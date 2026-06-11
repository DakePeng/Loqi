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
    /// Free memory required before loading, in bytes.
    let requiredHeadroom: UInt64
    /// Approximate download size in bytes — used only to turn the
    /// fraction-complete progress into a human-readable size/speed readout.
    let downloadBytes: Int64
}

enum ModelCatalog {
    // Standard uniform 4-bit quant. The OptiQ mixed-precision variant
    // produced gibberish with mlx-swift-lm 3.31.3 (its per-layer
    // quantization_mode is not applied) — don't switch back without testing.
    static let qwen35_2b = ModelOption(
        id: "mlx-community/Qwen3.5-2B-4bit",
        displayName: "Qwen3.5 2B — recommended",
        requiredHeadroom: 1_800_000_000,
        downloadBytes: 1_300_000_000)

    /// Known-good fallback if the 2B model is unavailable on the chosen
    /// source or quality regresses.
    static let qwen3_1_7b = ModelOption(
        id: "mlx-community/Qwen3-1.7B-4bit",
        displayName: "Qwen3 1.7B — fallback",
        requiredHeadroom: 1_600_000_000,
        downloadBytes: 1_000_000_000)

    /// Lightest tier (~620MB): fastest refinements and least contention
    /// with ASR, at noticeably lower translation quality.
    static let qwen35_0_8b = ModelOption(
        id: "mlx-community/Qwen3.5-0.8B-4bit",
        displayName: "Qwen3.5 0.8B — fastest",
        requiredHeadroom: 900_000_000,
        downloadBytes: 620_000_000)

    static let `default` = qwen35_2b
    static let all = [qwen35_2b, qwen3_1_7b, qwen35_0_8b]

    static func option(for id: String) -> ModelOption {
        all.first { $0.id == id } ?? `default`
    }
}
