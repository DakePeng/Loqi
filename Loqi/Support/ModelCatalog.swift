import Foundation

/// Where to download LLM weights from. ModelScope (魔搭) is the mirror to
/// use where huggingface.co is unreachable.
enum ModelSource: String, CaseIterable, Identifiable, Sendable {
    case huggingFace
    case modelScope

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .huggingFace: "Hugging Face"
        case .modelScope: "ModelScope 魔搭"
        }
    }
}

/// Where the speaker-recognition (diarization) models download from.
/// ModelScope is not an option here: the FluidInference CoreML repos are
/// not mirrored there (verified — "record not found"). HF-Mirror proxies
/// all of Hugging Face with identical URL paths and works where
/// huggingface.co is blocked.
enum DiarizerSource: String, CaseIterable, Identifiable, Sendable {
    case huggingFace
    case hfMirror

    var id: String { rawValue }

    static let defaultsKey = "diarizer.source"

    /// Persisted choice; absence of the key = .huggingFace.
    static var current: DiarizerSource {
        DiarizerSource(
            rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        ) ?? .huggingFace
    }

    var displayName: String {
        switch self {
        case .huggingFace: "Hugging Face"
        case .hfMirror: "HF-Mirror 镜像"
        }
    }

    var baseURL: String {
        switch self {
        case .huggingFace: "https://huggingface.co"
        case .hfMirror: "https://hf-mirror.com"
        }
    }
}

/// Refinement models the app offers. Qwen3.5-2B is small enough for every
/// supported device (iPhone 15+), so there is no per-device tier.
struct ModelOption: Identifiable, Sendable, Equatable {
    /// Repo id, identical on Hugging Face and ModelScope mirrors.
    let id: String
    let displayName: String
    /// Free memory required to load with the full MLX buffer cache, in
    /// bytes. LLMService admits loads up to ~190MB below this by shrinking
    /// the cache instead of refusing.
    let requiredHeadroom: UInt64
    /// Approximate download size in bytes — used only to turn the
    /// fraction-complete progress into a human-readable size/speed readout.
    let downloadBytes: Int64
    /// True for vision-language tiers (Qwen3-VL): attached photos get an
    /// LLM description in addition to OCR.
    var supportsVision = false
}

enum ModelCatalog {
    // Qwen3.5 is natively multimodal: every tier ships the vision tower
    // (model_type "qwen3_5", vision_config + processor configs — verified
    // byte-identical on Hugging Face and ModelScope, 2026-06), so photo
    // understanding needs no separate model and the older Qwen3 tiers are
    // gone. These repos load through the MLXVLM factory, whose processor
    // emits [1, N] prompts — safe only because LLMService flattens prompts
    // for the repetition ring (TokenRing bug in mlx-swift-lm ≤ 3.31.3).
    //
    // Standard uniform 4-bit quant. The OptiQ mixed-precision variant
    // produced gibberish with mlx-swift-lm 3.31.3 (its per-layer
    // quantization_mode is not applied) — don't switch back without testing.
    static let qwen35_2b = ModelOption(
        id: "mlx-community/Qwen3.5-2B-4bit",
        displayName: "Qwen3.5 2B — recommended",
        requiredHeadroom: 2_200_000_000,
        downloadBytes: 1_750_000_000,
        supportsVision: true)

    /// Lightest tier: fastest refinements and least contention with ASR,
    /// at noticeably lower text quality. Same vision tower.
    static let qwen35_0_8b = ModelOption(
        id: "mlx-community/Qwen3.5-0.8B-4bit",
        displayName: "Qwen3.5 0.8B — fastest",
        requiredHeadroom: 1_100_000_000,
        downloadBytes: 652_000_000,
        supportsVision: true)

    static let `default` = qwen35_2b
    /// Model that runs *during* a live recording: the fast, low-memory,
    /// low-heat tier. Always 0.8B regardless of the user's quality pick, so
    /// translation refinement and live notes never load the heavy VLM beside
    /// SenseVoice's in-process ONNX.
    static let liveModel = qwen35_0_8b

    /// Model post-session summary / title / vocabulary runs on: the user's
    /// quality pick (default 2B). Equals `liveModel` when the user picked the
    /// fast tier, in which case the boundary swap is a no-op.
    static var summaryModel: ModelOption { current }

    /// Bytes onboarding pulls for the LLM step now that both tiers ship.
    static var onboardingLLMBytes: Int64 {
        summaryModelDownloadBytes + liveModel.downloadBytes
    }

    /// The default/quality tier's size (onboarding runs before the user has
    /// picked, so this is `default`, not `current`).
    private static var summaryModelDownloadBytes: Int64 { `default`.downloadBytes }

    static let all = [qwen35_2b, qwen35_0_8b]

    static func option(for id: String) -> ModelOption {
        all.first { $0.id == id } ?? `default`
    }

    /// The user's active choice (Settings persists the id under "model.id").
    static var current: ModelOption {
        option(for: UserDefaults.standard.string(forKey: "model.id") ?? `default`.id)
    }

    /// Snap a persisted selection that's no longer in the catalog (the
    /// removed Qwen3 tiers) back to the default — otherwise the Settings
    /// picker renders with no row selected while the service quietly uses
    /// the default anyway. Idempotent; called at launch.
    static func normalizeStoredSelection(_ defaults: UserDefaults = .standard) {
        guard let id = defaults.string(forKey: "model.id"),
              !all.contains(where: { $0.id == id }) else { return }
        defaults.set(`default`.id, forKey: "model.id")
    }
}
