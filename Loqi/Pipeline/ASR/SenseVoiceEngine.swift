import AVFoundation
import Foundation
import os

#if os(iOS)
/// High-accuracy live recognition via SenseVoice-small (sherpa-onnx):
/// silero VAD segments speech, and the non-streaming recognizer is driven in
/// a pseudo-streaming pattern — the growing utterance is re-decoded every
/// ~0.7s for volatile captions, and the VAD-bounded segment gets a final
/// decode at the pause. Captions update in pulses rather than word-by-word;
/// in exchange, accuracy (especially zh/ja/ko) is far above the system
/// recognizer.
actor SenseVoiceEngine: SpeechEngine {
    nonisolated let sourceSelection: RecognitionLanguageSelection

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
    /// Resolved from `perf.reduceHeat` at prepare() — see SenseVoiceTuning.
    private var partialInterval = SenseVoiceTuning.partialInterval(reduceHeat: false)
    /// FIFO chain for final decodes: finalized events must be emitted in
    /// segment order even though decoding is async.
    private var finalTail: Task<Void, Never>?
    /// Forces a segment split when steady noise keeps the VAD open past
    /// what the partial cap already shows (see SpeechRunLimiter).
    private var runLimiter = SpeechRunLimiter(limit: maxUtteranceSamples)

    /// Cumulative wall time spent in SenseVoice decode this session (partial
    /// + final), the ASR counterpart to LLMService.generateActiveSeconds.
    private(set) var decodeActiveSeconds: Double = 0

    /// False in the hybrid engine's record role: Apple supplies the
    /// volatile text, so the pulsing whole-utterance partial decodes —
    /// the live path's dominant heat cost — are skipped entirely. Finals,
    /// VAD, speech-activity edges, and language detection are unaffected.
    private var emitsPartials: Bool

    private static let sampleRate = 16_000
    private static let preRollSamples = 8_000        // 0.5s
    private static let maxUtteranceSamples = 16_000 * 20

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "sensevoice")

    init(sourceSelection: RecognitionLanguageSelection, emitsPartials: Bool = true) {
        self.sourceSelection = sourceSelection
        self.emitsPartials = emitsPartials
    }

    /// The hybrid engine flips this back on when its Apple child fails and
    /// it degrades to pure-SenseVoice behavior.
    func setEmitsPartials(_ enabled: Bool) {
        emitsPartials = enabled
    }

    func prepare(contextualStrings: [String] = []) async throws -> AVAudioFormat {
        guard SenseVoiceModelStore.isInstalled else {
            throw SenseVoiceError.modelMissing
        }
        let reduceHeat = UserDefaults.standard.bool(forKey: "perf.reduceHeat")
        partialInterval = SenseVoiceTuning.partialInterval(reduceHeat: reduceHeat)
        decoder = SenseVoiceDecoder(
            sourceSelection: sourceSelection,
            numThreads: SenseVoiceTuning.decoderThreads(reduceHeat: reduceHeat))

        // Threshold + hangover follow the user's pickup preset: far-field
        // speech is reverb-smeared (lower probability, soft tails that a
        // short hangover chops), close-up wants strict gating so background
        // voices stay out. FarFieldGain fixes the level upstream; this
        // tolerates the smear. Preset changes mid-session restart the turn,
        // so prepare() always sees the current choice.
        let sensitivity = MicSensitivity.current
        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: SenseVoiceModelStore.fileURL("silero_vad.onnx").path,
                threshold: sensitivity.sileroThreshold,
                minSilenceDuration: sensitivity.sileroMinSilence,
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
        logger.info("SenseVoice prepared for \(self.sourceSelection.rawValue)")
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
        runLimiter = SpeechRunLimiter(limit: Self.maxUtteranceSamples)
        return events
    }

    func feed(_ chunk: AudioCaptureService.AudioChunk) {
        guard let vad else { return }
        let buffer = chunk.buffer
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard !samples.isEmpty else { return }

        vad.acceptWaveform(samples: samples)

        // Hard split: flush closes the open segment at the current tail
        // (max_speech_duration alone never closes one in steady noise and
        // the VAD buffer grows unbounded). The segment drains below like a
        // natural pause; speech re-detects on the very next window.
        if runLimiter.shouldSplit(
            isSpeech: vad.isSpeechDetected(), samples: samples.count) {
            logger.warning("speech run hit \(Self.maxUtteranceSamples) samples; forcing VAD flush")
            vad.flush()
        }

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

    func resetHeatStats() {
        decodeActiveSeconds = 0
    }

    // MARK: Decoding

    private func maybeDecodePartial() {
        guard emitsPartials else { return }
        guard samplesSincePartial >= partialInterval,
              !partialInFlight,
              let decoder else { return }
        partialInFlight = true
        samplesSincePartial = 0
        let snapshot = utterance
        let startedGeneration = generation
        Task { [weak self] in
            let decodeStart = ContinuousClock.now
            let result = await decoder.decode(snapshot)
            let d = decodeStart.duration(to: .now)
            await self?.addDecodeActiveSeconds(d)
            await self?.deliverPartial(result, from: startedGeneration)
        }
    }

    private func deliverPartial(_ result: SenseVoiceRecognitionResult, from startedGeneration: Int) {
        partialInFlight = false
        // A segment finalized while this decode ran: its text supersedes
        // the partial, which must not reopen a volatile entry.
        guard startedGeneration == generation, speaking else { return }
        if !result.text.isEmpty {
            emit(.volatile(result.text, language: result.language))
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
                let decodeStart = ContinuousClock.now
                let result = await decoder.decode(samples)
                let d = decodeStart.duration(to: .now)
                await self?.addDecodeActiveSeconds(d)
                await self?.deliverFinal(result)
            }
        }
    }

    private func addDecodeActiveSeconds(_ duration: Duration) {
        decodeActiveSeconds += Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    private func deliverFinal(_ result: SenseVoiceRecognitionResult) {
        guard !result.text.isEmpty else { return }
        emit(.finalized(result.text, runs: nil, language: result.language))
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
    private let sourceSelection: RecognitionLanguageSelection
    private let numThreads: Int

    /// `numThreads` defaults to the live engine's 2; the offline file pass
    /// raises it (a batch decode owns the device) so each segment finishes
    /// sooner. The file transcriber sizes it against the decode-pool count.
    init(sourceSelection: RecognitionLanguageSelection, numThreads: Int = 2) {
        self.sourceSelection = sourceSelection
        self.numThreads = numThreads
    }

    func decode(_ samples: [Float]) -> SenseVoiceRecognitionResult {
        if recognizer == nil {
            var config = sherpaOnnxOfflineRecognizerConfig(
                featConfig: sherpaOnnxFeatureConfig(),
                modelConfig: sherpaOnnxOfflineModelConfig(
                    tokens: SenseVoiceModelStore.fileURL("tokens.txt").path,
                    numThreads: numThreads,
                    senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                        model: SenseVoiceModelStore.fileURL("model.int8.onnx").path,
                        language: sourceSelection.senseVoiceCode,
                        useInverseTextNormalization: true)))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        }
        guard let recognizer else { return SenseVoiceRecognitionResult(text: "") }
        let result = recognizer.decode(samples: samples)
        return SenseVoiceRecognitionResult(
            text: Self.collapsedCJKTokenSpaces(result.text)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            language: AppLanguage(speechRecognitionCode: result.lang))
    }

    /// SenseVoice emits token-level spaces inside CJK text ("黒川 さん の
    /// ボス"); collapse whitespace runs both of whose neighbors are CJK.
    /// `Character.isCJK` is Han + kana only, so Korean keeps its real
    /// spaces and Latin/digit boundaries ("Wi-Fi ルーター", "3 キロ")
    /// are untouched.
    nonisolated static func collapsedCJKTokenSpaces(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingWhitespace = ""
        for char in text {
            if char.isWhitespace {
                pendingWhitespace.append(char)
            } else {
                if !pendingWhitespace.isEmpty,
                   !(result.last?.isCJK == true && char.isCJK) {
                    result += pendingWhitespace
                }
                pendingWhitespace = ""
                result.append(char)
            }
        }
        return result + pendingWhitespace
    }
}

