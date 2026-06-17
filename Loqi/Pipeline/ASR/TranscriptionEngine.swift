import AVFoundation
import Foundation
import Speech
import os

/// Common surface for live recognition backends. The pipeline drives a
/// session through this; which implementation it gets is a Settings choice
/// (Apple SpeechAnalyzer = instant word-by-word, SenseVoice = higher
/// accuracy in ~1s pulses).
protocol SpeechEngine: Actor {
    nonisolated var sourceSelection: RecognitionLanguageSelection { get }
    /// Build the recognition stack; returns the audio format to feed.
    func prepare(contextualStrings: [String]) async throws -> AVAudioFormat
    func start() async throws -> AsyncStream<TranscriptionEvent>
    func feed(_ chunk: AudioCaptureService.AudioChunk)
    /// Flushes pending audio into final results, then finishes the stream.
    func stop() async
    func applyContextualStrings(_ strings: [String]) async throws
}

/// Wraps SpeechAnalyzer/SpeechTranscriber for one locale.
/// Feed it converted audio buffers; consume the event stream from start().
///
/// A fresh analyzer/transcriber stack is built for every session: a finished
/// SpeechAnalyzer cannot be restarted, so prepare() always rebuilds.
actor TranscriptionEngine: SpeechEngine {
    let language: AppLanguage
    nonisolated var sourceSelection: RecognitionLanguageSelection { .language(language) }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var detector: SpeechDetector?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<TranscriptionEvent>.Continuation?

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "asr")

    init(language: AppLanguage) {
        self.language = language
    }

    /// Build a fresh transcriber stack, verify the locale's model assets are
    /// installed and reserved for this app, and return the audio format
    /// buffers must be converted to before `feed(_:)`.
    /// `contextualStrings` biases recognition toward user hotwords.
    func prepare(contextualStrings: [String] = []) async throws -> AVAudioFormat {
        let transcriber = SpeechTranscriber(
            locale: language.speechLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
        self.transcriber = transcriber
        // VAD rides in the same analyzer: it gates LLM work off live speech
        // and marks utterance boundaries for voiceprint classification.
        // Sensitivity follows the pickup preset — high reaches for the
        // faint, reverberant speech of far talkers; low keeps background
        // voices out in close-up use.
        let detectorOptions: SpeechDetector.DetectionOptions =
            switch MicSensitivity.current {
            case .near: .init(sensitivityLevel: .low)
            case .balanced: .init(sensitivityLevel: .medium)
            case .far: .init(sensitivityLevel: .high)
            }
        let detector = SpeechDetector(
            detectionOptions: detectorOptions,
            reportResults: true)
        self.detector = detector
        // High priority + retained models: live captions are the app's whole
        // job, and re-loading the ASR model per session costs seconds.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber, detector],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer

        try await ensureAssets(for: transcriber)
        try? await applyContextualStrings(contextualStrings)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber, detector])
        else {
            logger.error("No compatible audio format for \(self.language.rawValue)")
            throw TranscriptionError.noCompatibleAudioFormat
        }
        // Preheat: loads the model before audio arrives. Without this the
        // analyzer can sit on buffered audio and deliver everything late.
        try await analyzer.prepareToAnalyze(in: format)
        logger.info("Prepared \(self.language.rawValue), format \(format)")
        return format
    }

    /// Begin a transcription session and return its event stream.
    func start() async throws -> AsyncStream<TranscriptionEvent> {
        guard let analyzer, let transcriber else {
            throw TranscriptionError.notPrepared
        }

        let (events, eventCont) = AsyncStream<TranscriptionEvent>.makeStream()
        eventContinuation = eventCont
        fedChunks = 0

        // Subscribe to results BEFORE starting analysis so no early
        // result is dropped (the WWDC25 sample uses this order).
        resultsTask = Task { [weak self, logger] in
            do {
                var first = true
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if first {
                        logger.info("first result arrived (isFinal=\(result.isFinal))")
                        first = false
                    }
                    logger.debug("result isFinal=\(result.isFinal): \(text, privacy: .private)")
                    if result.isFinal {
                        await self?.emit(.finalized(text, language: self?.language))
                    } else {
                        await self?.emit(.volatile(text, language: self?.language))
                    }
                }
                logger.info("results stream ended")
                await self?.emit(.ended(nil))
            } catch {
                logger.error("results stream failed: \(error)")
                await self?.emit(.ended(error))
            }
        }

        if let detector {
            detectorTask = Task { [weak self, logger] in
                var lastReported: Bool?
                do {
                    for try await result in detector.results {
                        if result.speechDetected != lastReported {
                            lastReported = result.speechDetected
                            await self?.emit(.speechActivity(result.speechDetected))
                        }
                    }
                } catch {
                    logger.info("speech detector stream ended: \(error)")
                }
            }
        }

        let (input, inputCont) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        inputContinuation = inputCont

        try await analyzer.start(inputSequence: input)
        logger.info("analyzer started for \(self.language.rawValue)")
        return events
    }

    private var fedChunks = 0

    func feed(_ chunk: AudioCaptureService.AudioChunk) {
        inputContinuation?.yield(AnalyzerInput(buffer: chunk.buffer))
        fedChunks += 1
        if fedChunks % 100 == 1 {
            logger.info("fed \(self.fedChunks) chunks (\(chunk.buffer.frameLength) frames each)")
        }
    }

    /// Finish the session, flushing a final result for any pending audio.
    /// The stack is discarded; the next session rebuilds via prepare().
    func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        detectorTask?.cancel()
        detectorTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        analyzer = nil
        transcriber = nil
        detector = nil
    }

    /// Bias recognition toward user hotwords. Works on a live analyzer too,
    /// so editing the list mid-session takes effect immediately.
    func applyContextualStrings(_ strings: [String]) async throws {
        guard let analyzer else { return }
        let context = AnalysisContext()
        if !strings.isEmpty {
            context.contextualStrings = [.general: strings]
        }
        try await analyzer.setContext(context)
    }

    private func ensureAssets(for transcriber: SpeechTranscriber) async throws {
        let locale = language.speechLocale
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
                || $0.language.languageCode == locale.language.languageCode
        }) else {
            logger.error("Locale \(locale.identifier) not in supportedLocales")
            throw TranscriptionError.assetsUnavailable(language)
        }
        // Reserves the locale for this app and downloads the model if it
        // is missing. Cheap no-op when everything is already in place.
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            logger.info("Downloading speech assets for \(locale.identifier)")
            try await request.downloadAndInstall()
        }
    }

    private func emit(_ event: TranscriptionEvent) {
        eventContinuation?.yield(event)
    }
}

enum TranscriptionError: LocalizedError {
    case notPrepared
    case noCompatibleAudioFormat
    case assetsUnavailable(AppLanguage)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            "Transcription engine was not prepared."
        case .noCompatibleAudioFormat:
            "No compatible audio format for on-device speech recognition."
        case .assetsUnavailable(let language):
            "Speech recognition for \(language.displayName) is not available on this device."
        }
    }
}
