import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
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
actor LLMService {
    private(set) var loadState: LLMLoadState = .unloaded
    private var container: ModelContainer?
    private(set) var model: ModelOption
    private(set) var source: ModelSource

    /// Last measured generation speed, for the debug screen.
    private(set) var lastTokensPerSecond: Double = 0

    /// Cumulative wall time spent inside `generate`/`describeImage` this
    /// session — Diagnostics compares it against SenseVoice decode time to
    /// show which path drives heat. Reset by the pipeline at session start.
    private(set) var generateActiveSeconds: Double = 0

    /// While true, generation parks instead of touching Metal: iOS aborts
    /// GPU command buffers submitted from the background
    /// (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`).
    /// With our forked mlx that abort is no longer fatal — it poisons the
    /// stream and surfaces as a caught MLXError in `generate` — but the
    /// work is still garbage, so nothing should reach the GPU backgrounded.
    /// The pipeline drives this from scenePhase, setting it at `.inactive`
    /// (which always precedes `.background`). It guards the START of every
    /// generation via `parkWhileBackgrounded`, and every prefill-window and
    /// token boundary of an in-flight one via `checkSceneExit` — which
    /// ABANDONS the generation (no drain: the job restarts from its
    /// checkpoint on foreground, and any still-in-flight buffer either
    /// finishes or aborts on its own).
    private var isBackgrounded = false
    /// `isBackgrounded`, but readable synchronously from inside model code:
    /// the prefill loop in `GatedPrefillModel.prepare` is not async and
    /// can't await the actor. Written only by `setBackgrounded`.
    private let sceneExit = OSAllocatedUnfairLock(initialState: false)

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
        let backgroundHFSnapshot = HuggingFaceBackgroundDownloader.cacheRoot.appending(
            path: model.id, directoryHint: .isDirectory)
        if backgroundHFSnapshotLooksComplete(model: model, at: backgroundHFSnapshot) {
            return true
        }
        return hubSnapshotLooksComplete(model: model)
    }

    nonisolated static func backgroundHFSnapshotLooksComplete(
        model: ModelOption, at directory: URL
    ) -> Bool {
        guard let entries = try? backgroundHFManifestEntries(in: directory),
              entries.contains(where: { $0.path.hasSuffix(".safetensors") }),
              HuggingFaceBackgroundDownloader().isValidSnapshot(directory),
              visionFilesPresent(model: model, in: directory)
        else { return false }
        return true
    }

    private nonisolated static func backgroundHFManifestEntries(
        in directory: URL
    ) throws -> [HuggingFaceBackgroundDownloader.FileEntry] {
        let manifest = directory.appending(path: ".manifest.json")
        let data = try Data(contentsOf: manifest)
        if let metadata = try? JSONDecoder().decode(BackgroundHFSnapshotManifest.self, from: data) {
            return metadata.files
        }
        let sizes = try JSONDecoder().decode([String: Int64].self, from: data)
        return sizes.map { HuggingFaceBackgroundDownloader.FileEntry(path: $0.key, size: $0.value) }
    }

    private struct BackgroundHFSnapshotManifest: Decodable {
        var files: [HuggingFaceBackgroundDownloader.FileEntry]
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
            try await parkWhileBackgrounded()
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
            try await parkWhileBackgrounded()
            let cacheLimit = try await admitLoad()
            loadState = .downloading(progress: 0)
            // Text-era ModelScope snapshots must re-list to pick up the
            // repos' newly added vision files (no-op when already present).
            ModelScopeDownloader.invalidateSnapshotIfMissingVisionFiles(model: model)
            let downloader: any Downloader =
                switch source {
                case .huggingFace: HuggingFaceBackgroundDownloader()
                case .modelScope: ModelScopeDownloader()
                }

            // Both downloaders checkpoint completed files, so a retry after
            // a network drop resumes rather than restarting the ~1.3GB pull.
            logger.info("model load begin (cpu stream): \(self.model.id, privacy: .public)")
            let container = try await Self.cpuStreamLoad(
                modelID: model.id,
                downloader: downloader,
                onProgress: { [weak self] fraction in
                    Task { await self?.noteDownloadProgress(fraction) }
                })
            logger.info("model load end (cpu stream): \(self.model.id, privacy: .public)")
            // The downloader returned: weights are complete on disk. Future
            // `.requireDownloaded` loads may proceed without asking again.
            UserDefaults.standard.set(
                true, forKey: Self.downloadedMarkerKey(model.id))
            try await parkWhileBackgrounded()
            loadState = .loading
            MLX.Memory.cacheLimit = cacheLimit
            self.container = container
            loadState = .ready
            // Keep set = summary lineup PLUS the live roles: the live-refine
            // tier and the vision fallback are deliberately not in
            // `ModelCatalog.all` anymore, and pruning their just-downloaded
            // ModelScope snapshots would strand `.requireDownloaded` loads
            // behind a stale downloaded-marker.
            ModelScopeDownloader.removeSnapshots(
                notIn: Set((ModelCatalog.all
                    + [ModelCatalog.liveModel, ModelCatalog.liveRefineModel])
                    .map(\.id)))
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

    /// Download + load, with the whole load bound to the CPU stream: MLX
    /// records an op's stream at creation via the task-local default, so
    /// under this wrapper the weight materialization (loadWeights' big
    /// uninterruptible eval — no cancellation checks anywhere in the load
    /// path) never submits a Metal command buffer. That makes a load
    /// spanning backgrounding structurally crash-free, where the GPU
    /// version aborts the process the moment iOS revokes GPU access.
    /// Costs some load speed; generation is unaffected — its ops are
    /// created outside this scope, on the GPU default.
    private nonisolated static func cpuStreamLoad(
        modelID: String,
        downloader: any Downloader,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        try await Stream.withNewDefaultStream(device: Device.cpu) {
            try await withExponentialBackoff(attempts: 3) {
                try await loadModelContainer(
                    from: downloader,
                    using: #huggingFaceTokenizerLoader(),
                    configuration: ModelConfiguration(id: modelID)
                ) { progress in
                    onProgress(progress.fractionCompleted)
                }
            }
        }
    }

    private func noteDownloadProgress(_ fraction: Double) {
        if case .downloading = loadState {
            loadState = .downloading(progress: fraction)
        }
        for observer in progressObservers.values {
            observer(fraction)
        }
    }

    /// ponytail: no graceful Metal cleanup anywhere in here — no
    /// synchronize, no drain, no deferred foreground cleanup. Those calls
    /// block on MLX's global eval lock; abandoning is cheaper and the
    /// forked mlx force-signals poisoned events, so an abandoned abort
    /// can no longer wedge that lock (the old frozen-app bug). Scene exits
    /// ABANDON work (jobs restart from their checkpoints); the worst case
    /// is a caught MLXError, handled in `generate`.
    func unload() {
        loadTask?.cancel()
        container = nil
        loadState = .unloaded
        // Cache buffers stay resident when backgrounded — clearCache can
        // synchronize GPU work, which is exactly what must never happen
        // off-foreground. admitLoad clears it before the next load anyway.
        if !isBackgrounded {
            MLX.Memory.clearCache()
        }
        logger.info("unloaded (cache cleared=\(!self.isBackgrounded))")
    }

    /// Scene background state. While backgrounded, `generate`/`describeImage`
    /// defer to foreground rather than submit GPU work, and any in-flight
    /// generation abandons itself at its next gate check.
    func setBackgrounded(_ value: Bool) {
        if value != isBackgrounded {
            logger.info("llm scene flag -> backgrounded=\(value)")
        }
        isBackgrounded = value
        sceneExit.withLock { $0 = value }
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

    /// Off-foreground the shed is skipped outright — clearCache can
    /// synchronize GPU work; admitLoad clears before the next load anyway.
    func clearCache() {
        guard !isBackgrounded else { return }
        MLX.Memory.clearCache()
    }

    func resetHeatStats() {
        generateActiveSeconds = 0
    }

    private static func seconds(from duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    /// Run one generation. Cooperatively cancellable via Task cancellation.
    /// `responsePrefix` is appended after the chat template's assistant
    /// header so the model CONTINUES it instead of choosing its own
    /// opening — anchors format-critical generations (the 2B drifts into
    /// compressed schemas at the start of TSV extraction). The prefix is
    /// part of the answer and is prepended to the returned text.
    func generate(
        system: String,
        user: String,
        maxTokens: Int = 120,
        temperature: Float = 0.3,
        repetitionPenalty: Float? = 1.15,
        responsePrefix: String? = nil
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
        let result: String
        do {
            result = try await container.perform { context in
                let chat: [Chat.Message] = [
                    .system(system),
                    .user(user),
                ]
                // Qwen3/3.5 are hybrid thinking models; thinking must stay off
                // or refinement latency balloons.
                let input = UserInput(
                    chat: chat,
                    additionalContext: ["enable_thinking": false])
                var lmInput = try await context.processor.prepare(input: input)
                if let responsePrefix {
                    let prefixTokens = context.tokenizer.encode(
                        text: responsePrefix, addSpecialTokens: false)
                    let prompt = lmInput.text.tokens
                    var prefix = MLXArray(prefixTokens)
                    // The VLM processor emits [1, N] prompts; match dims.
                    if prompt.ndim == 2 { prefix = prefix.reshaped([1, -1]) }
                    lmInput = LMInput(
                        tokens: concatenated([prompt, prefix], axis: -1))
                }
                // Repetition penalty is essential for small quantized models:
                // without it they degenerate into "this, this, this…" loops.
                // BUT the ring seeds from the prompt tail, so a copy-shaped
                // task (sentence cleanup: correct output ≈ the input sitting
                // right there in the prompt) is penalized for copying and
                // pushed to paraphrase — those callers pass nil and rely on
                // their fidelity gate to catch loops instead.
                // The small prefill window bounds each un-gateable GPU burst
                // to roughly a decode step, so the prefill gate can fire well
                // inside the .inactive→.background transition even with the
                // buffer cache freshly shed (see GatedPrefillModel).
                let parameters = GenerateParameters(
                    maxTokens: maxTokens,
                    temperature: temperature,
                    topP: 0.9,
                    repetitionPenalty: repetitionPenalty,
                    repetitionContextSize: 64,
                    prefillStepSize: 64)

                let text = try await self.gatedText(
                    input: lmInput, parameters: parameters, context: context)
                return (responsePrefix ?? "") + text
            }
        } catch let error as MLXError {
            // A background GPU abort poisons the MLX stream (forked mlx,
            // upstream ml-explore/mlx#3523) instead of terminating the
            // process; gatedText surfaces it as MLXError. Map it to the
            // abandon/suspend path so the job restarts from its checkpoint.
            // The error is matched by content, not just the scene flag: iOS
            // can revoke GPU access before scenePhase delivery flips the
            // flag (and re-grant before the error surfaces), so the flag
            // alone misses the lag windows on both edges.
            if sceneExit.withLock({ $0 }) || Self.isBackgroundGPUAbort(error) {
                throw CancellationError()
            }
            throw error
        }

        let elapsed = started.duration(to: .now)
        let seconds = Self.seconds(from: elapsed)
        generateActiveSeconds += seconds
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

    /// Stop generating the moment the scene leaves the foreground —
    /// checked between prefill windows and tokens. Deliberately does NOT
    /// synchronize/drain: waiting on the GPU here blocks MLX's global eval
    /// lock, and a queue poisoned by a background abort would wedge it (and
    /// with it every later MLX call) forever. Abandon instead; throwing
    /// `CancellationError` reuses every caller's suspend/checkpoint
    /// handling, and the pending marker restarts the job on foreground.
    private nonisolated func checkSceneExit() throws {
        guard sceneExit.withLock({ $0 }) else { return }
        logger.warning("scene-exit gate tripped; abandoning generation")
        throw CancellationError()
    }

    /// One generation, iterating the TokenIterator directly instead of
    /// through MLX's `generateTask`: the upstream producer free-runs ahead
    /// of its consumer, so cancelling it can never bound what's on the GPU.
    /// Owning the loop makes every token boundary a deterministic safe-stop
    /// (`checkSceneExit`) that abandons the generation on scene exit, for
    /// every `generate`/`describeImage` caller at once.
    /// The explicit TokenIterator also lets the repetition processor wrap in
    /// FlattenedPromptProcessor (the TokenRing 2-D prompt crash — see its
    /// doc). Output matches upstream: same stop-token set, same streaming
    /// detokenizer, and a trailing incomplete-unicode segment is dropped
    /// there too.
    private nonisolated func gatedText(
        input: LMInput, parameters: GenerateParameters, context: ModelContext
    ) async throws -> String {
        // Mirrors MLX's private buildStopTokenIds.
        var stopTokens = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { stopTokens.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) {
                stopTokens.insert(id)
            }
        }

        // Prompt prefill runs inside the iterator's init and submits GPU
        // work of its own — gate before starting it, and wrap the model so
        // the prefill itself checks the gate between windows (Qwen3.5's own
        // prepare would otherwise run the whole prompt as one multi-second
        // un-stoppable forward; see GatedPrefillModel).
        try checkSceneExit()
        let gatedModel = GatedPrefillModel(
            wrapping: context.model, gate: checkSceneExit)
        // withError (sync — the loop never suspends) converts an MLX error
        // during prefill/decode into a thrown MLXError instead of the
        // default fatalError. With the forked mlx, this is where a
        // background GPU abort (poisoned stream) surfaces.
        return try withError {
            var iterator = try TokenIterator(
                input: input,
                model: gatedModel,
                processor: parameters.processor().map {
                    FlattenedPromptProcessor(inner: $0) as any LogitProcessor
                },
                sampler: parameters.sampler(),
                prefillStepSize: parameters.prefillStepSize,
                maxTokens: parameters.maxTokens)
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var text = ""
            while let token = iterator.next() {
                try Task.checkCancellation()
                try checkSceneExit()
                if token == context.tokenizer.unknownTokenId || stopTokens.contains(token) {
                    break
                }
                detokenizer.append(token: token)
                if let chunk = detokenizer.next() { text += chunk }
            }
            return text
        }
    }

    /// The one MLX error that is always a scene-exit artifact, never a
    /// model/format problem: iOS refused GPU work because the app was
    /// backgrounded. String match on the IOGPU error name — MLXError
    /// carries only the flattened C++ message, so there is nothing typed
    /// to switch on. Two independent phrasings are matched (the IOGPU
    /// constant and Metal's human-readable description) so a wording
    /// change in one layer doesn't silently break the suspend mapping.
    /// TODO: when the mlx-swift fork is rebased (or dropped for upstream
    /// ≥ a025496c), surface a typed error code through mlx-c instead.
    nonisolated static func isBackgroundGPUAbort(_ error: MLXError) -> Bool {
        let message = String(describing: error)
        return message.contains("BackgroundExecutionNotPermitted")
            || message.contains("GPU work from background")
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

        let started = ContinuousClock.now
        let result: String
        do {
            result = try await container.perform { context in
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

                return try await self.gatedText(
                    input: lmInput, parameters: parameters, context: context)
            }
        } catch let error as MLXError {
            // Same MLXError mapping as `generate` (see there).
            if sceneExit.withLock({ $0 }) || Self.isBackgroundGPUAbort(error) {
                throw CancellationError()
            }
            throw error
        }
        generateActiveSeconds += Self.seconds(from: started.duration(to: .now))
        return result
    }

    func available() -> UInt64 {
        SystemResources.availableMemoryBytes()
    }
}

/// Makes the prompt prefill gateable. Qwen3.5's `prepare` ignores
/// `windowSize` and runs the whole prompt — seconds of Metal work for a
/// summary-chunk prompt — as one forward inside `TokenIterator.init`,
/// where no token-boundary gate can fire; a scene exit mid-prefill then
/// loses the whole prompt to a GPU abort (GPU work is forbidden in the
/// background, and iOS aborts even committed buffers at the transition;
/// the forked mlx makes that a caught error rather than a process kill,
/// but the generation is still wasted). For text-only prompts
/// longer than one window this feeds the model window-by-window through
/// its public step entry point, fully evaluating each window before
/// consulting `gate` — a gate trip therefore throws with nothing left in
/// flight. The first window still goes through the wrapped `prepare` so
/// model-internal sequence-start state (Qwen3.5 resets its position state
/// there) happens exactly once; an LLM-style `prepare` that returns the
/// window unconsumed (`.tokens`) gets it fed manually instead.
/// ponytail: image/video input delegates to the wrapped path un-windowed —
/// splitting a VLM's merged image-text embedding is per-model surgery, so
/// a photo-description prefill keeps a small crash window; revisit if that
/// path shows up in crash logs.
private final class GatedPrefillModel: Module, LanguageModel {
    let wrapped: any LanguageModel
    let gate: () throws -> Void

    init(wrapping: any LanguageModel, gate: @escaping () throws -> Void) {
        self.wrapped = wrapping
        self.gate = gate
        super.init()
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        let window = windowSize ?? 512
        guard input.image == nil, input.video == nil, input.text.mask == nil,
              input.text.tokens.dim(-1) > window
        else { return try wrapped.prepare(input, cache: cache, windowSize: windowSize) }

        // The VLM factory hands over `[1, N]` prompts, the LLM factory 1-D;
        // the step entry point always wants a batch axis.
        func batched(_ text: LMInput.Text) -> MLXArray {
            text.tokens.ndim == 1 ? text.tokens[.newAxis] : text.tokens
        }

        try gate()
        var remaining = input.text[.ellipsis, window...]
        switch try wrapped.prepare(
            LMInput(text: input.text[.ellipsis, ..<window]),
            cache: cache, windowSize: windowSize
        ) {
        case .logits:
            // Consumed the window (VLM style); its logits are unused.
            eval(cache)
        case .tokens(let rest):
            // Returned unconsumed (LLM style, window ≤ its step): feed it.
            _ = wrapped(batched(rest), cache: cache)
            eval(cache)
        }
        while remaining.tokens.dim(-1) > window {
            try gate()
            _ = wrapped(batched(remaining[.ellipsis, ..<window]), cache: cache)
            eval(cache)
            remaining = remaining[.ellipsis, window...]
        }
        try gate()
        // The tail's logits seed the first sampled token; the TokenIterator
        // evaluates them as part of its own pipeline.
        return .logits(LMOutput(logits: wrapped(batched(remaining), cache: cache)))
    }

    func callAsFunction(
        _ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?
    ) -> LMOutput {
        wrapped(input, cache: cache, state: state)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        wrapped(inputs, cache: cache)
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] {
        wrapped.newCache(parameters: parameters)
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