struct SenseVoiceRecognitionResult: Sendable {
    var text: String
    var language: AppLanguage?
}

extension RecognitionLanguageSelection {
    /// Language hint for the SenseVoice model.
    var senseVoiceCode: String {
        switch self {
        case .auto: ""
        case .language(.english): "en"
        case .language(.chinese): "zh"
        case .language(.japanese): "ja"
        case .language(.korean): "ko"
        }
    }
}

enum SenseVoiceError: LocalizedError {
    case modelMissing

    var errorDescription: String? {
        String(localized: "Download the SenseVoice model in Settings first, or switch to Apple recognition.")
    }
}
#else
actor SenseVoiceEngine: SpeechEngine {
    nonisolated let sourceSelection: RecognitionLanguageSelection
    nonisolated var language: AppLanguage { sourceSelection.fallbackLanguage }
    private(set) var decodeActiveSeconds: Double = 0

    init(sourceSelection: RecognitionLanguageSelection, emitsPartials: Bool = true) {
        self.sourceSelection = sourceSelection
    }

    func prepare(contextualStrings: [String] = []) async throws -> AVAudioFormat {
        throw SenseVoiceError.unavailableOnMac
    }

    func start() async throws -> AsyncStream<TranscriptionEvent> {
        throw SenseVoiceError.unavailableOnMac
    }

    func feed(_ chunk: AudioCaptureService.AudioChunk) {}
    func stop() async {}
    func applyContextualStrings(_ strings: [String]) async throws {}
    func setEmitsPartials(_ enabled: Bool) {}
    func resetHeatStats() {}
}

actor SenseVoiceDecoder {
    init(language: AppLanguage, numThreads: Int = 2) {}
    func decode(_ samples: [Float]) -> SenseVoiceRecognitionResult {
        SenseVoiceRecognitionResult(text: "")
    }
}

struct SenseVoiceRecognitionResult: Sendable {
    var text: String
    var language: AppLanguage?
}

enum SenseVoiceError: LocalizedError {
    case modelMissing
    case unavailableOnMac

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            String(localized: "Download the SenseVoice model in Settings first, or switch to Apple recognition.")
        case .unavailableOnMac:
            String(localized: "SenseVoice is unavailable in the native Mac app until the sherpa-onnx macOS library is bundled.")
        }
    }
}
#endif
