import AVFoundation
import Foundation
import os

/// High-accuracy live recognition via SenseVoice-small (sherpa-onnx):
/// silero VAD segments speech, and the non-streaming recognizer is driven in
/// a pseudo-streaming pattern — the growing utterance is re-decoded every
/// ~0.7s for volatile captions, and the VAD-bounded segment gets a final
/// decode at the pause. Captions update in pulses rather than word-by-word;
/// in exchange, accuracy (especially zh/ja/ko) is far above the system
/// recognizer.
actor SenseVoiceEngine: SpeechEngine {
    nonisolated let language: AppLanguage

    private var vad: SherpaOnnxVoiceActivityDetectorWrapper?
    private var decoder: SenseVoiceDecoder?
    private var eventContinuation: AsyncStream<TranscriptionEvent>.Continuation?

    /// Samples of the current speech run (our own copy — the VAD only
    /// exposes a segment once it has ENDED, partials need live audio).
    private var utterance: [Float] = []
    /// Rolling pre-roll so a partial doesn't clip the first syllable
    /// (VAD detection lags speech onset slightly).
    private var preRoll: [Float] = []
    private var speaking = false
    /// Bumped on every finalized segment; stale partial decodes compare
    /// against it and discard themselves instead of resurrecting old text
    /// as a fresh volatile entry.
    private var generation = 0
    private var samplesSincePartial = 0
    private var partialInFlight = false
    /// FIFO chain for final decodes: finalized events must be emitted in
    /// segment order even though decoding is async.
    private var finalTail: Task<Void, Never>?

    private static let sampleRate = 16_000
    private static let partialInterval = 11_200      // 0.7s
    private static let preRollSamples = 8_000        // 0.5s
    private static let maxUtteranceSamples = 16_000 * 20

    private let logger = Logger(subsystem: "com.kunzhipeng.locally", category: "sensevoice")

    init(language: AppLanguage) {
        self.language = language
    }

    func prepare(contextualStrings: [String] = []) async throws -> AVAudioFormat {
        guard SenseVoiceModelStore.isInstalled else {
            throw SenseVoiceError.modelMissing
        }
        decoder = SenseVoiceDecoder(language: language)

        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: SenseVoiceModelStore.fileURL("silero_vad.onnx").path,
                threshold: 0.5,
                minSilenceDuration: 0.5,
                minSpeechDuration: 0.25,
                windowSize: 512,
                // Force a finalized segment mid-monologue so long speech
                // doesn't postpone translation/refinement indefinitely.
                maxSpeechDuration: 12),
            sampleRate: Int32(Self.sampleRate),
            numThreads: 1)
        vad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig, buffer_size_in_seconds: 60)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false)
        else { throw TranscriptionError.noCompatibleAudioFormat }
        logger.info("SenseVoice prepared for \(self.language.rawValue)")
        return format
    }

    func start() async throws -> AsyncStream<TranscriptionEvent> {
        guard vad != nil, decoder != nil else {
            throw TranscriptionError.notPrepared
        }
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream()
        eventContinuation = continuation
        utterance = []
        preRoll = []
        speaking = false
        generation = 0
        samplesSincePartial = 0
        return events
    }

    func feed(_ chunk: AudioCaptureService.AudioChunk) {
        guard let vad else { return }
        let buffer = chunk.buffer
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard !samples.isEmpty else { return }

        vad.acceptWaveform(samples: samples)

        let nowSpeaking = vad.isSpeechDetected()
        if nowSpeaking != speaking {
            speaking = nowSpeaking
            if nowSpeaking {
                utterance = preRoll
                samplesSincePartial = 0
            }
            emit(.speechActivity(nowSpeaking))
        }

        if speaking {
            utterance.append(contentsOf: samples)
            if utterance.count > Self.maxUtteranceSamples {
                utterance.removeFirst(utterance.count - Self.maxUtteranceSamples)
            }
            samplesSincePartial += samples.count
            maybeDecodePartial()
        } else {
            preRoll.append(contentsOf: samples)
            if preRoll.count > Self.preRollSamples {
                preRoll.removeFirst(preRoll.count - Self.preRollSamples)
            }
        }

        drainFinalizedSegments()
    }

    func stop() async {
        // Flush forces the VAD to close a segment that's still open, so the
        // speaker's last words are finalized rather than dropped.
        vad?.flush()
        drainFinalizedSegments()
        await finalTail?.value
        finalTail = nil
        emit(.ended(nil))
        eventContinuation?.finish()
        eventContinuation = nil
        vad = nil
        decoder = nil
        utterance = []
        preRoll = []
    }

    /// SenseVoice (CTC) has no contextual-string biasing; the pipeline's
    /// deterministic HotwordMatcher fixup still applies downstream.
    func applyContextualStrings(_ strings: [String]) async throws {}

    // MARK: Decoding

    private func maybeDecodePartial() {
        guard samplesSincePartial >= Self.partialInterval,
              !partialInFlight,
              let decoder else { return }
        partialInFlight = true
        samplesSincePartial = 0
        let snapshot = utterance
        let startedGeneration = generation
        Task { [weak self] in
            let text = await decoder.decode(snapshot)
            await self?.deliverPartial(text, from: startedGeneration)
        }
    }

    private func deliverPartial(_ text: String, from startedGeneration: Int) {
        partialInFlight = false
        // A segment finalized while this decode ran: its text supersedes
        // the partial, which must not reopen a volatile entry.
        guard startedGeneration == generation, speaking else { return }
        if !text.isEmpty {
            emit(.volatile(text))
        }
    }

    private func drainFinalizedSegments() {
        guard let vad, let decoder else { return }
        while !vad.isEmpty() {
            let samples = vad.front().samples
            vad.pop()
            generation += 1
            let previous = finalTail
            finalTail = Task { [weak self] in
                await previous?.value
                let text = await decoder.decode(samples)
                await self?.deliverFinal(text)
            }
        }
    }

    private func deliverFinal(_ text: String) {
        guard !text.isEmpty else { return }
        emit(.finalized(text))
    }

    private func emit(_ event: TranscriptionEvent) {
        eventContinuation?.yield(event)
    }
}

/// Owns the sherpa-onnx recognizer on its own actor so a 0.3–0.8s decode
/// never blocks `feed` — audio consumption (recording, diarization) must
/// stay real-time. Shared with `SenseVoiceFileTranscriber` for imports.
actor SenseVoiceDecoder {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    func decode(_ samples: [Float]) -> String {
        if recognizer == nil {
            var config = sherpaOnnxOfflineRecognizerConfig(
                featConfig: sherpaOnnxFeatureConfig(),
                modelConfig: sherpaOnnxOfflineModelConfig(
                    tokens: SenseVoiceModelStore.fileURL("tokens.txt").path,
                    numThreads: 2,
                    senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                        model: SenseVoiceModelStore.fileURL("model.int8.onnx").path,
                        language: language.senseVoiceCode,
                        useInverseTextNormalization: true)))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        }
        guard let recognizer else { return "" }
        return recognizer.decode(samples: samples)
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AppLanguage {
    /// Language hint for the SenseVoice model.
    var senseVoiceCode: String {
        switch self {
        case .english: "en"
        case .chinese: "zh"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }
}

enum SenseVoiceError: LocalizedError {
    case modelMissing

    var errorDescription: String? {
        String(localized: "Download the SenseVoice model in Settings first, or switch to Apple recognition.")
    }
}
