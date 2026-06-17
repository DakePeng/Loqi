import Foundation

/// LLM load state, lifted to the top level so `LLMServicing` (and any fake)
/// can name it without depending on the concrete `LLMService` actor.
enum LLMLoadState: Sendable, Equatable {
    case unloaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)
}

/// Whether `load` may reach the network. Weights are ~0.6–1.8 GB, so every
/// user-facing feature asks consent first (`requireDownloaded`) and only an
/// explicit download action passes `downloadIfNeeded`.
enum LLMLoadPolicy: Sendable {
    case downloadIfNeeded
    case requireDownloaded
}

/// Seam over the on-device refinement model. The only production conformer
/// is the `LLMService` actor (the single file that touches MLX); tests
/// conform `FakeLLMService` so the orchestration layer (CaptionPipeline,
/// RefinementQueue, ChunkNoteQueue, SummaryJobCenter, SummaryEngine,
/// ChatEngine, SessionRetranscriber, FileImportEngine,
/// AttachmentDescribeQueue) can be exercised in the simulator without
/// Metal or a multi-GB download.
///
/// Protocol requirements carry no default arguments (a Swift limitation);
/// the extensions below restore the ergonomic call shapes (`load { ... }`,
/// `generate(system:user:maxTokens:)`, etc.) that callers already use.
protocol LLMServicing: Sendable {
    /// Download (first run) and load the model. Safe to call repeatedly and
    /// concurrently — a second caller joins the in-flight load. Under
    /// `.requireDownloaded`, missing weights throw `.modelNotDownloaded`
    /// instead of silently pulling gigabytes.
    func load(
        policy: LLMLoadPolicy,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws

    /// Cancel an in-flight download/load. Checkpointed files stay on disk.
    func cancelLoad() async

    /// Current load state — drives Settings/Diagnostics UI and the
    /// pipeline's readiness gates (`llmIsReady`).
    var loadState: LLMLoadState { get async }

    /// Switch the active model tier; unloads the previous one.
    func setModel(_ option: ModelOption) async

    /// Switch the download mirror (Hugging Face / ModelScope). Cached
    /// snapshots stay valid; only future downloads change source.
    func setSource(_ newSource: ModelSource) async

    /// Release the container and clear the MLX cache.
    func unload() async

    /// Gate GPU work on foreground state — a command buffer submitted from
    /// the background aborts the process uncatchably.
    func setBackgrounded(_ value: Bool) async

    /// Run one generation. Cooperatively cancellable via Task cancellation.
    func generate(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Float
    ) async throws -> String

    /// Describe an attached photo. Vision tiers only — text models throw.
    func describeImage(
        at url: URL,
        system: String,
        user: String,
        maxTokens: Int
    ) async throws -> String

    /// Free memory estimate, for the load-admission heuristic and Diagnostics.
    func available() async -> UInt64

    /// Last measured generation speed, for the debug screen.
    var lastTokensPerSecond: Double { get async }

    /// The active model tier — read for its `supportsVision` flag.
    var model: ModelOption { get async }
}

// MARK: - Convenience overloads (restore default-argument ergonomics)

extension LLMServicing {
    /// `load(policy: .requireDownloaded)` — no progress callback.
    func load(policy: LLMLoadPolicy) async throws {
        try await load(policy: policy, onProgress: nil)
    }

    /// `load { fraction in ... }` — default policy, trailing-closure progress.
    func load(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await load(policy: .downloadIfNeeded, onProgress: onProgress)
    }

    /// `generate(system:user:maxTokens:)` — default temperature 0.3.
    func generate(
        system: String, user: String, maxTokens: Int
    ) async throws -> String {
        try await generate(system: system, user: user, maxTokens: maxTokens, temperature: 0.3)
    }

    /// `describeImage(at:system:user:)` — default maxTokens 200.
    func describeImage(
        at url: URL, system: String, user: String
    ) async throws -> String {
        try await describeImage(at: url, system: system, user: user, maxTokens: 200)
    }
}
