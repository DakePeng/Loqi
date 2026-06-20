import Foundation

/// LLM load state, kept separate from `LLMService` so UI code can switch on
/// it without importing MLX-heavy implementation details.
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
