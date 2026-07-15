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
            // Per-word audio time ranges ride on the final result's runs;
            // the diarizer uses them to split an utterance at a speaker change.
            attributeOptions: [.audioTimeRange])
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
                        let runs = Self.timedRuns(from: result.text)
                        await self?.emit(.finalized(text, runs: runs, language: self?.language))
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

    /// Split a final result's attributed text into per-run pieces carrying
    /// their audio time range (requested via `.audioTimeRange`). Runs without
    /// a range or with no letters/digits (lone punctuation/space) are dropped.
    private static func timedRuns(from text: AttributedString) -> [TimedRun] {
        var runs: [TimedRun] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
            guard piece.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            runs.append(TimedRun(
                text: piece,
                start: range.start.seconds,
                end: range.end.seconds))
        }
        return runs
    }
}

/// Pure state machine composing the hybrid engine's gray text from Apple's
/// volatile/final results between SenseVoice finals. Two jobs:
///
/// 1. Apple's endpointer routinely holds one utterance open across silero
///    segment closes, so after a SenseVoice final the next Apple volatiles
///    still carry already-finalized words. Each SenseVoice final snapshots
///    the current Apple volatile as `consumedPrefix`; later Apple text is
///    trimmed by longest-common-prefix against it — a stale re-emission
///    trims to empty and is dropped, never resurrecting a finalized row.
///    LCP also makes composition order-insensitive between the two child
///    event streams, which have no cross-stream ordering guarantee.
/// 2. Composed text is gated on silero `speaking`, so Apple noise
///    hallucinations can never create a store entry that turn teardown
///    (`finalizeActiveAsIs`) would save — SenseVoice stays the sole source
///    of the record.
///
/// ponytail: hosted in this file, not its own, so the xcodegen-generated
/// pbxproj (pending local edits) needn't change.
struct HybridVolatileComposer: Sendable {
    /// "" for CJK sources (no spaces between joined pieces), " " otherwise.
    let separator: String

    /// Apple finals since the last SenseVoice final (post-trim) — keeps
    /// Apple-finalized words visible when Apple endpoints before silero
    /// closes the segment.
    private var accumulatedFinals: [String] = []
    private var currentVolatile = ""
    /// Apple text already covered by a SenseVoice final.
    private var consumedPrefix = ""
    private var speaking = false
    private var lastEmitted: String?

    init(separator: String) {
        self.separator = separator
    }

    mutating func setSpeaking(_ on: Bool) {
        speaking = on
    }

    /// Returns composed gray text to forward, or nil (suppressed, empty,
    /// or identical to the last emission). State updates even while
    /// suppressed so the next SenseVoice-final snapshot sees Apple's
    /// latest lagging refinements.
    mutating func appleVolatile(_ text: String) -> String? {
        currentVolatile = text
        return speaking ? composedIfFresh() : nil
    }

    mutating func appleFinal(_ text: String) -> String? {
        let piece = Self.lcpRemainder(of: text, after: consumedPrefix)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if piece.hasSpeechContent {
            accumulatedFinals.append(piece)
        }
        // Apple's utterance closed — the next volatile is a fresh
        // utterance the old prefix must not trim.
        consumedPrefix = ""
        currentVolatile = ""
        return speaking ? composedIfFresh() : nil
    }

    /// SenseVoice finalized the segment: its text supersedes everything
    /// composed so far. Snapshot at final time (not the speaking(false)
    /// edge) deliberately — Apple's volatiles lag speech, so this also
    /// consumes trailing refinements of pre-pause words.
    mutating func senseVoiceFinalized() {
        consumedPrefix = currentVolatile
        accumulatedFinals = []
        lastEmitted = nil
    }

    private mutating func composedIfFresh() -> String? {
        let live = Self.lcpRemainder(of: currentVolatile, after: consumedPrefix)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = (accumulatedFinals + [live]).filter(\.hasSpeechContent)
        let composed = parts.joined(separator: separator)
        guard composed.hasSpeechContent, composed != lastEmitted else { return nil }
        lastEmitted = composed
        return composed
    }

    /// Drop the longest common Character-prefix of `prefix` from `text`.
    /// Exact-prefix match is the common case; a mid-prefix Apple revision
    /// falls back to a shorter trim — transient duplication the next
    /// SenseVoice final cleans up, acceptable for disposable gray text.
    static func lcpRemainder(of text: String, after prefix: String) -> String {
        guard !prefix.isEmpty else { return text }
        let t = Array(text)
        let p = Array(prefix)
        var i = 0
        while i < t.count, i < p.count, t[i] == p[i] { i += 1 }
        return String(t[i...])
    }
}

