import AVFoundation
import FluidAudio
import Foundation
import os

/// Speaker embeddings for diarization: live captions and audio import group
/// utterances into voices entirely on-device, per session — nothing is
/// enrolled or persisted.
actor VoiceprintService {
    enum State: Sendable, Equatable {
        case unloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .unloaded
    private var diarizer: DiarizerManager?

    /// Rolling window of the current utterance (16kHz mono samples).
    private var window: [Float] = []
    private let maxWindowSamples = 16_000 * 3
    /// Minimum audio for a usable embedding.
    private let minWindowSamples = 16_000

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "voiceprint")

    // MARK: Model lifecycle

    /// FluidAudio segmentation + embedding models, ~50 MB total. Approximate:
    /// FluidAudio doesn't publish exact sizes, so progress readouts scale
    /// their fraction by this.
    nonisolated static let approximateDownloadBytes: Int64 = 50_000_000

    /// True when the model files already sit in FluidAudio's cache —
    /// loading then needs no network at all.
    nonisolated static var isModelCached: Bool {
        let directory = DiarizerModels.defaultModelsDirectory()
        return ModelNames.Diarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0).path)
        }
    }

    private var loadTask: Task<Void, Error>?

    /// Download (~tens of MB) and compile the segmentation + embedding
    /// models. Safe to call repeatedly and concurrently — a second caller
    /// joins the in-flight load. Retries transient network failures with
    /// backoff; FluidAudio itself wipes and re-fetches corrupted caches.
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
        // FluidAudio builds all model URLs from this registry base; the
        // mirror serves identical paths.
        ModelRegistry.baseURL = source.baseURL

        do {
            try await withExponentialBackoff(attempts: 3) {
                let models = try await DiarizerModels.downloadIfNeeded { [weak self] progress in
                    onProgress?(progress.fractionCompleted)
                    Task { await self?.noteProgress(progress.fractionCompleted) }
                }
                state = .loading
                let manager = DiarizerManager()
                manager.initialize(models: models)
                diarizer = manager
                state = .ready
                logger.info("voiceprint models ready (source: \(source.rawValue))")
            }
        } catch is CancellationError {
            state = .unloaded
            throw CancellationError()
        } catch {
            let message = error.localizedDescription
            state = .failed(message)
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
        state = .unloaded
    }

    // MARK: Audio window

    /// The embedding models are trained on 16kHz mono; the ASR stream may
    /// run at a different rate, so resample defensively.
    private let embeddingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!
    private var resampler: AVAudioConverter?

    /// Feed converted audio (tee of the stream the ASR consumes).
    func ingest(_ chunk: AudioCaptureService.AudioChunk) {
        guard state == .ready else { return }
        let buffer = chunk.buffer
        let samples: [Float]
        if buffer.format.sampleRate == embeddingFormat.sampleRate,
           buffer.format.channelCount == 1,
           let channel = buffer.floatChannelData?[0] {
            samples = Array(UnsafeBufferPointer(
                start: channel, count: Int(buffer.frameLength)))
        } else {
            samples = resampleTo16k(buffer)
        }
        window.append(contentsOf: samples)
        if window.count > maxWindowSamples {
            window.removeFirst(window.count - maxWindowSamples)
        }
    }

    private func resampleTo16k(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if resampler == nil || resampler?.inputFormat != buffer.format {
            resampler = AVAudioConverter(from: buffer.format, to: embeddingFormat)
        }
        guard let converter = resampler else { return [] }
        let ratio = embeddingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(
            pcmFormat: embeddingFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        converter.convert(to: output, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard output.frameLength > 0, let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    /// Snapshot taken at VAD speech-end: by ASR-finalize time the *next*
    /// speaker may already be talking into the rolling window, so the
    /// cleanest single-speaker audio is what existed when speech stopped.
    private var utteranceSnapshot: [Float] = []

    /// Call at utterance start so the window holds one speaker's audio.
    /// The snapshot is deliberately kept: the previous utterance's ASR
    /// final is often still in flight when the next speaker starts, and it
    /// must embed the audio of the utterance it describes — wiping here
    /// made fast turn-taking attribute one speaker's words to the next
    /// voice. `endUtterance` replaces the snapshot instead.
    func beginUtterance() {
        window.removeAll(keepingCapacity: true)
    }

    /// Call at VAD speech-end to freeze the utterance's audio for embedding.
    /// A too-short utterance clears the snapshot rather than keeping the
    /// previous one — better unattributed than the previous speaker's voice.
    func endUtterance() {
        utteranceSnapshot = window.count >= minWindowSamples ? window : []
    }

    /// The cleanest single-speaker audio available: the VAD speech-end
    /// snapshot when valid, else the live rolling window — embedding the
    /// live window at ASR-finalize time can pick up the next speaker.
    private var currentUtteranceSamples: [Float] {
        utteranceSnapshot.count >= minWindowSamples ? utteranceSnapshot : window
    }

    // MARK: Diarization

    /// Session-scoped diarization state; not persisted — each captions
    /// session diarizes from scratch. Every utterance's embedding is
    /// remembered (capped) and the WHOLE memory is re-clustered after each
    /// new utterance: the declared speaker count acts as a cap, never a
    /// target, so one voice stays one speaker regardless of the picker.
    private struct RememberedUtterance {
        let entryID: UUID
        let embedding: [Float]
        /// Audio length in seconds — short clips give noisy embeddings, so
        /// clustering demands more corroboration before they found a speaker.
        let seconds: Double
        var slot: Int
    }

    private var maxClusters = 0
    private var utteranceMemory: [RememberedUtterance] = []
    private let memoryLimit = 60
    /// Slot centroids by slot number, including slots whose utterances have
    /// all aged out of memory — a returning voice reclaims its old number.
    /// Slot numbers are therefore stable for the whole session (the speaker
    /// cap bounds concurrent clusters, not total slots ever minted).
    private var slotCentroids: [[Float]] = []

    /// Map the speaker-picker value to a clustering cap: 2+ = hard cap,
    /// -1 ("Auto") = discover the count by voice similarity under a
    /// generous ceiling, 0/1 = nil (diarization off). Safe because the
    /// cap is a ceiling, never a target — clustering merges by the
    /// similarity threshold first and only forces merges above the cap.
    static func clusterCap(forPickerValue value: Int) -> Int? {
        switch value {
        case -1: 8
        case 2...: value
        default: nil
        }
    }

    /// Whether the offline file-diarization model bundle (FluidAudio) is
    /// already cached on disk. Derives the path exactly as FluidAudio's loader
    /// does — same models directory, repo folder, and required model files —
    /// so it can't drift from where `diarizeFile` will actually look. Lets the
    /// import flow ask for consent before a first-use network download instead
    /// of fetching gigabytes silently (e.g. on cellular).
    nonisolated static var isOfflineDiarizerDownloaded: Bool {
        let repoDir = OfflineDiarizerModels.defaultModelsDirectory()
            .appendingPathComponent(Repo.diarizer.folderName)
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(
                atPath: repoDir.appendingPathComponent($0).path)
        }
    }

    /// Begin grouping utterances into at most `maxSpeakers` voices.
    /// Calling again mid-session re-clusters everything heard so far into
    /// the new cap and reports the relabels.
    @discardableResult
    func startDiarization(maxSpeakers: Int) -> [(UUID, Int)] {
        maxClusters = maxSpeakers
        guard maxSpeakers >= 2 else {
            utteranceMemory.removeAll()
            slotCentroids.removeAll()
            return []
        }
        return reclusterMemory()
    }

    var isDiarizing: Bool { maxClusters >= 2 }

    func stopDiarization() {
        maxClusters = 0
        utteranceMemory.removeAll()
        slotCentroids.removeAll()
    }

    /// Assign the current utterance to a speaker slot (0-based), globally
    /// re-clustering all remembered utterances — earlier entries whose
    /// cluster membership changed are reported for relabeling on screen.
    /// Nil = leave the entry unattributed.
    func assignSpeaker(entryID: UUID) -> (slot: Int, relabels: [(UUID, Int)])? {
        guard isDiarizing else {
            logger.debug("assign skipped: diarization off")
            return nil
        }
        guard state == .ready else {
            logger.info("assign skipped: model state not ready")
            return nil
        }
        let samples = currentUtteranceSamples
        // Consume the speech-end snapshot: it stays alive across `beginUtterance`
        // so a late ASR-final embeds the utterance it describes, but it must be
        // used at most once — otherwise a second, later entry whose own snapshot
        // hasn't been frozen yet would be attributed to this (now stale) voice.
        // After consuming, the next assign falls back to the live window.
        utteranceSnapshot.removeAll(keepingCapacity: true)
        guard samples.count >= minWindowSamples else {
            logger.info("assign skipped: \(samples.count) samples < \(self.minWindowSamples)")
            return nil
        }
        guard let probe = embed(samples) else {
            logger.warning("assign skipped: embedding failed for \(samples.count) samples")
            return nil
        }

        utteranceMemory.append(RememberedUtterance(
            entryID: entryID, embedding: probe,
            seconds: Double(samples.count) / 16_000, slot: -1))
        if utteranceMemory.count > memoryLimit {
            utteranceMemory.removeFirst(utteranceMemory.count - memoryLimit)
        }
        // The whole-memory recluster below is O(n²) in this count, so the cap
        // is what keeps it cheap — guard against a future regression that lets
        // it grow unbounded.
        assert(utteranceMemory.count <= memoryLimit)

        let relabels = reclusterMemory()
        guard let slot = utteranceMemory.last?.slot else { return nil }
        // The new entry's slot is returned directly; don't also report it
        // as a relabel.
        return (slot, relabels.filter { $0.0 != entryID })
    }

    /// Re-run agglomerative clustering over the full memory, pin the
    /// resulting clusters to stable slot numbers via their centroids, and
    /// update stored slots; returns every (entryID, newSlot) that changed.
    ///
    /// The centroid step matters once the memory cap starts evicting:
    /// labels from a clustering pass are ordered by first appearance
    /// *within current memory*, so eviction would silently renumber voices
    /// while the evicted entries keep their old numbers on screen.
    private func reclusterMemory() -> [(UUID, Int)] {
        guard !utteranceMemory.isEmpty else { return [] }
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: utteranceMemory.map(\.embedding),
            maxClusters: maxClusters,
            durations: utteranceMemory.map(\.seconds))

        var membersByLabel: [Int: [Int]] = [:]
        for (index, label) in labels.enumerated() {
            membersByLabel[label, default: []].append(index)
        }
        let orderedLabels = membersByLabel.keys.sorted()
        let centroids = orderedLabels.map { label in
            VoiceprintMath.meanEmbedding(
                membersByLabel[label]!.map { utteranceMemory[$0].embedding })
        }
        let slotForLabel = VoiceprintMath.matchClustersToSlots(
            clusters: centroids, slots: slotCentroids)
        for (which, slot) in slotForLabel.enumerated() {
            if slot < slotCentroids.count {
                slotCentroids[slot] = centroids[which]
            } else {
                slotCentroids.append(centroids[which])
            }
        }

        var relabels: [(UUID, Int)] = []
        for index in utteranceMemory.indices {
            let slot = slotForLabel[labels[index]]
            if utteranceMemory[index].slot != slot {
                utteranceMemory[index].slot = slot
                relabels.append((utteranceMemory[index].entryID, slot))
            }
        }
        logger.info("recluster: \(self.utteranceMemory.count) utterances → \(orderedLabels.count) speakers (cap \(self.maxClusters)), \(relabels.count) relabels")
        return relabels
    }

    // MARK: Whole-file diarization (imports)

    enum FileDiarizationProgress: Sendable {
        case download(Double)
        case analysis(Double)
    }

    /// Diarize a complete audio file with FluidAudio's offline pipeline
    /// (Pyannote Community-1: powerset segmentation + WeSpeaker + VBx) —
    /// far more accurate than per-utterance embeddings, because the
    /// segmentation model masks out overlapping voices and VBx refines
    /// cluster boundaries over the whole recording at once. Its model
    /// bundle is separate from the live models and downloads on first use
    /// (honoring the chosen mirror). Nothing is cached in memory: imports
    /// are occasional and CoreML keeps the compiled models on disk.
    ///
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

        // Same transient-network retry as the live models; FluidAudio
        // wipes and re-fetches corrupted caches itself.
        // A cache hit still drives this callback while CoreML compiles the
        // models from disk — surface the download phase only when a real
        // network fetch will happen, so an installed model never shows
        // "Fetching speaker model".
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

    // MARK: Internals

    private func embed(_ samples: [Float]) -> [Float]? {
        guard let diarizer, samples.count >= minWindowSamples else { return nil }
        do {
            let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
            return diarizer.validateEmbedding(embedding) ? embedding : nil
        } catch {
            logger.debug("embedding failed: \(error)")
            return nil
        }
    }

}

enum VoiceprintError: LocalizedError {
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let reason):
            "Speaker model download failed: \(reason)"
        }
    }
}
