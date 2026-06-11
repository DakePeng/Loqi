import AVFoundation
import Foundation
import Observation
import UIKit
import os

/// Explicit session lifecycle. nil-checks on activeDirection used to encode
/// three different states ("no session" / "turn released" / "interrupted"),
/// which let interruption recovery fire from the wrong state.
enum SessionPhase: Equatable {
    case idle
    case listening(LanguagePair)
    case paused(PauseReason)
}

enum PauseReason: Equatable {
    /// Phone call / Siri took the mic; remembers what to resume.
    case interrupted(resume: LanguagePair)
}

/// Wires the whole pipeline together for one listening session:
/// audio → transcription → segmentation → tier-1 drafts → tier-2 refinement.
/// Both app modes drive this; conversation mode additionally switches the
/// active direction between turns.
///
/// All session transitions (start/stop/switch/release/interrupt/route-change)
/// are serialized FIFO — two transitions interleaving across their await
/// points previously allowed double audio starts (a precondition crash).
@MainActor
@Observable
final class CaptionPipeline {
    let store = CaptionStore()
    let translator = TranslationCoordinator()
    let thermal = ThermalMonitor()
    let hotwords = HotwordStore()
    let voiceprint = VoiceprintService()
    let archive = SessionArchive()
    let llm: LLMService

    /// User-assigned names for this session's diarization slots.
    var speakerNames: [Int: String] = [:]
    private(set) var sessionStartedAt: Date?

    private(set) var phase: SessionPhase = .idle
    var isRunning: Bool { phase != .idle }
    var activeDirection: LanguagePair? {
        if case .listening(let direction) = phase { return direction }
        return nil
    }

    /// Mic level in [0, 1] for meters.
    private(set) var level: Float = 0

    /// Typed per-subsystem status messages: clearing is structural (by key),
    /// never by comparing display strings, and subsystems can't clobber each
    /// other. Rendered by PipelineStatusBar in both modes.
    enum StatusKey: Int, Comparable, Hashable {
        case interruption = 0, memory, thermal, llm, diarizer
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    private(set) var statusMessages: [StatusKey: String] = [:]
    var statusBanner: [String] {
        statusMessages.sorted { $0.key < $1.key }.map(\.value)
    }
    private func setStatus(_ key: StatusKey, _ message: String?) {
        if let message {
            statusMessages[key] = message
        } else {
            statusMessages.removeValue(forKey: key)
        }
    }

    /// Most recent pipeline failure, surfaced in the UI. ASR errors arrive
    /// asynchronously through the event stream, not as thrown errors.
    private(set) var lastError: String?

    private let logger = Logger(subsystem: "com.kunzhipeng.locally", category: "pipeline")

    private let audio = AudioCaptureService()
    private let segmenter = TranscriptSegmenter()
    private var engines: [AppLanguage: TranscriptionEngine] = [:]
    private var refinement: RefinementQueue?
    private var feedTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var thermalWatch: Task<Void, Never>?
    private var systemObservers: [NSObjectProtocol] = []
    private var backgroundUnload: Task<Void, Never>?

    // Session artifacts (capture-first): audio recording + live summary notes.
    private var sessionID: UUID?
    private var recorder: SessionRecorder?
    private var liveChunker = LiveChunker()
    private var noteQueue: ChunkNoteQueue?
    private(set) var liveNotes: [SessionRecord.ChunkNote] = []
    private var notesEndEntryID: UUID?
    private var liveMappingStopped = false
    private var chunkGapTimer: Task<Void, Never>?

    /// Save session audio alongside the transcript (default on).
    var saveRecordingsEnabled: Bool {
        UserDefaults.standard.object(forKey: "audio.saveRecordings") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "audio.saveRecordings")
    }

