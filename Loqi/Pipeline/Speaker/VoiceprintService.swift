import AVFoundation
import FluidAudio
import Foundation
import os

/// Whole-file (offline) speaker diarization for imports and re-transcribe:
/// FluidAudio's Pyannote Community-1 pipeline (powerset segmentation +
/// WeSpeaker + VBx) processes a complete recording at once, far more
/// accurately than per-utterance embeddings. Live captions use
/// [StreamingDiarizer] (below) instead.
///
/// Stateless: each call builds and tears down its own CoreML manager —
/// imports are occasional and CoreML keeps the compiled models on disk.
actor VoiceprintService {
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

// MARK: - Live streaming diarization (Sortformer)

/// Live speaker diarization via FluidAudio's Streaming Sortformer — an
/// end-to-end model that assigns frame-level speaker labels (up to 4 voices,
/// the public model's hard cap) as audio streams in. Replaces the old
/// per-utterance embedding + agglomerative clustering: Sortformer handles
/// overlap and fast turn-taking natively and keeps speaker identities stable
/// for the whole session, so attribution is just a time-overlap lookup
/// against its timeline (the same [SpeakerAttribution] the import path uses).
///
/// Session-scoped: nothing is enrolled or persisted; each session diarizes
/// from scratch. Lives beside `VoiceprintService` (its offline counterpart)
/// so both share this file's imports; the project compiles it into both the
/// iOS and macOS targets without a separate file reference.
actor StreamingDiarizer {
    enum State: Sendable, Equatable {
        case unloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .unloaded

    /// Sortformer's fixed slot count — the public model has exactly 4 speaker
    /// tracks. The caption picker's higher values clamp to this.
    static let maxSupportedSpeakers = 4

    /// Sortformer's CoreML bundle, roughly. FluidAudio doesn't publish exact
    /// sizes; the onboarding/Settings speedometers scale their fraction by
    /// this, so an approximation only skews the MB/s readout, never progress.
    nonisolated static let approximateDownloadBytes: Int64 = 80_000_000

    private var diarizer: SortformerDiarizer?
    private var loadTask: Task<Void, Error>?
    private var active = false
    /// Seconds of audio actually fed to the model — the time base for
    /// attribution. Counted only past the ready guard so it stays aligned
    /// with what Sortformer's timeline has seen. Reset per session.
    private var audioSecondsFed: Double = 0

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "streaming-diarizer")

    /// Lowest-latency v2.1 weights (~1s latency). `.default` has no model
    /// variant — it can't resolve a downloadable bundle — so use `.fastV2_1`.
    private nonisolated static var config: SortformerConfig { .fastV2_1 }

    /// True when the streaming model files already sit in FluidAudio's cache,
    /// so loading needs no network.
    nonisolated static var isModelCached: Bool {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models")
        guard let bundle = ModelNames.Sortformer.bundle(for: config) else { return false }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(bundle).path)
    }

    // MARK: Model lifecycle

    /// Download (when needed) and load the Sortformer model. Safe to call
    /// repeatedly and concurrently — a second caller joins the in-flight load.
    /// Honors the chosen mirror via `ModelRegistry.baseURL` (DownloadUtils
    /// builds every URL through it), so HF-mirror users are covered.
    func loadIfNeeded(
        source: DiarizerSource = .huggingFace,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if state == .ready { return }
        if let loadTask {
            return try await loadTask.value
        }
        let task = Task { try await performLoad(source: source, onProgress: onProgress) }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func performLoad(
        source: DiarizerSource,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws {
        state = .downloading(0)
        ModelRegistry.baseURL = source.baseURL
        do {
            try await withExponentialBackoff(attempts: 3) {
                let models = try await SortformerModels.loadFromHuggingFace(
                    config: Self.config
                ) { [weak self] progress in
                    onProgress?(progress.fractionCompleted)
                    Task { await self?.noteProgress(progress.fractionCompleted) }
                }
                state = .loading
                let manager = SortformerDiarizer(config: Self.config)
                manager.initialize(models: models)
                diarizer = manager
                state = .ready
                logger.info("streaming diarizer ready (source: \(source.rawValue))")
            }
        } catch is CancellationError {
            state = .unloaded
            throw CancellationError()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func noteProgress(_ fraction: Double) {
        if case .downloading = state {
            state = .downloading(fraction)
        }
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        diarizer?.cleanup()
        diarizer = nil
        active = false
        state = .unloaded
    }

    // MARK: Streaming

    /// Begin a fresh diarization stream. Resets the timeline and audio clock;
    /// safe to call before the model finishes loading (ingest no-ops until
    /// ready).
    func start() {
        active = true
        audioSecondsFed = 0
        diarizer?.reset()
    }

    func stop() {
        active = false
        _ = try? diarizer?.finalizeSession()
    }

    var isDiarizing: Bool { active }

    /// Audio time the model has seen, in seconds — the base for utterance
    /// bounds passed to `attribute`.
    var audioSeconds: Double { audioSecondsFed }

    /// Feed a chunk (a tee of the ASR stream) and advance the timeline.
    /// Sortformer resamples to its 16 kHz mono rate itself.
    func ingest(_ chunk: AudioCaptureService.AudioChunk) {
        guard active, state == .ready, let diarizer else { return }
        let buffer = chunk.buffer
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rate = buffer.format.sampleRate
        do {
            try diarizer.addAudio(samples, sourceSampleRate: rate)
            audioSecondsFed += Double(samples.count) / rate
        } catch {
            logger.debug("streaming diarizer addAudio failed: \(error.localizedDescription)")
            return
        }
        _ = try? diarizer.process()
    }

    /// The speaker slot whose timeline segments overlap `[start, end]` most,
    /// or nil when nothing overlaps within tolerance. Slot = Sortformer's
    /// arrival-order speaker index, stable for the whole session.
    func attribute(start: TimeInterval, end: TimeInterval) -> Int? {
        SpeakerAttribution.attribute(
            utterances: [(start, end)], to: currentSegments()).first ?? nil
    }

    /// Current timeline mapped to attribution segments — finalized first,
    /// then tentative (recent audio Sortformer hasn't confirmed yet), so a
    /// just-finalized utterance whose tail is still tentative still attributes.
    private func currentSegments() -> [SpeakerAttribution.Segment] {
        guard let diarizer else { return [] }
        var segments: [SpeakerAttribution.Segment] = []
        for speaker in diarizer.timeline.speakers.values {
            for segment in speaker.finalizedSegments + speaker.tentativeSegments {
                segments.append(.init(
                    slot: segment.speakerIndex,
                    start: TimeInterval(segment.startTime),
                    end: TimeInterval(segment.endTime)))
            }
        }
        return segments
    }
}
