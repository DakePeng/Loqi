import AVFoundation
import Foundation
import os

/// Whole-file (offline) speaker diarization on sherpa-onnx: pyannote
/// segmentation-3.0 (overlap-aware frame-level activity) + 3D-Speaker's
/// bilingual zh/en CAM++ embedding, fast-clustered. Replaced the
/// FluidAudio Pyannote bundle so the models mirror to ModelScope
/// (see DiarizerModelStore) and all audio ML runs on the one vendored
/// ONNX runtime. The ONLY diarizer — live recordings get their speaker
/// labels from the post-process pass over the saved audio.
actor VoiceprintService {
    /// Speaker-picker ceiling for explicit counts; "Auto" (-1) discovers
    /// up to `clusterCap`'s generous limit on its own.
    nonisolated static let maxSupportedSpeakers = 4

    /// Bundle size for download speedometers and the onboarding total.
    nonisolated static var approximateDownloadBytes: Int64 {
        DiarizerModelStore.totalExpectedBytes
    }

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

    /// Explicit picks force that cluster count (sherpa's fast clustering
    /// bypasses the threshold when the count is known — strongly preferred
    /// per its docs). "Auto" arrives as a cap above the picker ceiling and
    /// discovers the count by distance threshold instead. Pure for testing.
    nonisolated static func clustering(
        maxSpeakers: Int
    ) -> (numClusters: Int, threshold: Float) {
        maxSpeakers <= maxSupportedSpeakers
            ? (numClusters: maxSpeakers, threshold: 0)
            // ponytail: 0.5 is sherpa's reference default; tune on device
            // if Auto over/under-splits.
            : (numClusters: -1, threshold: 0.5)
    }

    /// Whether both model files are already on disk. Lets the import flow
    /// ask consent before a first-use network download.
    nonisolated static var isOfflineDiarizerDownloaded: Bool {
        DiarizerModelStore.isInstalled
    }

    enum FileDiarizationProgress: Sendable {
        case download(Double)
        case analysis(Double)
    }

    enum DiarizationError: LocalizedError {
        case unsupportedPlatform
        case modelLoadFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                String(localized: "Speaker separation isn't available on this platform.")
            case .modelLoadFailed:
                String(localized: "The speaker model couldn't be loaded — try re-downloading it.")
            }
        }
    }

    /// Pre-download the model bundle (Settings / onboarding), so the first
    /// post-process or import needs no network.
    static func downloadModels(
        source: ASRModelSource,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await DiarizerModelStore.download(from: source, onProgress: onProgress)
    }

    /// Diarize a complete audio file. Missing models download on first use
    /// (honoring the persisted source choice). Returns segments with dense
    /// slot numbers by first appearance, sorted by start time.
    func diarizeFile(
        url: URL,
        maxSpeakers: Int,
        source: ASRModelSource = DiarizerModelStore.currentSource,
        onProgress: (@Sendable (FileDiarizationProgress) -> Void)? = nil
    ) async throws -> [SpeakerAttribution.Segment] {
        #if os(iOS)
        if !DiarizerModelStore.isInstalled {
            try await DiarizerModelStore.download(from: source) {
                onProgress?(.download($0))
            }
        }
        let audioFile = try AVAudioFile(forReading: url)
        let samples = try await OfflineTranscriber.decodeMono16k(audioFile)

        let clustering = Self.clustering(maxSpeakers: maxSpeakers)
        var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                    model: DiarizerModelStore.segmentationModelURL.path)),
            embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(
                model: DiarizerModelStore.embeddingModelURL.path),
            clustering: sherpaOnnxFastClusteringConfig(
                numClusters: clustering.numClusters,
                threshold: clustering.threshold))
        guard let diarizer = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
        else { throw DiarizationError.modelLoadFailed }

        // One long synchronous C call: this actor's thread is blocked for
        // the analysis — the same shape the FluidAudio pipeline had, and
        // acceptable for an occasional post-process batch job.
        let raw = diarizer.process(samples: samples) { done, total in
            onProgress?(.analysis(Double(done) / Double(max(total, 1))))
        }

        var slotByID: [Int: Int] = [:]
        return raw.map { segment in
            let slot = slotByID[segment.speaker, default: slotByID.count]
            slotByID[segment.speaker] = slot
            return SpeakerAttribution.Segment(
                slot: slot,
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end))
        }
        #else
        // No sherpa runtime in the macOS target; diarization is gated off
        // upstream (postProcessBackend and the import sheet).
        throw DiarizationError.unsupportedPlatform
        #endif
    }
}