/// Hybrid live engine: Apple SpeechTranscriber supplies the disposable
/// word-by-word gray text (Neural Engine, near-zero CPU); SenseVoice runs
/// finals-only — ONE decode per silero segment instead of a re-decode of
/// the growing utterance every 0.7s — and remains the sole source of
/// saved entries, refinement, and translation. Captions get more
/// responsive than the SenseVoice pulses while its live compute drops
/// roughly an order of magnitude.
///
/// Failure policy: SenseVoice is the record engine — its prepare() errors
/// propagate. The Apple child is optional responsiveness — any failure
/// (assets, locale, mid-session death) degrades to pure-SenseVoice
/// behavior by re-enabling its partials; the session survives.
actor HybridSpeechEngine: SpeechEngine {
    nonisolated let language: AppLanguage
    nonisolated var sourceSelection: RecognitionLanguageSelection { .language(language) }

    private let apple: TranscriptionEngine
    private let senseVoice: SenseVoiceEngine
    private var composer: HybridVolatileComposer
    /// Apple child failed; behave as pure SenseVoice (partials re-enabled).
    private var degraded = false

    /// Built only when Apple's format differs from SenseVoice's 16 kHz
    /// mono Float32. Persistent across chunks — resamplers carry filter
    /// state, so a per-chunk converter would smear segment boundaries.
    private var converter: AVAudioConverter?

    // feed() is synchronous actor state — audio fans out through one
    // AsyncStream lane per child (FIFO), each drained by one forwarder
    // task. A Task-per-chunk would reorder samples into silero.
    private var appleFeed: AsyncStream<AudioCaptureService.AudioChunk>.Continuation?
    private var svFeed: AsyncStream<AudioCaptureService.AudioChunk>.Continuation?
    private var appleForwardTask: Task<Void, Never>?
    private var svForwardTask: Task<Void, Never>?
    private var appleMergeTask: Task<Void, Never>?
    private var svMergeTask: Task<Void, Never>?
    private var outContinuation: AsyncStream<TranscriptionEvent>.Continuation?

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "hybrid")

    init(language: AppLanguage) {
        self.language = language
        self.apple = TranscriptionEngine(language: language)
        self.senseVoice = SenseVoiceEngine(
            sourceSelection: .language(language), emitsPartials: false)
        self.composer = HybridVolatileComposer(
            separator: language.usesCJKScript ? "" : " ")
    }

    func prepare(contextualStrings: [String] = []) async throws -> AVAudioFormat {
        // Record engine first: without it the hybrid is pointless.
        let svFormat = try await senseVoice.prepare(contextualStrings: contextualStrings)
        composer = HybridVolatileComposer(
            separator: language.usesCJKScript ? "" : " ")
        do {
            let appleFormat = try await apple.prepare(contextualStrings: contextualStrings)
            if Self.formatsMatch(appleFormat, svFormat) {
                converter = nil
            } else if let built = AVAudioConverter(from: appleFormat, to: svFormat) {
                logger.info("hybrid: converting \(appleFormat) -> 16k mono for SenseVoice")
                converter = built
            } else {
                // Can't bridge the formats — SenseVoice would decode noise.
                logger.error("hybrid: no converter \(appleFormat) -> \(svFormat); degrading")
                return await degrade(returning: svFormat)
            }
            degraded = false
            await senseVoice.setEmitsPartials(false)
            return appleFormat
        } catch {
            logger.error("hybrid: Apple child prepare failed (\(error)); degrading to pure SenseVoice")
            return await degrade(returning: svFormat)
        }
    }

    /// Prepare-time degrade ONLY: safe to drop the converter because we
    /// return SenseVoice's own 16k format — the mic tap will feed 16k.
    /// After prepare() has committed Apple's format, degrades must KEEP
    /// the converter or SenseVoice receives wrong-rate audio.
    private func degrade(returning format: AVAudioFormat) async -> AVAudioFormat {
        degraded = true
        converter = nil
        await senseVoice.setEmitsPartials(true)
        return format
    }

    func start() async throws -> AsyncStream<TranscriptionEvent> {
        let svEvents = try await senseVoice.start()
        var appleEvents: AsyncStream<TranscriptionEvent>?
        if !degraded {
            do {
                appleEvents = try await apple.start()
            } catch {
                // prepare() already returned Apple's format — the mic tap
                // feeds it, so the converter MUST survive this degrade or
                // the record engine decodes wrong-rate audio all session.
                logger.error("hybrid: Apple child start failed (\(error)); degrading to pure SenseVoice")
                degraded = true
                await senseVoice.setEmitsPartials(true)
            }
        }

        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream()
        outContinuation = continuation

        // The record lane never drops audio (a dropped chunk is lost
        // words); the display lane matches Apple's own input policy.
        let (svLane, svCont) = AsyncStream<AudioCaptureService.AudioChunk>
            .makeStream(bufferingPolicy: .unbounded)
        svFeed = svCont
        svForwardTask = Task { [senseVoice] in
            for await chunk in svLane { await senseVoice.feed(chunk) }
        }
        if let appleEvents {
            let (appleLane, appleCont) = AsyncStream<AudioCaptureService.AudioChunk>
                .makeStream(bufferingPolicy: .bufferingNewest(32))
            appleFeed = appleCont
            appleForwardTask = Task { [apple] in
                for await chunk in appleLane { await apple.feed(chunk) }
            }
            appleMergeTask = Task { [weak self] in
                for await event in appleEvents { await self?.handleApple(event) }
            }
        }
        svMergeTask = Task { [weak self] in
            for await event in svEvents { await self?.handleSenseVoice(event) }
        }
        return events
    }

    func feed(_ chunk: AudioCaptureService.AudioChunk) {
        appleFeed?.yield(chunk)
        if let converter {
            if let converted = Self.convert(chunk.buffer, with: converter),
               converted.frameLength > 0 {
                svFeed?.yield(AudioCaptureService.AudioChunk(buffer: converted))
            }
        } else {
            svFeed?.yield(chunk)
        }
    }

    /// Order matters: close the lanes and drain the forwarders so queued
    /// audio reaches SenseVoice BEFORE its stop() flushes the VAD; its
    /// trailing finals then flow through the merge before the out-stream
    /// finishes, and the pipeline's endTurn drain still processes them.
    func stop() async {
        appleFeed?.finish()
        appleFeed = nil
        svFeed?.finish()
        svFeed = nil
        await appleForwardTask?.value
        appleForwardTask = nil
        await svForwardTask?.value
        svForwardTask = nil
        await apple.stop()
        await senseVoice.stop()
        await appleMergeTask?.value
        appleMergeTask = nil
        await svMergeTask?.value
        svMergeTask = nil
        converter = nil
    }

    func applyContextualStrings(_ strings: [String]) async throws {
        guard !degraded else { return }
        try await apple.applyContextualStrings(strings)
    }

    // Heat-stat plumbing: CaptionPipeline reads/resets SenseVoice decode
    // seconds through the hybrid (its `as? SenseVoiceEngine` cast would
    // otherwise silently report 0 for hybrid sessions).
    func senseVoiceDecodeActiveSeconds() async -> Double {
        await senseVoice.decodeActiveSeconds
    }

    func resetSenseVoiceHeatStats() async {
        await senseVoice.resetHeatStats()
    }

    private func handleSenseVoice(_ event: TranscriptionEvent) {
        switch event {
        case .volatile:
            // Pure-SenseVoice behavior only when the Apple child is gone.
            if degraded { emit(event) }
        case .finalized:
            composer.senseVoiceFinalized()
            emit(event)
        case .speechActivity(let active):
            composer.setSpeaking(active)
            emit(event)
        case .ended:
            emit(event)
            outContinuation?.finish()
            outContinuation = nil
        }
    }

    private func handleApple(_ event: TranscriptionEvent) {
        switch event {
        case .volatile(let text, _):
            if let composed = composer.appleVolatile(text) {
                emit(.volatile(composed, language: language))
            }
        case .finalized(let text, _, _):
            // Display-only: an Apple final is folded into the gray text
            // (its words must stay visible until SenseVoice's authoritative
            // final lands) — never forwarded as a final.
            if let composed = composer.appleFinal(text) {
                emit(.volatile(composed, language: language))
            }
        case .speechActivity:
            // silero (via SenseVoice) drives downstream gating, as today.
            break
        case .ended(let error):
            if let error {
                // Degrade to pure-SenseVoice behavior: partials resume from
                // the next utterance and SenseVoice volatiles forward
                // (degraded routing). The converter stays — the mic tap is
                // still feeding Apple's committed format.
                logger.warning("hybrid: Apple child died (\(error)); reverting to SenseVoice partials")
                degraded = true
                appleFeed?.finish()
                appleFeed = nil
                Task { [senseVoice] in await senseVoice.setEmitsPartials(true) }
            }
        }
    }

    private func emit(_ event: TranscriptionEvent) {
        outContinuation?.yield(event)
    }

    private static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    /// Same consumed-flag convert pattern as AudioCaptureService's tap.
    private static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { return nil }
        var consumed = false
        var conversionError: NSError?
        // The input block runs synchronously inside convert() on this
        // thread; the buffer never actually crosses an isolation boundary.
        nonisolated(unsafe) let inputBuffer = buffer
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if conversionError != nil { return nil }
        return converted
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
