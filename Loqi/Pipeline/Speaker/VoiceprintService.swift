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

        var lastError: Error?
        for attempt in 0..<3 {
            do {
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
                return
            } catch is CancellationError {
                state = .unloaded
                throw CancellationError()
            } catch {
                lastError = error
                logger.error("voiceprint model load attempt \(attempt + 1) failed: \(error)")
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(Double(1 << (attempt + 1))))
                }
            }
        }
        let message = lastError?.localizedDescription ?? "Unknown error"
        state = .failed(message)
        throw lastError ?? VoiceprintError.loadFailed(message)
    }

    private func noteProgress(_ fraction: Double) {
        if case .downloading = state {
            state = .downloading(fraction)
        }
    }

    func unload() {
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
    func beginUtterance() {
        window.removeAll(keepingCapacity: true)
        utteranceSnapshot.removeAll(keepingCapacity: true)
    }

    /// Call at VAD speech-end to freeze the utterance's audio for embedding.
    func endUtterance() {
        if window.count >= minWindowSamples {
            utteranceSnapshot = window
        }
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
        var slot: Int
    }

    private var maxClusters = 0
    private var utteranceMemory: [RememberedUtterance] = []
    private let memoryLimit = 60

    /// Begin grouping utterances into at most `maxSpeakers` voices.
    /// Calling again mid-session re-clusters everything heard so far into
    /// the new cap and reports the relabels.
    @discardableResult
    func startDiarization(maxSpeakers: Int) -> [(UUID, Int)] {
        maxClusters = maxSpeakers
        guard maxSpeakers >= 2 else {
            utteranceMemory.removeAll()
            return []
        }
        return reclusterMemory()
    }

    var isDiarizing: Bool { maxClusters >= 2 }

    func stopDiarization() {
        maxClusters = 0
        utteranceMemory.removeAll()
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
        guard window.count >= minWindowSamples else {
            logger.info("assign skipped: window \(self.window.count) samples < \(self.minWindowSamples)")
            return nil
        }
        let samples = currentUtteranceSamples
        guard let probe = embed(samples) else {
            logger.warning("assign skipped: embedding failed for \(samples.count) samples")
            return nil
        }

        utteranceMemory.append(RememberedUtterance(
            entryID: entryID, embedding: probe, slot: -1))
        if utteranceMemory.count > memoryLimit {
            utteranceMemory.removeFirst(utteranceMemory.count - memoryLimit)
        }

        let relabels = reclusterMemory()
        guard let slot = utteranceMemory.last?.slot else { return nil }
        // The new entry's slot is returned directly; don't also report it
        // as a relabel.
        return (slot, relabels.filter { $0.0 != entryID })
    }

    /// Re-run agglomerative clustering over the full memory and update
    /// stored slots; returns every (entryID, newSlot) that changed.
    private func reclusterMemory() -> [(UUID, Int)] {
        guard !utteranceMemory.isEmpty else { return [] }
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: utteranceMemory.map(\.embedding),
            maxClusters: maxClusters)
        var relabels: [(UUID, Int)] = []
        for index in utteranceMemory.indices where utteranceMemory[index].slot != labels[index] {
            utteranceMemory[index].slot = labels[index]
            relabels.append((utteranceMemory[index].entryID, labels[index]))
        }
        let clusterCount = Set(labels).count
        logger.info("recluster: \(self.utteranceMemory.count) utterances → \(clusterCount) speakers (cap \(self.maxClusters)), \(relabels.count) relabels")
        return relabels
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
