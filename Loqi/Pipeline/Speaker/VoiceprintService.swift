import AVFoundation
import FluidAudio
import Foundation
import os

/// Whole-file (offline) speaker diarization: FluidAudio's Pyannote
/// Community-1 pipeline (powerset segmentation + WeSpeaker + VBx)
/// processes a complete recording at once, far more accurately than any
/// streaming pass. The ONLY diarizer — live recordings get their speaker
/// labels from the post-process pass over the saved audio (the old live
/// Sortformer cost more heat next to ASR + the LLM than it was worth).
///
/// Stateless: each call builds and tears down its own CoreML manager —
/// imports are occasional and CoreML keeps the compiled models on disk.
actor VoiceprintService {
    /// Speaker-picker ceiling for explicit counts; "Auto" (-1) discovers
    /// up to `clusterCap`'s generous limit on its own.
    nonisolated static let maxSupportedSpeakers = 4

    /// Rough bundle size for download speedometers only — an approximation
    /// skews the MB/s readout, never progress.
    nonisolated static let approximateDownloadBytes: Int64 = 80_000_000

    /// Map the speaker-picker value to a clustering cap: 2+ = hard cap,
    /// -1 ("Auto") = discover the count under a generous ceiling, 0/1 = nil
    /// (diarization off).
    static func clusterCap(forPickerValue value: Int) -> Int? {
        switch value {
        case -1: 8
        case 2...: value
        default: nil
        }
    }

    /// Pre-download the offline model bundle (Settings / onboarding), so
    /// the first post-process or import needs no network.
    static func downloadModels(
        source: DiarizerSource,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        ModelRegistry.baseURL = source.baseURL
        _ = try await withExponentialBackoff(attempts: 3) {
            try await OfflineDiarizerModels.load { progress in
                onProgress?(progress.fractionCompleted)
            }
        }
    }

    /// Whether the offline file-diarization model bundle is already cached on
    /// disk. Derives the path exactly as FluidAudio's loader does so it can't
    /// drift from where `diarizeFile` looks. Lets the import flow ask consent
    /// before a first-use network download instead of fetching silently.
    nonisolated static var isOfflineDiarizerDownloaded: Bool {
        let repoDir = OfflineDiarizerModels.defaultModelsDirectory()
            .appendingPathComponent(Repo.diarizer.folderName)
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(
                atPath: repoDir.appendingPathComponent($0).path)
        }
    }

    enum FileDiarizationProgress: Sendable {
        case download(Double)
        case analysis(Double)
    }

    /// Diarize a complete audio file with FluidAudio's offline pipeline.
    /// The model bundle downloads on first use (honoring the chosen mirror).
    /// Returns segments with dense slot numbers by first appearance.
    func diarizeFile(
        url: URL,
        maxSpeakers: Int,
        source: DiarizerSource = .huggingFace,
        onProgress: (@Sendable (FileDiarizationProgress) -> Void)? = nil
    ) async throws -> [SpeakerAttribution.Segment] {
        ModelRegistry.baseURL = source.baseURL
        var clustering = OfflineDiarizerConfig.Clustering.community
        clustering.maxSpeakers = max(2, maxSpeakers)
        let manager = OfflineDiarizerManager(
            config: OfflineDiarizerConfig(clustering: clustering))

        // A cache hit still drives this callback while CoreML compiles the
        // models from disk — surface the download phase only when a real
        // network fetch will happen.
        let needsDownload = !Self.isOfflineDiarizerDownloaded
        let models = try await withExponentialBackoff(attempts: 3) {
            try await OfflineDiarizerModels.load { progress in
                guard needsDownload else { return }
                onProgress?(.download(progress.fractionCompleted))
            }
        }
        manager.initialize(models: models)

        let result = try await manager.process(url) { done, total in
            onProgress?(.analysis(Double(done) / Double(max(total, 1))))
        }

        let ordered = result.segments.sorted {
            $0.startTimeSeconds < $1.startTimeSeconds
        }
        var slotByID: [String: Int] = [:]
        return ordered.map { segment in
            let slot = slotByID[
                segment.speakerId, default: slotByID.count]
            slotByID[segment.speakerId] = slot
            return SpeakerAttribution.Segment(
                slot: slot,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds))
        }
    }
}
