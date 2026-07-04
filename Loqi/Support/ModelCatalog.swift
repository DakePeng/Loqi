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

    /// Experimental text-only 8B (Qwen3-8B arch), ternary weights stored in
    /// MLX 2-bit format — which stock mlx-swift loads out of the box (the
    /// 1-bit build needs a custom fork and aborts: upstream MLX `quantize`
    /// only supports 2/3/4/5/6/8 bits). No vision tower, so when picked, photo
    /// description routes to the live VLM (see SummaryJobCenter). Hidden behind
    /// `model.bonsaiEnabled` (off by default).
    static let bonsai8b = ModelOption(
        id: "prism-ml/Ternary-Bonsai-8B-mlx-2bit",
        displayName: "Bonsai 8B (ternary 2-bit) — experimental",
        requiredHeadroom: 3_000_000_000,   // ~2.3 GB weights + cache; tune on device
        downloadBytes: 2_300_000_000,
        supportsVision: false)

    static let `default` = qwen35_2b
    /// Model that runs *during* a live recording for photo description:
    /// the fast, low-memory, low-heat vision-capable tier. Always 0.8B
    /// regardless of the user's quality pick, so live photo description and
    /// the post-session vision back-fill (see SummaryJobCenter) never load
    /// the heavy VLM beside SenseVoice's in-process ONNX. This never changes
    /// — `liveRefineModel` below is the swappable one.
    static let liveModel = qwen35_0_8b

    /// Experimental text-only 230M live-refine candidate (Liquid AI's
    /// LFM2.5), first-party MLX port — mlx-swift-lm 3.31.3 already ships
    /// `LFM2.swift`, so no fork is needed (config.json model_type "lfm2").
    /// No vision tower: while active, a photo attached live falls back to
    /// OCR-only (AttachmentDescribeQueue already treats every
    /// `describeImage` failure as best-effort). Hidden behind
    /// `model.liveRefineLFM2Enabled` (off by default); the same flag also
    /// lists it in the summary lineup for A/B against the Qwen tiers.
    static let lfm2_5_230m = ModelOption(
        id: "LiquidAI/LFM2.5-230M-MLX-4bit",
        displayName: "Liquid LFM2.5 230M — experimental",
        requiredHeadroom: 300_000_000,   // ~151 MB weights; tune on device
        downloadBytes: 151_000_000,
        supportsVision: false)

    /// Whether the experimental LFM2.5 live-refine tier replaces the fixed
    /// 0.8B during recording. Off by default.
    static func liveRefineLFM2Enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "model.liveRefineLFM2Enabled")
    }

    /// Model `CaptionPipeline` loads during recording for translation
    /// refinement and live notes (text-only path; never touches vision).
    /// Defaults to `liveModel`; swaps to the LFM2.5 candidate when the
    /// experimental flag is on.
    static func liveRefineModel(_ defaults: UserDefaults = .standard) -> ModelOption {
        liveRefineLFM2Enabled(defaults) ? lfm2_5_230m : liveModel
    }

    /// Model post-session summary / title / vocabulary runs on: the user's
    /// quality pick (default 2B). Equals `liveModel` when the user picked the
    /// fast tier, in which case the boundary swap is a no-op.
    static var summaryModel: ModelOption { current }

    /// Whether the experimental Bonsai tier is offered. Off by default; it
    /// needs the 1-bit-kernel mlx-swift fork present to actually load.
    static func bonsaiEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "model.bonsaiEnabled")
    }

    /// Selectable summary models. The experimental text-only tiers (Bonsai,
    /// LFM2.5) appear only while their flags are set; the vision role never
    /// uses them.
    static func availableModels(defaults: UserDefaults = .standard) -> [ModelOption] {
        var lineup = [qwen35_2b, qwen35_0_8b]
        if bonsaiEnabled(defaults) { lineup.append(bonsai8b) }
        if liveRefineLFM2Enabled(defaults) { lineup.append(lfm2_5_230m) }
        return lineup
    }

    static var all: [ModelOption] { availableModels() }

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
              !availableModels(defaults: defaults).contains(where: { $0.id == id })
        else { return }
        defaults.set(`default`.id, forKey: "model.id")
    }
}
