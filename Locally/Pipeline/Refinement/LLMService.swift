import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Owns the on-device refinement model. The only file that touches MLX —
/// keep it that way so library churn stays contained.
///
/// Weights download from Hugging Face or ModelScope (user-selectable in
/// Settings; ModelScope for regions where huggingface.co is unreachable).
/// MLX requires a real Apple-silicon GPU: this never runs in the simulator.
actor LLMService {
    enum LoadState: Sendable {
        case unloaded
        case downloading(progress: Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .unloaded
    private var container: ModelContainer?
    private(set) var model: ModelOption
    private(set) var source: ModelSource

    /// Last measured generation speed, for the debug screen.
    private(set) var lastTokensPerSecond: Double = 0

    init(model: ModelOption = ModelCatalog.default, source: ModelSource = .huggingFace) {
        self.model = model
        self.source = source
    }

    func setModel(_ option: ModelOption) {
        guard option != model else { return }
        unload()
        model = option
    }

    func setSource(_ newSource: ModelSource) {
        guard newSource != source else { return }
        // Cached snapshots stay valid; only future downloads change source.
        source = newSource
    }

    private var loadTask: Task<Void, Error>?
    /// All concurrent load() callers' progress callbacks — a joiner's bar
    /// must advance even though the download was started by someone else.
    private var progressObservers: [UUID: @Sendable (Double) -> Void] = [:]

    /// Download (first run) and load the model. Safe to call repeatedly and
    /// concurrently — a second caller joins the in-flight load and still
    /// receives progress.
    func load(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        if case .ready = loadState { return }
        let token = UUID()
        if let onProgress {
            progressObservers[token] = onProgress
            if case .downloading(let fraction) = loadState {
                onProgress(fraction)
            }
        }
        defer { progressObservers[token] = nil }

        if let loadTask {
            return try await loadTask.value
        }
        let task = Task { try await performLoad() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    /// Cancel an in-flight download/load. The completed-file checkpoints stay
    /// on disk, so a later `load()` resumes rather than restarting.
    func cancelLoad() {
        loadTask?.cancel()
    }

    private func performLoad() async throws {
        guard available() > model.requiredHeadroom else {
            loadState = .failed("Not enough free memory to load the model")
            throw LLMServiceError.insufficientMemory
        }

        loadState = .downloading(progress: 0)
        do {
            let downloader: any Downloader =
                switch source {
                case .huggingFace: #hubDownloader()
                case .modelScope: ModelScopeDownloader()
                }

            // Both downloaders checkpoint completed files, so a retry after
            // a network drop resumes rather than restarting the ~1.3GB pull.
            let container = try await withRetry(attempts: 3) {
                try await loadModelContainer(
                    from: downloader,
                    using: #huggingFaceTokenizerLoader(),
                    configuration: ModelConfiguration(id: self.model.id)
                ) { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { await self?.noteDownloadProgress(fraction) }
                }
            }
            loadState = .loading
            MLX.Memory.cacheLimit = 256 * 1024 * 1024
            self.container = container
            loadState = .ready
            ModelScopeDownloader.removeSnapshots(
                notIn: Set(ModelCatalog.all.map(\.id)))
        } catch is CancellationError {
            // User stopped the download — back to a clean idle state, not an
            // error. Checkpointed files remain for a later resume.
            loadState = .unloaded
            throw CancellationError()
        } catch {
            loadState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func withRetry<T>(
        attempts: Int, _ body: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try await body()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    try await Task.sleep(for: .seconds(Double(1 << (attempt + 1))))
                }
            }
        }
        throw lastError ?? LLMServiceError.modelNotLoaded
    }

    private func noteDownloadProgress(_ fraction: Double) {
        if case .downloading = loadState {
            loadState = .downloading(progress: fraction)
        }
        for observer in progressObservers.values {
            observer(fraction)
        }
    }

    func unload() {
        container = nil
        MLX.Memory.clearCache()
        loadState = .unloaded
    }

    func clearCache() {
        MLX.Memory.clearCache()
    }

    /// Run one generation. Cooperatively cancellable via Task cancellation.
    func generate(
        system: String,
        user: String,
        maxTokens: Int = 120,
        temperature: Float = 0.3
    ) async throws -> String {
        guard let container else { throw LLMServiceError.modelNotLoaded }

        let started = ContinuousClock.now
        let result = try await container.perform { context in
            let chat: [Chat.Message] = [
                .system(system),
                .user(user),
            ]
            // Qwen3/3.5 are hybrid thinking models; thinking must stay off
            // or refinement latency balloons.
            let input = UserInput(
                chat: chat,
                additionalContext: ["enable_thinking": false])
            let lmInput = try await context.processor.prepare(input: input)
            // Repetition penalty is essential for small quantized models:
            // without it they degenerate into "this, this, this…" loops.
            let parameters = GenerateParameters(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: 0.9,
                repetitionPenalty: 1.15,
                repetitionContextSize: 64)

            var text = ""
            let stream = try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context)
            for await generation in stream {
                if Task.isCancelled { break }
                if case .chunk(let chunk) = generation {
                    text += chunk
                }
            }
            return text
        }

        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        if seconds > 0 {
            // Rough chars/4 token estimate; good enough for the debug readout.
            lastTokensPerSecond = Double(result.count) / 4 / seconds
        }

        assert(!result.contains("<think>"), "Thinking mode leaked into output")
        return result
    }

    func available() -> UInt64 {
        UInt64(max(0, os_proc_available_memory()))
    }
}

enum LLMServiceError: Error {
    case modelNotLoaded
    case insufficientMemory
}
