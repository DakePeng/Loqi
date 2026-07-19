import Foundation

/// Qwen3-ASR-0.6B was retired 2026-07: the autoregressive pass ran near
/// realtime (20-30 hot minutes per hour of audio); Dolphin + SenseVoice
/// now cover the accuracy pass. This file remains only so the
/// xcodegen-generated pbxproj needn't change — delete it on the next
/// project regen.
enum Qwen3ASRModelStore {
    /// One-time reclaim of the ~990 MB of weights on devices that had the
    /// model installed. Cheap when the directory is already gone.
    nonisolated static func deleteLeftoverFiles() {
        let directory = URL.applicationSupportDirectory
            .appending(path: "Qwen3ASR", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
    }
}