    /// LLM transcript polishing (defaults on; absent key must not read as
    /// false).
    var transcriptPolishEnabled: Bool {
        UserDefaults.standard.object(forKey: "transcript.polish") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "transcript.polish")
    }

    /// Captions-mode speaker count; 0/1 = diarization off.
    var captionSpeakerCount: Int {
        UserDefaults.standard.integer(forKey: "captions.speakerCount")
    }

    /// Persisted download source for the speaker model (Settings key
    /// matches SettingsView's @AppStorage).
    var diarizerSource: DiarizerSource {
        DiarizerSource(
            rawValue: UserDefaults.standard.string(forKey: "diarizer.source") ?? ""
        ) ?? .huggingFace
    }

    private var diarizationActive = false

    /// All live sessions are captions-mode now; the enum survives for old
    /// archived records.
    var sessionMode: SessionMode { .captions }

    init(llm: LLMService? = nil) {
        // Honor persisted Settings choices even if that screen was never
        // opened this launch (the keys match SettingsView's @AppStorage).
        let defaults = UserDefaults.standard
        let model = ModelCatalog.option(
            for: defaults.string(forKey: "model.id") ?? ModelCatalog.default.id)
        let source = ModelSource(
            rawValue: defaults.string(forKey: "model.source") ?? "") ?? .huggingFace
        self.llm = llm ?? LLMService(model: model, source: source)
        let store = self.store
        refinement = RefinementQueue(llm: self.llm) { [weak store] entryID, outcome in
            store?.setRefined(outcome.translation, for: entryID)
            if let cleaned = outcome.cleanedSource {
                store?.applyCleanedSource(cleaned, for: entryID)
            }
        }
        hotwords.onChange = { [weak self] in
            self?.pushHotwordsToEngines()
        }
        noteQueue = ChunkNoteQueue(llm: self.llm) { [weak self] note, endEntryID in
            self?.liveNotes.append(note)
            self?.notesEndEntryID = endEntryID
        }
    }

    /// Refresh contextual strings on every built engine (live ones included)
    /// after the user edits the hotword list.
    private func pushHotwordsToEngines() {
        for (language, engine) in engines {
            let strings = hotwords.biasStrings(for: language)
            Task { try? await engine.applyContextualStrings(strings) }
        }
    }

    // MARK: Transition serialization

    /// FIFO queue for session transitions. Every entry point (user taps,
    /// route changes, interruptions, silence release) funnels through here,
    /// so transitions can never interleave across their await points.
    private var transitionTail: Task<Void, Never>?

    private func serialized<T: Sendable>(
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = transitionTail
        let task = Task { @MainActor () -> Result<T, Error> in
            await previous?.value
            do { return .success(try await body()) }
            catch { return .failure(error) }
        }
        transitionTail = Task { _ = await task.value }
        return try await task.value.get()
    }

    // MARK: Session lifecycle

    /// Start a recording session.
    func start(direction: LanguagePair) async throws {
        try await serialized { [self] in
            guard phase == .idle else { return }
            try await beginSession(direction: direction)
        }
    }

    private func beginSession(direction: LanguagePair) async throws {
        lastError = nil
        statusMessages.removeAll()

        await translator.setDirections([direction])
        store.currentMode = sessionMode
        speakerNames.removeAll()
        sessionID = UUID()
        liveChunker = LiveChunker()
        liveNotes.removeAll()
        notesEndEntryID = nil
        liveMappingStopped = false
        if saveRecordingsEnabled, let sessionID {
            let recorder = SessionRecorder()
            self.recorder = recorder
            await recorder.begin(sessionID: sessionID)
        }

        // Diarization: cluster utterances into N voices. The model load must
        // not block session start — captions begin immediately and
        // attribution kicks in once the model is ready.
        diarizationActive = captionSpeakerCount >= 2
        if diarizationActive {
            await voiceprint.startDiarization(maxSpeakers: captionSpeakerCount)
            if await voiceprint.state != .ready {
                setStatus(.diarizer, String(localized: "Preparing speaker separation…"))
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.voiceprint.loadIfNeeded(source: self.diarizerSource)
                    } catch {
                        self.lastError = String(
                            localized: "Speaker separation unavailable: \(error.localizedDescription)")
                    }
                    self.setStatus(.diarizer, nil)
                }
            }
        } else {
            await voiceprint.stopDiarization()
        }

        if engines[direction.source] == nil {
            engines[direction.source] = TranscriptionEngine(language: direction.source)
        }

        do {
            try await beginTurn(direction: direction)
        } catch {
            // Unwind everything beginSession set up, or a failed start
            // leaks state for a session that doesn't exist.
            await recorder?.abort()
            recorder = nil
            sessionID = nil
            diarizationActive = false
            await voiceprint.stopDiarization()
            setStatus(.diarizer, nil)
            phase = .idle
            throw error
        }

        sessionStartedAt = .now
        installSystemObservers()
        UIApplication.shared.isIdleTimerDisabled = true
        watchThermalPolicy()
        // The LLM load (~1.3GB of memory traffic) is deferred to the first
        // silence gap so it can't lag the captions; this is the fallback in
        // case the speaker never pauses.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.isRunning else { return }
            self.loadLLMIfAllowed()
        }
    }

    func stop() async {
        try? await serialized { [self] in
            await endSession()
        }
    }

    private func endSession() async {
        guard phase != .idle else { return }
        await endTurn()
        phase = .idle
        UIApplication.shared.isIdleTimerDisabled = false
        thermalWatch?.cancel()
        thermalWatch = nil
        removeSystemObservers()
        statusMessages.removeAll()
        await voiceprint.stopDiarization()
        diarizationActive = false

        // Finish artifacts BEFORE archiving: the recording's file name and
        // the live notes ride along with the record. Stop stays instant —
        // in-flight note generations are cancelled, their chunks fall to
        // the post-hoc summarize path.
        chunkGapTimer?.cancel()
        chunkGapTimer = nil
        _ = liveChunker.flush()
        await noteQueue?.cancelAll()
        let audioFileName = await recorder?.finish()
        recorder = nil

        // Sessions persist automatically; trivial ones are skipped, and the
        // archive only takes entries created during THIS session.
        if let startedAt = sessionStartedAt {
            let saved = archive.save(
                entries: store.entries(in: sessionMode),
                mode: sessionMode,
                speakerNames: speakerNames,
                startedAt: startedAt,
                artifacts: SessionArtifacts(
                    sessionID: sessionID ?? UUID(),
                    audioFileName: audioFileName,
                    chunkNotes: liveNotes,
                    notesEndEntryID: notesEndEntryID))
            if saved == nil, let audioFileName {
                try? FileManager.default.removeItem(
                    at: SessionArchive.recordingURL(fileName: audioFileName))
            }
        }
        sessionStartedAt = nil
        sessionID = nil
        liveNotes.removeAll()
        notesEndEntryID = nil
    }

    // MARK: System events (interruptions, route changes, backgrounding)

    private func installSystemObservers() {
        guard systemObservers.isEmpty else { return }
        let center = NotificationCenter.default

        systemObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let typeRaw,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
                else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                switch type {
                case .began:
                    self.handleInterruptionBegan()
                case .ended:
                    self.handleInterruptionEnded(
                        shouldResume: options.contains(.shouldResume))
                @unknown default:
                    break
                }
            }
        })

        systemObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let reasonRaw,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
                else { return }
                // Mic hardware changed (AirPods on/off, cable mic): the tap
                // format is stale — rebind by restarting the current turn.
                if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
                    self.restartCurrentTurn()
                }
            }
        })
    }

    private func removeSystemObservers() {
        for observer in systemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        systemObservers.removeAll()
    }

    private func handleInterruptionBegan() {
        Task {
            try? await self.serialized { [self] in
                // Only a live turn pauses; released/idle states are not
                // "interrupted" (resuming them would open the mic unasked).
                guard case .listening(let direction) = phase else { return }
                logger.info("audio interrupted (call/Siri); pausing session")
                await endTurn()
                phase = .paused(.interrupted(resume: direction))
                setStatus(.interruption, String(
                    localized: "Paused — another app is using the microphone"))
            }
        }
    }

    private func handleInterruptionEnded(shouldResume: Bool) {
        Task {
            try? await self.serialized { [self] in
                // Resume exactly the turn that was interrupted — never the
                // session-start direction, never a silence-released idle.
                guard case .paused(.interrupted(let resume)) = phase else { return }
                setStatus(.interruption, nil)
                guard shouldResume else {
                    lastError = String(
                        localized: "Session ended by an interruption.")
                    await endSession()
                    return
                }
                logger.info("interruption ended; resuming \(resume.source.rawValue)")
                do {
                    try await beginTurn(direction: resume)
                } catch {
                    lastError = error.localizedDescription
                    await endSession()
                }
            }
        }
    }

    private func restartCurrentTurn() {
        Task {
            try? await self.serialized { [self] in
                guard case .listening(let direction) = phase else { return }
                logger.info("audio route changed; rebinding microphone")
                await endTurn()
                do {
                    try await beginTurn(direction: direction)
                } catch {
                    lastError = error.localizedDescription
                    await endSession()
                }
            }
        }
    }

    /// Scene went to background: the mic stops; say so instead of dying
    /// silently, and free the big models if the user stays away.
    func handleBackground() {
        if isRunning {
            Task { await stop() }
            lastError = String(localized: "Session ended when the app went to the background.")
        }
        backgroundUnload = Task { [llm, voiceprint] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await llm.unload()
            await voiceprint.unload()
        }
    }

    func handleForeground() {
        backgroundUnload?.cancel()
        backgroundUnload = nil
    }

    // MARK: Turn plumbing

    private func beginTurn(direction: LanguagePair) async throws {
        // Self-heal: a turn can ask for a direction the session was not
        // started with. Build whatever is missing on demand.
        if engines[direction.source] == nil {
            engines[direction.source] = TranscriptionEngine(language: direction.source)
        }
        await translator.addDirection(direction)
        guard let engine = engines[direction.source] else {
            throw TranscriptionError.assetsUnavailable(direction.source)
        }

        let format = try await engine.prepare(
            contextualStrings: hotwords.biasStrings(for: direction.source))
        let (buffers, levels) = try audio.start(outputFormat: format)
        let events: AsyncStream<TranscriptionEvent>
        do {
            events = try await engine.start()
        } catch {
            audio.stop()
            throw error
        }
        phase = .listening(direction)

        feedTask = Task { [weak self, voiceprint] in
            for await chunk in buffers {
                guard let self else { return }
                await engine.feed(chunk)
                // Checked live (not captured): the speaker-count picker can
                // enable diarization mid-turn and the tee must follow.
                if self.diarizationActive {
                    await voiceprint.ingest(chunk)
                }
                if let recorder = self.recorder {
                    await recorder.append(chunk)
                }
            }
        }
        levelTask = Task { [weak self] in
            for await sample in levels {
                guard let self else { return }
                // Delta-throttled: publishing every ~43ms sample re-renders
                // level readers at audio rate for invisible changes.
                if abs(sample.rms - self.level) > 0.02
                    || (sample.rms == 0 && self.level != 0) {
                    self.level = sample.rms
                }
            }
        }
        eventsTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event, direction: direction)
            }
        }
    }

    /// Tear down the live turn, DRAINING the event stream so flushed final
    /// results are processed instead of dropped, then freeze any leftover
    /// volatile entry so the next turn can never adopt and overwrite it.
    /// Callers set the next phase afterwards.
    private func endTurn() async {
        audio.stop()  // finishes the buffer + level streams
        if case .listening(let direction) = phase {
            await engines[direction.source]?.stop()  // flushes + finishes events
        }
        await feedTask?.value
        feedTask = nil
        await eventsTask?.value  // drain: final results still run handle()
        eventsTask = nil
        await levelTask?.value
        levelTask = nil

        if let leftover = store.finalizeActiveAsIs() {
            if let closed = liveChunker.append(leftover) {
                await enqueueChunkNote(for: closed)
            }
            // The analyzer never finalized this text; translate it so the
            // speaker's last words aren't lost (transcribe-only: keep as-is).
            if leftover.direction.source == leftover.direction.target {
                store.setRefined(nil, for: leftover.id)
            } else if await produceDraft(for: leftover) != nil {
                store.setRefined(nil, for: leftover.id)
            }
        }
        level = 0
    }

    // MARK: Event handling

    private func handle(_ event: TranscriptionEvent, direction: LanguagePair) async {
        // ASR failures arrive as events, not thrown errors — surface them
        // or the session dies silently with the mic still "live".
        if case .ended(let error) = event, let error {
            logger.error("transcription ended with error: \(error)")
            lastError = error.localizedDescription
            return
        }

        // VAD drives everything that must yield to live speech.
        if case .speechActivity(let active) = event {
            await refinement?.setSpeechActive(active)
            await noteQueue?.setSpeechActive(active)
            if active {
                chunkGapTimer?.cancel()
                await voiceprint.beginUtterance()
            } else {
                await voiceprint.endUtterance()
                loadLLMIfAllowed()
                scheduleChunkGapClose()
            }
            return
        }

        guard let output = segmenter.process(event, language: direction.source) else { return }

        switch output.kind {
        case .volatileUpdate:
            let entryID = store.applyVolatile(text: output.text, direction: direction)
            if direction.source != direction.target {
                translator.draftDebounced(
                    output.text, direction: direction, entryID: entryID, store: store)
            }

        case .finalized(let refine):
            // Tier-0: deterministically restore near-miss hotwords before
            // anything else sees the text — the draft benefits too.
            let matcher = hotwords.matcher
            let text = matcher.fixup(output.text, language: direction.source)
            guard let entry = store.finalizeActive(text: text, direction: direction)
            else { return }
            // Captions diarization: attribute the utterance to a voice slot,
            // and apply any retroactive corrections to earlier entries.
            if diarizationActive,
               let result = await voiceprint.assignSpeaker(entryID: entry.id) {
                store.setSpeaker(result.slot, for: entry.id)
                for (entryID, slot) in result.relabels {
                    store.setSpeaker(slot, for: entryID)
                }
            }

            // Live summary mapping: a closed chunk generates its note in
            // the next silence gap.
            if let closed = liveChunker.append(store.entry(for: entry.id) ?? entry) {
                await enqueueChunkNote(for: closed)
            }

            // Transcribe-only sessions (source == target) skip translation
            // but still get LLM transcript polish.
            let translationEnabled = direction.source != direction.target
            var draft = ""
            if translationEnabled {
                guard let produced = await produceDraft(for: entry) else { return }
                draft = produced
            }

            // Hotword near-misses force refinement even for short
            // utterances — names usually appear in exactly those.
            let wantsRefinement = translationEnabled
                ? (refine || matcher.shouldForceRefine(text, language: direction.source))
                : transcriptPolishEnabled
            if wantsRefinement, llmEnabled, thermal.policy == .full, await llmIsReady() {
                store.markRefining(entry.id)
                let history = translationEnabled
                    ? store.recentHistory(limit: 6).map {
                        PromptBuilder.HistoryTurn(
                            sourceLanguage: $0.direction.source,
                            sourceText: $0.sourceText,
                            translation: $0.displayTranslation ?? "")
                    }
                    : []
                await refinement?.enqueue(RefinementQueue.Job(
                    entryID: entry.id,
                    source: text,
                    draft: draft,
                    direction: direction,
                    history: history,
                    glossary: matcher.glossaryLines(
                        direction: direction, sourceText: text),
                    cleanSource: transcriptPolishEnabled))
            } else {
                store.setRefined(nil, for: entry.id)
            }

        case .discard:
            store.discardActiveIfEmpty()
        }
    }

    /// Tier-1 draft for a finalized entry: cancel pending volatile work,
    /// translate, store, and speak (conversation + TTS). Returns nil and
    /// marks the entry on failure.
    private func produceDraft(for entry: CaptionEntry) async -> String? {
        translator.cancelPending(entryID: entry.id)
        do {
            let draft = try await translator.draft(
                entry.sourceText, direction: entry.direction)
            store.setDraft(draft, for: entry.id)
            return draft
        } catch {
            logger.warning("draft translation failed: \(error)")
            store.markDraftFailed(entry.id)
            store.setRefined(nil, for: entry.id)
            return nil
        }
    }

    /// Close the current chunk after a long silence so its note generates
    /// during the very gap that ended it.
    private func scheduleChunkGapClose() {
        chunkGapTimer?.cancel()
        chunkGapTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SummaryEngine.chunkGap))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            if let closed = self.liveChunker.closeForGap() {
                await self.enqueueChunkNote(for: closed)
            }
        }
    }

    /// Hand a closed chunk to the note queue. Gating failures stop live
    /// mapping for the rest of the session so note coverage stays a
    /// contiguous prefix (post-hoc summarize maps the tail).
    private func enqueueChunkNote(for chunk: [CaptionEntry]) async {
        guard !liveMappingStopped, !chunk.isEmpty else { return }
        guard llmEnabled, thermal.policy == .full, await llmIsReady() else {
            liveMappingStopped = true
            return
        }
        let text = chunk.map { entry in
            let label = entry.speaker.map {
                speakerNames[$0] ?? "Speaker \($0 + 1)"
            }
            return (label.map { "[\($0)] " } ?? "") + entry.sourceText
        }.joined(separator: "\n")
        let language = AppLanguage.devicePreferred ?? chunk[0].direction.target
        await noteQueue?.enqueue(ChunkNoteQueue.Job(
            chunkText: text,
            anchorEntryID: chunk[0].id,
            endEntryID: chunk[chunk.count - 1].id,
            startedAt: chunk[0].createdAt,
            fallbackHeadline: String(chunk[0].sourceText.prefix(24)),
            language: language))
    }

    /// Change the speaker count, live: existing utterances are re-clustered
    /// into the new count and relabeled on screen. The audio tee follows
    /// automatically (checked per-chunk in the feed loop).
    func updateSpeakerCount(_ count: Int) {
        UserDefaults.standard.set(count, forKey: "captions.speakerCount")
        guard isRunning else { return }
        diarizationActive = count >= 2
        Task { [weak self] in
            guard let self else { return }
            if count >= 2 {
                if await self.voiceprint.state != .ready {
                    self.setStatus(.diarizer, String(localized: "Preparing speaker separation…"))
                    try? await self.voiceprint.loadIfNeeded(source: self.diarizerSource)
                    self.setStatus(.diarizer, nil)
                }
                let relabels = await self.voiceprint.startDiarization(maxSpeakers: count)
                for (entryID, slot) in relabels {
                    self.store.setSpeaker(slot, for: entryID)
                }
            } else {
                await self.voiceprint.stopDiarization()
            }
        }
    }

    // MARK: LLM + thermal management

    private func llmIsReady() async -> Bool {
        if case .ready = await llm.loadState { return true }
        return false
    }

    /// User-facing switch for tier-2 refinement. Defaults to on; absence of
    /// the key must not read as `false`.
    var llmEnabled: Bool {
        UserDefaults.standard.object(forKey: "llm.enabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "llm.enabled")
    }

    func setLLMEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "llm.enabled")
        if enabled {
            Task { await refinement?.setPaused(false) }
            if isRunning { loadLLMIfAllowed() }
        } else {
            setStatus(.llm, nil)
            Task { [refinement, llm] in
                await refinement?.setPaused(true)
                await llm.unload()
            }
        }
    }

    private func loadLLMIfAllowed() {
        guard llmEnabled, thermal.policy != .llmUnloaded else { return }
        Task { [llm] in
            // Called on every silence gap; only show status when there is
            // actually a load to do (llm.load joins in-flight loads).
            if case .ready = await llm.loadState { return }
            self.setStatus(.llm, String(localized: "Warming up enhanced translations…"))
            do {
                try await llm.load()
                await self.refinement?.setPaused(false)
                self.setStatus(.llm, nil)
            } catch {
                self.setStatus(.llm, String(localized: "Enhanced translations unavailable"))
            }
        }
    }

    private func watchThermalPolicy() {
        thermalWatch?.cancel()
        thermalWatch = Task { [weak self] in
            var lastPolicy = ThermalMonitor.Policy.full
            while !Task.isCancelled {
                guard let self else { return }
                let policy = self.thermal.policy
                if policy != lastPolicy {
                    lastPolicy = policy
                    switch policy {
                    case .full:
                        await self.refinement?.setPaused(false)
                        self.loadLLMIfAllowed()
                        self.setStatus(.thermal, nil)
                    case .refinementPaused:
                        await self.refinement?.setPaused(true)
                        self.setStatus(.thermal, String(
                            localized: "Enhanced translation paused (device warm)"))
                    case .llmUnloaded:
                        await self.refinement?.setPaused(true)
                        await self.llm.unload()
                        self.setStatus(.thermal, String(
                            localized: "Enhanced translation off (device hot)"))
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Memory-warning hook (RootView forwards the notification). The system
    /// is about to kill us — drop the big models, not just the MLX cache.
    /// Tier-1 captions keep working; the LLM reloads on the next quiet gap.
    func handleMemoryWarning() {
        logger.warning("memory warning: unloading models")
        setStatus(.memory, String(localized: "Enhanced translation paused (low memory)"))
        Task { [llm, voiceprint, refinement] in
            await refinement?.setPaused(true)
            await llm.unload()
            await voiceprint.unload()
        }
    }
}
