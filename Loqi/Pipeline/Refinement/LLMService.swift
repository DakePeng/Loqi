import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import os
// Linking MLXVLM is what lets loadModelContainer load vision repos
// (Qwen3-VL): MLXLMCommon discovers its factory via an NSClassFromString
// trampoline, so the existing load path needs no changes.
import MLXVLM
import Tokenizers

/// Owns the on-device refinement model. The only file that touches MLX —
/// keep it that way so library churn stays contained.
///
/// Weights download from Hugging Face or ModelScope (user-selectable in
/// Settings; ModelScope for regions where huggingface.co is unreachable).
/// MLX requires a real Apple-silicon GPU: this never runs in the simulator.
actor LLMService: LLMServicing {
    private(set) var loadState: LLMLoadState = .unloaded
    private var container: ModelContainer?
    private(set) var model: ModelOption
    private(set) var source: ModelSource

    /// Last measured generation speed, for the debug screen.
    private(set) var lastTokensPerSecond: Double = 0

    /// While true, generation parks instead of touching Metal: a GPU command
    /// buffer submitted from the background aborts the process uncatchably
    /// (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`).
    /// The pipeline drives this from scenePhase. This guards the START of
    /// every generation (so nothing new reaches the GPU backgrounded); an
    /// already-in-flight generation is stopped separately, by cancelling it.
    private var isBackgrounded = false

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "llm")

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
    /// receives progress. Under `.requireDownloaded`, missing weights throw
    /// `.modelNotDownloaded` instead of silently pulling gigabytes; joining
    /// a load someone else already started is always allowed.
    func load(
        policy: LLMLoadPolicy = .downloadIfNeeded,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
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
        if policy == .requireDownloaded, !Self.isDownloaded(model: model) {
            throw LLMServiceError.modelNotDownloaded
        }
        let task = Task { try await performLoad() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    // MARK: Downloaded-weights detection

    /// Marker written after weights provably completed (the downloader
    /// returned). It survives source switches — snapshots stay valid.
    /// "v2": the v1 namespace was retired when the Qwen3.5 repos gained
    /// their vision files — a pre-VLM snapshot must not count as
    /// downloaded, or photo understanding silently degrades to a
    /// text-only container.
    private nonisolated static func downloadedMarkerKey(_ modelID: String) -> String {
        "llm.downloaded.v2.\(modelID)"
    }

    /// Whether the model can load without touching the network. Checks the
    /// completion marker first, then both caches on disk (covers installs
    /// that predate the marker).
    nonisolated static func isDownloaded(model: ModelOption) -> Bool {
        if UserDefaults.standard.bool(forKey: downloadedMarkerKey(model.id)) {
            return true
        }
        let scopeSnapshot = ModelScopeDownloader.cacheRoot.appending(
            path: model.id, directoryHint: .isDirectory)
        if ModelScopeDownloader().isValidSnapshot(scopeSnapshot),
           visionFilesPresent(model: model, in: scopeSnapshot) {
            return true
        }
        return hubSnapshotLooksComplete(model: model)
    }

    /// Vision tiers need the processor configs on disk or the VLM factory
    /// can't claim the repo and it loads text-only; snapshots downloaded
    /// before the repos gained their vision tower predate these files.
    private nonisolated static func visionFilesPresent(
        model: ModelOption, in directory: URL
    ) -> Bool {
        guard model.supportsVision else { return true }
        return FileManager.default.fileExists(
            atPath: directory.appending(path: "preprocessor_config.json").path)
    }

    /// Hugging Face cache heuristic: a snapshot revision whose safetensors
    /// total at least ~80% of the expected download (symlinks resolved).
    /// The hub layout only links files after their blob completes, and the
    /// size floor rejects multi-file partials.
    private nonisolated static func hubSnapshotLooksComplete(model: ModelOption) -> Bool {
        let parts = model.id.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let repo = Repo.ID(namespace: String(parts[0]), name: String(parts[1]))
        let snapshots = HubCache().snapshotsDirectory(repo: repo, kind: .model)
        let fm = FileManager.default
        guard let revisions = try? fm.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil) else { return false }
        for revision in revisions {
            guard let files = try? fm.contentsOfDirectory(
                at: revision, includingPropertiesForKeys: nil) else { continue }
            let weightBytes = files
                .filter { $0.pathExtension == "safetensors" }
                .compactMap { file -> Int64? in
                    let resolved = file.resolvingSymlinksInPath()
                    guard let size = try? resolved.resourceValues(
                        forKeys: [.fileSizeKey]).fileSize else { return nil }
                    return Int64(size)
                }
                .reduce(Int64(0), +)
            if weightBytes >= Int64(Double(model.downloadBytes) * 0.8),
               visionFilesPresent(model: model, in: revision) {
                return true
            }
        }
        return false
    }

    /// Cancel an in-flight download/load. The completed-file checkpoints stay
    /// on disk, so a later `load()` resumes rather than restarting.
    func cancelLoad() {
        loadTask?.cancel()
    }

    /// MLX buffer-cache caps. `ModelOption.requiredHeadroom` budgets for the
    /// full cache; when memory is tight the tight cap shaves ~190MB off the
    /// loaded footprint at some generation-speed cost.
    private static let fullCacheLimit = 256 * 1024 * 1024
    private static let tightCacheLimit = 64 * 1024 * 1024

    /// Memory admission, pure for testing: which cache cap fits in `free`
    /// bytes, or nil if even the tight one does not.
    static func admittedCacheLimit(free: UInt64, requiredHeadroom: UInt64) -> Int? {
        if free > requiredHeadroom { return fullCacheLimit }
        if free + UInt64(fullCacheLimit - tightCacheLimit) > requiredHeadroom {
            return tightCacheLimit
        }
        return nil
    }

    /// In-process ASR (SenseVoice's ONNX arenas) makes free memory dip
    /// during decode bursts, so one bad sample must not fail the load:
    /// re-poll briefly, clearing whatever the MLX cache can give back.
    private func admitLoad() async throws -> Int {
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            MLX.Memory.clearCache()
            if let limit = Self.admittedCacheLimit(
                free: available(), requiredHeadroom: model.requiredHeadroom) {
                return limit
            }
        }
        throw LLMServiceError.insufficientMemory
    }

    private func performLoad() async throws {
        do {
            let cacheLimit = try await admitLoad()
            loadState = .downloading(progress: 0)
            // Text-era ModelScope snapshots must re-list to pick up the
            // repos' newly added vision files (no-op when already present).
            ModelScopeDownloader.invalidateSnapshotIfMissingVisionFiles(model: model)
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
            // The downloader returned: weights are complete on disk. Future
            // `.requireDownloaded` loads may proceed without asking again.
            UserDefaults.standard.set(
                true, forKey: Self.downloadedMarkerKey(model.id))
            loadState = .loading
            MLX.Memory.cacheLimit = cacheLimit
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
        try await withExponentialBackoff(attempts: attempts, body)
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
        loadTask?.cancel()
        container = nil
        MLX.Memory.clearCache()
        loadState = .unloaded
    }

    /// Scene background state. While backgrounded, `generate`/`describeImage`
    /// defer to foreground rather than submit GPU work.
    func setBackgrounded(_ value: Bool) {
        isBackgrounded = value
    }

    /// Suspend until the app is foregrounded (or the task is cancelled), so a
    /// caller never begins GPU work — generation or a self-healing reload —
    /// from the background.
    ///
    /// This is the intended back-pressure for the jobs `SummaryJobCenter`
    /// deliberately leaves running across backgrounding (imports, in-progress
    /// re-transcribes): when they reach their summary phase they park here
    /// instead of being cancelled. The loop honours `Task.checkCancellation`,
    /// so if the background-task grace expires and the OS cancels the task,
    /// the park exits cleanly rather than hanging.
    private func parkWhileBackgrounded() async throws {
        while isBackgrounded {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
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
        // Never begin Metal work from the background — it aborts the process.
        try await parkWhileBackgrounded()
        if container == nil {
            // A memory shed can unload mid-job (e.g. between summarize
            // chunks). Weights are on disk, so heal with a reload instead
            // of failing the whole job; requireDownloaded keeps this from
            // ever becoming a surprise download.
            try await load(policy: .requireDownloaded)
        }
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

            let stream = try Self.tokenStream(
                input: lmInput, parameters: parameters, context: context)
            return try await Self.collectGeneratedText(from: stream) { generation in
                if case .chunk(let chunk) = generation {
                    return chunk
                }
                return nil
            }
        }

        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        if seconds > 0 {
            lastTokensPerSecond = Self.estimatedDiagnosticTokens(in: result) / seconds
        }

        // Hybrid thinking models occasionally leak a think tag despite
        // enable_thinking=false. Strip it — this used to be an assert,
        // which made one leaked token after an hour of refinements crash
        // the whole recording in debug builds.
        if result.contains("<think>") {
            logger.warning("thinking tag leaked into output; stripping")
            return Self.stripThinking(result)
        }
        return result
    }

    /// Generation stream through an explicitly built TokenIterator, so the
    /// repetition processor can be wrapped in FlattenedPromptProcessor (the
    /// TokenRing 2-D prompt crash — see its doc). Otherwise equivalent to
    /// `MLXLMCommon.generate(input:parameters:context:)`.
    private nonisolated static func tokenStream(
        input: LMInput, parameters: GenerateParameters, context: ModelContext
    ) throws -> AsyncStream<Generation> {
        let iterator = try TokenIterator(
            input: input,
            model: context.model,
            processor: parameters.processor().map {
                FlattenedPromptProcessor(inner: $0) as any LogitProcessor
            },
            sampler: parameters.sampler(),
            prefillStepSize: parameters.prefillStepSize,
            maxTokens: parameters.maxTokens)
        let (stream, _) = generateTask(
            promptTokenCount: input.text.tokens.size,
            modelConfiguration: context.configuration,
            tokenizer: context.tokenizer,
            iterator: iterator)
        return stream
    }

    nonisolated static func collectGeneratedText<S: AsyncSequence>(
        from stream: S,
        chunkText: (S.Element) -> String?
    ) async throws -> String {
        var text = ""
        for try await generation in stream {
            try Task.checkCancellation()
            if let chunk = chunkText(generation) {
                text += chunk
            }
        }
        try Task.checkCancellation()
        return text
    }

    /// Remove `<think>…</think>` spans (and an unterminated trailing one).
    /// Pure and internal for tests.
    nonisolated static func stripThinking(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var result = text
        while let open = result.range(of: "<think>") {
            if let close = result.range(
                of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Diagnostic-only token estimate for Settings. Most Loqi generations
    /// are CJK-heavy notes, where non-punctuation characters average much
    /// closer to 1.5 chars/token than the English-ish 4 chars/token rule.
    nonisolated static func estimatedDiagnosticTokens(in text: String) -> Double {
        let contentCharacters = text.reduce(0) { count, character in
            let ignored = character.unicodeScalars.allSatisfy { scalar in
                CharacterSet.punctuationCharacters.contains(scalar)
                    || CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            return count + (ignored ? 0 : 1)
        }
        return Double(contentCharacters) / 1.5
    }

    /// Describe an attached photo. Vision tiers only — text models throw
    /// immediately. Same generation discipline as `generate`; the image is
    /// resized at prepare time to bound image-token prefill.
    func describeImage(
        at url: URL,
        system: String,
        user: String,
        maxTokens: Int = 200
    ) async throws -> String {
        guard model.supportsVision else { throw LLMServiceError.visionUnsupported }
        try await parkWhileBackgrounded()
        if container == nil {
            try await load(policy: .requireDownloaded)
        }
        guard let container else { throw LLMServiceError.modelNotLoaded }

        return try await container.perform { context in
            let input = UserInput(
                chat: [
                    .system(system),
                    .user(user, images: [.url(url)]),
                ],
                processing: .init(resize: CGSize(width: 1024, height: 1024)),
                additionalContext: ["enable_thinking": false])
            let lmInput = try await context.processor.prepare(input: input)
            let parameters = GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.3,
                topP: 0.9,
                repetitionPenalty: 1.15,
                repetitionContextSize: 64)

            let stream = try Self.tokenStream(
                input: lmInput, parameters: parameters, context: context)
            return try await Self.collectGeneratedText(from: stream) { generation in
                if case .chunk(let chunk) = generation {
                    return chunk
                }
                return nil
            }
        }
    }

    func available() -> UInt64 {
        SystemResources.availableMemoryBytes()
    }
}

/// Upstream PR #170 applied from outside (mlx-swift-lm ≤ 3.31.3): VLM input
/// processors hand the iterator a `[1, N]` prompt, and the repetition
/// penalty's TokenRing reads `dim(0)` — the batch axis — as the prompt
/// length. Its ring buffer then comes out `[N + capacity - 1]` instead of
/// `[capacity]`, and the first sampled token aborts the process with
/// "broadcast_shapes (capacity) and (N + capacity - 1)" — uncatchable from
/// Swift. Text models build 1-D prompts and were never affected.
/// Flattening the prompt before the ring sees it is exactly the fix merged
/// upstream after 3.31.3; delete this when the dependency moves past it.
private struct FlattenedPromptProcessor: LogitProcessor {
    var inner: any LogitProcessor

    mutating func prompt(_ prompt: MLXArray) {
        inner.prompt(prompt.reshaped(-1))
    }

    func process(logits: MLXArray) -> MLXArray {
        inner.process(logits: logits)
    }

    mutating func didSample(token: MLXArray) {
        inner.didSample(token: token)
    }
}

enum LLMServiceError: LocalizedError {
    case modelNotLoaded
    case modelNotDownloaded
    case insufficientMemory
    case visionUnsupported

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            String(localized: "The AI model is not loaded")
        case .modelNotDownloaded:
            String(localized: "The AI model isn't downloaded yet")
        case .insufficientMemory:
            String(localized: "Not enough free memory to load the model")
        case .visionUnsupported:
            String(localized: "The selected model cannot read images")
        }
    }
}
