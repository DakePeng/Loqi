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
    private static let logger = Logger(
        subsystem: "com.kunzhipeng.loqi", category: "diarize")
    /// Bundle size for download speedometers and the onboarding total.
    nonisolated static var approximateDownloadBytes: Int64 {
        DiarizerModelStore.totalExpectedBytes
    }

    /// Whether a speaker-picker value turns separation on: -1 ("Auto") or
    /// an explicit count of 2+. 0/1 = single voice, separation off.
    nonisolated static func separationEnabled(forPickerValue value: Int) -> Bool {
        value == -1 || value >= 2
    }

    /// Clustering config straight from the picker's intent. An explicit
    /// pick forces that EXACT cluster count — sherpa's fast clustering
    /// strongly prefers a known count, and "N speakers" in the import sheet
    /// means exactly N (unlike the old FluidAudio VBx path, this is not an
    /// upper cap). "Auto" (-1) discovers the count by distance threshold.
    /// Pure for testing.
    nonisolated static func clustering(
        forPickerValue value: Int
    ) -> (numClusters: Int, threshold: Float) {
        value >= 2
            ? (numClusters: value, threshold: 0)
            // Field-tuned twice: sherpa's reference 0.5 gave 30+ phantom
            // speakers on a real meeting, 0.75 still over-split. 0.9
            // merges aggressively — under-splitting is the lesser evil
            // (merged voices read fine; phantom ones don't) and the exact
            // picker count covers precision. The real over-split fuel is
            // micro-segments; see the minDuration knobs at the call site.
            : (numClusters: -1, threshold: 0.9)
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

    /// Diarize a complete audio file. `speakerCount` carries the picker's
    /// intent (-1 = Auto, 2+ = exact count). Missing models download on
    /// first use (honoring the persisted source choice). Returns segments
    /// with dense slot numbers by first appearance, sorted by start time.
    func diarizeFile(
        url: URL,
        speakerCount: Int,
        source: ASRModelSource = DiarizerModelStore.currentSource,
        onProgress: (@Sendable (FileDiarizationProgress) -> Void)? = nil
    ) async throws -> [SpeakerAttribution.Segment] {
        #if os(iOS)
        if !DiarizerModelStore.isInstalled {
            try await DiarizerModelStore.download(from: source) {
                onProgress?(.download($0))
            }
        }
        let samples = try await OfflineTranscriber.decodeMono16k(contentsOf: url)

        let clustering = Self.clustering(forPickerValue: speakerCount)
        Self.logger.info("diarize: \(samples.count / 16_000)s audio, picker=\(speakerCount), clusters=\(clustering.numClusters), threshold=\(clustering.threshold)")
        // Both ONNX sessions default to ONE thread — on an hour of audio
        // that made the sherpa pass minutes-slow where the old CoreML/ANE
        // path felt instant. This batch job owns the device (same
        // rationale as the offline decode pools), so give the sessions
        // real cores.
        let threads = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                    model: DiarizerModelStore.segmentationModelURL.path),
                numThreads: threads),
            embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(
                model: DiarizerModelStore.embeddingModelURL.path,
                numThreads: threads),
            clustering: sherpaOnnxFastClusteringConfig(
                numClusters: clustering.numClusters,
                threshold: clustering.threshold),
            // Sub-second speech islands produce junk CAM++ embeddings —
            // the main driver of Auto's phantom-speaker explosions (the
            // wrapper default keeps everything ≥0.3s). Dropping them
            // loses no words: attribution's nearest-gap rule labels those
            // entries from the neighboring segments.
            minDurationOn: 1.0,
            minDurationOff: 0.8)
        guard let diarizer = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
        else { throw DiarizationError.modelLoadFailed }

        // One long synchronous C call. Run it on a GCD thread via a
        // continuation so it never parks a Swift cooperative-pool thread
        // for minutes — the pool is core-count wide and shared with every
        // actor in the app. userInitiated, not utility: the user is
        // watching this progress row, and utility QoS parks CPU-bound
        // work on efficiency cores. Cancellation cannot interrupt the C
        // call itself (sherpa documents the progress callback's return
        // value as ignored), so the practical bound is checking before
        // it starts.
        try Task.checkCancellation()
        let raw = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: diarizer.process(samples: samples) { done, total in
                    onProgress?(.analysis(Double(done) / Double(max(total, 1))))
                })
            }
        }
        try Task.checkCancellation()

        var slotByID: [Int: Int] = [:]
        let segments = raw.map { segment in
            let slot = slotByID[segment.speaker, default: slotByID.count]
            slotByID[segment.speaker] = slot
            return SpeakerAttribution.Segment(
                slot: slot,
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end))
        }
        Self.logger.info("diarize: \(segments.count) segments, \(slotByID.count) speakers")
        return segments
        #else
        // No sherpa runtime in the macOS target; diarization is gated off
        // upstream (postProcessBackend and the import sheet).
        throw DiarizationError.unsupportedPlatform
        #endif
    }
}
