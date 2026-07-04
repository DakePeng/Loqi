import AVFoundation
import Foundation
import Observation
import os

#if os(iOS)
import UIKit
import WidgetKit
#endif

/// Explicit session lifecycle. nil-checks on activeDirection used to encode
/// three different states ("no session" / "turn released" / "interrupted"),
/// which let interruption recovery fire from the wrong state.
enum SessionPhase: Equatable {
    case idle
    case listening(RecognitionRoute)
    case paused(PauseReason)
}

enum PauseReason: Equatable {
    /// Phone call / Siri took the mic; remembers what to resume.
    case interrupted(resume: RecognitionRoute)
}

/// Wires the whole pipeline together for one listening session:
/// audio → transcription → segmentation → tier-1 drafts → tier-2 refinement.
///
/// All session transitions (start/stop/switch/release/interrupt/route-change)
/// are serialized FIFO — two transitions interleaving across their await
/// points previously allowed double audio starts (a precondition crash).
@MainActor
@Observable
final class CaptionPipeline {
    /// The one pipeline instance. App Intents (Action Button, Siri, the
    /// Live Activity stop button, the Control Center toggle) execute in
    /// the app process and must reach the same pipeline the UI drives.
    static let shared = CaptionPipeline()

    let store = CaptionStore()
    let translator = TranslationCoordinator()
    let thermal = ThermalMonitor()
    let hotwords = HotwordStore()
    /// Offline whole-file diarization for imports / re-transcribe (owned by
    /// the job center). Live captions use `streamingDiarizer` instead.
    let voiceprint = VoiceprintService()
    /// Live streaming diarization (Sortformer). Separate from `voiceprint`:
    /// one streams the mic, the other batch-processes a finished file.
    let streamingDiarizer = StreamingDiarizer()
    let archive = SessionArchive()
    let llm: LLMService
    /// Post-hoc LLM jobs (summarize / re-transcribe): shared so progress
    /// and dedupe don't depend on which screen started a job. IUO because
    /// its `isRecording` closure needs `self` (set at the end of init).
    private(set) var jobs: SummaryJobCenter!

    /// User-assigned names for this session's diarization slots.
    var speakerNames: [Int: String] = [:]
    private(set) var sessionStartedAt: Date?
    /// The session just archived by stop(), driving the post-recording
    /// card (summarize / discard audio). Cleared when the next session
    /// starts or the user dismisses the card.
    private(set) var lastFinishedSessionID: UUID?
    /// True when `lastFinishedSessionID` was recovered from the crash
    /// journal rather than a clean stop — the post-stop page says so.
    private(set) var lastFinishedWasInterrupted = false

    private(set) var phase: SessionPhase = .idle
    var isRunning: Bool { phase != .idle }
    /// Mic lost to a call/Siri; the recording bar and landscape view swap
    /// their live indicators for a paused one.
    var isPaused: Bool {
        if case .paused = phase { return true }
        return false
    }
    var activeDirection: LanguagePair? {
        if case .listening(let route) = phase { return route.fallbackDirection }
        return nil
    }
    var activeRoute: RecognitionRoute? {
        if case .listening(let route) = phase { return route }
        return nil
    }

    /// Whether the active model's weights are on disk — gates every UI
    /// entry point that would otherwise trigger a multi-GB download.
    var llmDownloaded: Bool {
        LLMService.isDownloaded(model: ModelCatalog.current)
    }

    /// Short-lived, self-clearing message for outcomes that have no other
    /// surface (e.g. "nothing captured"). Rendered by PipelineStatusBar.
    private(set) var transientNotice: String?
    private var noticeTask: Task<Void, Never>?

    func showNotice(_ text: String, for seconds: Double = 5) {
        transientNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.transientNotice = nil
        }
    }

    /// Mic level in [0, 1] for meters.
    private(set) var level: Float = 0

    /// Typed per-subsystem status messages: clearing is structural (by key),
    /// never by comparing display strings, and subsystems can't clobber each
    /// other. Rendered by PipelineStatusBar in both modes.
    enum StatusKey: Int, Comparable, Hashable {
        case interruption = 0, memory, thermal, llm, diarizer, asr
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    private(set) var statusMessages: [StatusKey: String] = [:]
    var statusBanner: [String] {
        Self.visibleStatusMessages(from: statusMessages)
    }

    static func visibleStatusMessages(from messages: [StatusKey: String]) -> [String] {
        let resourceKeys: [StatusKey] = [.memory, .thermal, .llm]
        let visibleResourceKey = resourceKeys.first { messages[$0] != nil }

        return messages.sorted { $0.key < $1.key }.compactMap { key, value in
            if resourceKeys.contains(key) {
                return key == visibleResourceKey ? value : nil
            }
            return value
        }
    }

    static func shouldUnloadVoiceprintOnMemoryWarning(
        isRunning: Bool,
        diarizationActive: Bool
    ) -> Bool {
        !(isRunning && diarizationActive)
    }

    static func shouldRunLiveDiarization(
        diarizationActive: Bool,
        isBackgrounded: Bool
    ) -> Bool {
        diarizationActive && !isBackgrounded
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

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "pipeline")

    private let audio = AudioCaptureService()
    private let segmenter = TranscriptSegmenter()
    private var engines: [RecognitionLanguageSelection: any SpeechEngine] = [:]
    private var activeEngineKey: RecognitionLanguageSelection?
    /// Which backend the cached engines were built for; a Settings change
    /// invalidates them.
    private var enginesKind = ""
    private var refinement: RefinementQueue?
    private var feedTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var thermalWatch: Task<Void, Never>?
    private var systemObservers: [NSObjectProtocol] = []
    private var backgroundUnload: Task<Void, Never>?
    /// Tail of the ordered LLM scene-state handoff chain; see
    /// `forwardLLMSceneState`.
    private var llmSceneForward: Task<Void, Never>?
    /// Fires on critical system memory pressure, foreground or background.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastMemoryShed: ContinuousClock.Instant?
    /// Serializes crash-journal writes off the main actor, coalescing the
    /// per-utterance snapshots so encoding + disk I/O never blocks captions.
    private let journalWriter = JournalWriter()
    private var startupTask: Task<Void, Never>?
    /// Scene is in the background. While true, no Metal-backed work may
    /// start — captions and the recorder run alone.
    private(set) var isBackgrounded = false

    /// Lock screen / Dynamic Island presence while recording.
    private let liveActivity = RecordingActivityController()

    // Session artifacts (capture-first): audio recording + live summary notes.
    private var sessionID: UUID?
    private var recorder: SessionRecorder?
    /// One anchor per turn start: wall date ↔ audio seconds written, so
    /// archived entries get audio offsets that survive interruption gaps.
    private var audioAnchors: [AudioTimeline.Anchor] = []
    /// Finalized entries the store pruned out of its render window, retained
    /// so the archived transcript and crash journal stay complete on long
    /// sessions (the store bounds only what the UI re-groups). Reset per
    /// session; chronological — eviction always drops the oldest first.
    private var evictedEntries: [CaptionEntry] = []
    /// The full session transcript for archival: entries evicted from the
    /// live render window followed by what's still on screen.
    private var archivableEntries: [CaptionEntry] {
        evictedEntries + store.entries
    }
    private var liveChunker = LiveChunker()
    private var noteQueue: ChunkNoteQueue?
    private(set) var liveNotes: [SessionRecord.ChunkNote] = []
    /// Photos attached to the running session; ride into the archive via
    /// SessionArtifacts. OCR fills in asynchronously.
    private(set) var liveAttachments: [SessionRecord.Attachment] = []
    /// VLM photo descriptions (vision tier only) — yields like note jobs.
    private var describeQueue: AttachmentDescribeQueue?
    private var notesEndEntryID: UUID?
    private var liveMappingStopped = false
    private var chunkGapTimer: Task<Void, Never>?

    /// Save session audio alongside the transcript (default on).
    var saveRecordingsEnabled: Bool {
        UserDefaults.standard.object(forKey: "audio.saveRecordings") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "audio.saveRecordings")
    }

    /// Captions-mode speaker picker value; 0/1 = diarization off, -1 =
    /// Auto, 2+ = hard cap (see VoiceprintService.clusterCap). Unset defaults
    /// stay off until the model is cached, so first recording never fetches
    /// speaker weights without consent.
    var captionSpeakerCount: Int {
        (UserDefaults.standard.object(forKey: "captions.speakerCount") as? Int)
            ?? VoiceprintService.defaultLiveSpeakerPickerValue()
    }

    /// Persisted download source for the speaker model (Settings key
    /// matches SettingsView's @AppStorage).
    var diarizerSource: DiarizerSource { .current }

    private var diarizationActive = false
    private var diarizationPausedForSceneExit = false
    /// Audio-time bounds (seconds, in the streaming diarizer's clock) of the
    /// utterance currently being spoken — stamped at VAD speech-start/-end and
    /// used to attribute the ASR final to a speaker slot.
    private var utteranceStartAudioSeconds: Double?
    private var utteranceEndAudioSeconds: Double?

    init(llm: LLMService? = nil) {
        // Honor persisted Settings choices even if that screen was never
        // opened this launch (the keys match SettingsView's @AppStorage).
        let defaults = UserDefaults.standard
        // Selections pointing at removed tiers snap back to the default.
        ModelCatalog.normalizeStoredSelection(defaults)
        let model = ModelCatalog.option(
            for: defaults.string(forKey: "model.id") ?? ModelCatalog.default.id)
        let source = ModelSource(
            rawValue: defaults.string(forKey: "model.source") ?? "") ?? .huggingFace
        self.llm = llm ?? LLMService(model: model, source: source)
        let store = self.store
        refinement = RefinementQueue(llm: self.llm) { [weak store] entryID, outcome in
            store?.setRefined(outcome.translation, for: entryID)
        }
        hotwords.onChange = { [weak self] in
            self?.pushHotwordsToEngines()
        }
        // Entries pruned from the live render window are retained for archival
        // instead of dropped, so a session longer than the store's window
        // keeps its opening in the saved transcript and the crash journal.
        store.onEvict = { [weak self] evicted in
            self?.evictedEntries.append(contentsOf: evicted)
        }
        noteQueue = ChunkNoteQueue(llm: self.llm) { [weak self] note, endEntryID in
            self?.liveNotes.append(note)
            self?.notesEndEntryID = endEntryID
            self?.writeJournal()
        }
        describeQueue = AttachmentDescribeQueue(llm: self.llm) { [weak self] text, attachmentID, sessionID in
            self?.updateAttachment(attachmentID, sessionID: sessionID) {
                $0.vlmDescription = text
                $0.summaryRecords = nil
            }
        }
        jobs = SummaryJobCenter(
            llm: self.llm,
            archive: archive,
            hotwords: hotwords,
            translator: translator,
            voiceprint: voiceprint
        ) { [weak self] in
            self?.isRunning ?? false
        }

        #if os(iOS)
        // iOS can relaunch the app IN THE BACKGROUND (e.g. to deliver
        // background URLSession download events). scenePhase hasn't fired
        // yet at init, so seed the scene state from UIApplication before
        // the startup sweep below can start Metal work in a context that
        // forbids it. The first real scenePhase change takes over via
        // handleForeground()/handleBackground().
        if UIApplication.shared.applicationState == .background {
            isBackgrounded = true
            jobs.setBackgrounded(true)
            forwardLLMSceneState(backgrounded: true)
        }
        #endif

        // Load history before recovery/sweep. Sweeping an empty, unloaded
        // archive would delete every recording; recovery also dedupes
        // against loaded sessions.
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.archive.loadIfNeeded()
            self.recoverInterruptedSession()
            self.archive.sweepOrphans()
            // Both sweeps no-op while backgrounded; the foreground
            // transition re-runs them via resumeBackgroundJobs().
            self.jobs.resumeUnfinishedImports()
            self.jobs.resumeUnfinishedSummaries()
        }

        // UIKit's memory warning only arrives in the foreground; a
        // dispatch source also fires while recording with the screen
        // locked — exactly where jetsam was killing long sessions.
        //
        // BUT the source reports SYSTEM-WIDE pressure, which sits at
        // critical chronically on 6GB devices — reacting to every event
        // shed-thrashed the LLM (unload → silence-gap reload → pressure →
        // unload…) and killed in-flight summaries. Only shed when OUR
        // headroom is actually gone.
        #if os(iOS)
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: .critical, queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                    guard SystemResources.availableMemoryBytes() < Self.memoryShedFloor else { return }
                self?.handleMemoryWarning()
            }
        }
        pressure.activate()
        memoryPressureSource = pressure
        #endif
    }

    /// Per-app free-memory floor under which a critical system-pressure
    /// event triggers model shedding. Above it, global pressure is someone
    /// else's problem and our models keep working.
    private static let memoryShedFloor: UInt64 = 400_000_000

    // MARK: Crash recovery

    /// Rebuild and archive the session a dead process left behind: the
    /// journal snapshot plus its crash-tolerant CAF audio. The Record tab
    /// then opens on the post-stop page in "interrupted" framing, one tap
    /// from reviewing the session or starting a new recording.
    private func recoverInterruptedSession() {
        guard var record = SessionJournal.read() else { return }
        SessionJournal.clear()
        defer {
            // The crashed process never reset the widget state; without
            // this the Control Center toggle keeps claiming "recording".
            #if os(iOS)
            RecordingSharedState.write(.init(isRunning: false, startedAt: nil))
            ControlCenter.shared.reloadControls(ofKind: RecordingSharedState.controlKind)
            #endif
        }
        // The crash may have raced the clean shutdown's journal clear.
        guard !archive.sessions.contains(where: { $0.id == record.id }) else { return }

        // Claim the audio if the recorder got far enough to be worth it
        // (CAF stays playable up to the last written chunk).
        if let fileName = record.audioFileName {
            let url = SessionArchive.recordingURL(fileName: fileName)
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if bytes < 8_192 {
                try? FileManager.default.removeItem(at: url)
                record.audioFileName = nil
            }
        }

        let duration = record.endedAt.timeIntervalSince(record.startedAt)
        guard SessionArchive.shouldArchive(
            entryCount: record.entries.count,
            hasAudio: record.audioFileName != nil,
            duration: duration)
        else {
            if let fileName = record.audioFileName {
                try? FileManager.default.removeItem(
                    at: SessionArchive.recordingURL(fileName: fileName))
            }
            return
        }

        archive.add(record)
        logger.info("recovered interrupted session: \(record.entries.count) entries, audio: \(record.audioFileName != nil)")
        if record.entries.isEmpty {
            showNotice(String(
                localized: "A recording was interrupted — its audio is saved in Sessions."),
                for: 8)
        } else {
            lastFinishedSessionID = record.id
            lastFinishedWasInterrupted = true
        }
    }

    /// Refresh contextual strings on every built engine (live ones included)
    /// after the user edits the hotword list.
    private func pushHotwordsToEngines() {
        for (source, engine) in engines {
            let strings: [String] = switch source {
            case .auto: []
            case .language(let language): hotwords.biasStrings(for: language)
            }
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
        try await start(route: RecognitionRoute(
            source: .language(direction.source),
            target: direction.source == direction.target ? nil : direction.target))
    }

    /// Start a recording session.
    func start(route: RecognitionRoute) async throws {
        try await serialized { [self] in
            await startupTask?.value
            guard phase == .idle else { return }
            try await beginSession(route: route)
        }
    }

    private func beginSession(route: RecognitionRoute) async throws {
        lastError = nil
        statusMessages.removeAll()

        await translator.setDirections(route.eagerTranslationDirections)
        // Fresh page per session: the previous session's transcript (already
        // archived — or deliberately discarded) must not lead the new one,
        // on screen or in refinement history.
        store.clear()
        jobs.yieldToRecording()
        // Recording preempts post-hoc work — but let a cancelled import/
        // summarize fully release its GPU/ASR memory before live capture
        // loads its own models, or both touch Metal at once and the OS kills
        // the process. Bounded: yieldToRecording already cancelled the holder.
        await jobs.waitForHeavyIdle()
        speakerNames.removeAll()
        sessionID = UUID()
        lastFinishedSessionID = nil
        liveChunker = LiveChunker()
        liveNotes.removeAll()
        notesEndEntryID = nil
        liveMappingStopped = false
        audioAnchors.removeAll()
        evictedEntries.removeAll()
        liveAttachments.removeAll()
        if saveRecordingsEnabled, let sessionID {
            let recorder = SessionRecorder()
            self.recorder = recorder
            await recorder.begin(sessionID: sessionID)
        }

        // Diarization: Sortformer labels up to 4 voices as audio streams in.
        // The picker value only gates on/off (0/1 = off); Sortformer's slot
        // count is fixed, so picks above 4 simply use all 4 slots. The model
        // load must not block session start — captions begin immediately and
        // attribution kicks in once the model is ready.
        diarizationActive = VoiceprintService.clusterCap(
            forPickerValue: captionSpeakerCount) != nil
        utteranceStartAudioSeconds = nil
        utteranceEndAudioSeconds = nil
        if diarizationActive {
            await streamingDiarizer.start()
            if await streamingDiarizer.state != .ready {
                setStatus(.diarizer, String(localized: "Preparing speaker separation…"))
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.streamingDiarizer.loadIfNeeded(source: self.diarizerSource)
                    } catch {
                        self.lastError = String(
                            localized: "Speaker separation unavailable: \(error.localizedDescription)")
                    }
                    self.setStatus(.diarizer, nil)
                }
            }
        } else {
            await streamingDiarizer.stop()
        }

        ensureEngine(for: route.source)
        Task { [llm] in await llm.resetHeatStats() }
        if let engine = engines[engineKey(for: route.source)] as? SenseVoiceEngine {
            Task { await engine.resetHeatStats() }
        }

        do {
            try await beginTurn(route: route)
        } catch {
            // Unwind everything beginSession set up, or a failed start
            // leaks state for a session that doesn't exist.
            await recorder?.abort()
            recorder = nil
            sessionID = nil
            diarizationActive = false
            await streamingDiarizer.stop()
            setStatus(.diarizer, nil)
            phase = .idle
            throw error
        }

        sessionStartedAt = .now
        // First journal heartbeat: from here on, a dead process leaves
        // enough on disk to recover the session.
        writeJournal()
        publishSessionStarted(route: route)
        installSystemObservers()
        #if os(iOS)
        let keepOn = UserDefaults.standard.object(forKey: "display.keepScreenOn") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "display.keepScreenOn")
        UIApplication.shared.isIdleTimerDisabled = keepOn
        #endif
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

    /// Dismiss the post-recording card.
    func clearLastFinishedSession() {
        lastFinishedSessionID = nil
        lastFinishedWasInterrupted = false
    }

    /// Attach a photo to the running session: stored beside recordings,
    /// OCR'd in the background (Vision — no MLX contention), anchored to
    /// the last finalized entry so it lands in the right transcript spot.
    func attachImage(_ image: UIImage) {
        guard isRunning, let sessionID,
              let data = ImageTextExtractor.jpegData(for: image) else { return }
        let fileName = "\(UUID().uuidString).jpg"
        try? FileManager.default.createDirectory(
            at: SessionArchive.attachmentsDirectory, withIntermediateDirectories: true)
        guard (try? data.write(
            to: SessionArchive.attachmentURL(fileName: fileName),
            options: .atomic)) != nil else { return }
        let attachment = SessionRecord.Attachment(
            fileName: fileName,
            timestamp: .now,
            anchorEntryID: store.entries
                .last { $0.state != .volatile }?.id)
        liveAttachments.append(attachment)
        writeJournal()
        // OCR off the hot path. Skipped only under the heaviest thermal
        // shedding — it's deferrable work; a missing result just means the
        // photo contributes no text.
        guard thermal.policy != .llmUnloaded else { return }
        let attachmentID = attachment.id
        Task { [weak self] in
            let text = await ImageTextExtractor.recognizeText(in: image)
            guard let text else { return }
            self?.applyAttachmentText(text, attachmentID: attachmentID, sessionID: sessionID)
        }
        Task { [weak self] in
            await self?.enqueueAttachmentDescription(attachment, sessionID: sessionID)
        }
    }

    /// Attach a photo to a saved session (detail view). Unanchored — it
    /// renders in the Photos section and trails the markdown export.
    func attachImage(_ image: UIImage, to recordID: UUID) {
        guard var record = archive.sessions.first(where: { $0.id == recordID }),
              let data = ImageTextExtractor.jpegData(for: image) else { return }
        let fileName = "\(UUID().uuidString).jpg"
        try? FileManager.default.createDirectory(
            at: SessionArchive.attachmentsDirectory, withIntermediateDirectories: true)
        guard (try? data.write(
            to: SessionArchive.attachmentURL(fileName: fileName),
            options: .atomic)) != nil else { return }
        let attachment = SessionRecord.Attachment(fileName: fileName, timestamp: .now)
        record.attachments = (record.attachments ?? []) + [attachment]
        archive.update(record)
        Task { [weak self] in
            let text = await ImageTextExtractor.recognizeText(in: image)
            guard let text else { return }
            self?.applyAttachmentText(text, attachmentID: attachment.id, sessionID: recordID)
        }
        Task { [weak self] in
            await self?.enqueueAttachmentDescription(attachment, sessionID: recordID)
        }
    }

    /// Remove a photo from the running session. Any in-flight OCR/description
    /// for it lands on nothing (updateAttachment no-ops once it's gone).
    func removeAttachment(_ id: UUID) {
        guard let index = liveAttachments.firstIndex(where: { $0.id == id }) else { return }
        let fileName = liveAttachments[index].fileName
        liveAttachments.remove(at: index)
        try? FileManager.default.removeItem(
            at: SessionArchive.attachmentURL(fileName: fileName))
        writeJournal()
    }

    /// Deliver an OCR result to wherever the attachment lives now: the
    /// live session if it's still running, the archived record otherwise.
    private func applyAttachmentText(
        _ text: String, attachmentID: UUID, sessionID: UUID
    ) {
        updateAttachment(attachmentID, sessionID: sessionID) {
            $0.ocrText = text
            $0.summaryRecords = nil
        }
    }

    /// Mutate an attachment wherever it lives now: the running session's
    /// live list, or the archived record (OCR/descriptions can land after
    /// the session stopped, or for post-hoc photos).
    private func updateAttachment(
        _ attachmentID: UUID, sessionID: UUID,
        mutate: (inout SessionRecord.Attachment) -> Void
    ) {
        if self.sessionID == sessionID,
           let index = liveAttachments.firstIndex(where: { $0.id == attachmentID }) {
            mutate(&liveAttachments[index])
            writeJournal()
        } else if var record = archive.sessions.first(where: { $0.id == sessionID }),
                  let index = record.attachments?.firstIndex(where: { $0.id == attachmentID }) {
            mutate(&record.attachments![index])
            archive.update(record)
        }
    }

    /// Queue a VLM description when the active model can read images.
    /// Admission mirrors `enqueueChunkNote`: never start LLM work that
    /// live speech or thermal pressure would have to fight.
    private func enqueueAttachmentDescription(
        _ attachment: SessionRecord.Attachment, sessionID: UUID
    ) async {
        guard llmEnabled, thermal.policy == .full,
              await llm.model.supportsVision, await llmIsReady() else { return }
        let language = AppLanguage.devicePreferred
            ?? activeDirection?.target ?? .english
        await describeQueue?.enqueue(AttachmentDescribeQueue.Job(
            attachmentID: attachment.id,
            sessionID: sessionID,
            fileURL: SessionArchive.attachmentURL(fileName: attachment.fileName),
            language: language,
            context: recentTranscriptContext()))
    }

    /// Last few finalized transcript lines, for grounding a photo description
    /// in what was being discussed. Empty before any speech is finalized.
    private func recentTranscriptContext() -> String {
        let text = store.entries
            .filter { $0.state != .volatile }
            .suffix(4)
            .map(\.sourceText)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(400))
    }

    /// Snapshot the running session to the crash journal.
    private func writeJournal() {
        guard let sessionID, let startedAt = sessionStartedAt else { return }
        let inputs = JournalSnapshotInputs(
            sessionID: sessionID,
            mode: .captions,
            startedAt: startedAt,
            evicted: evictedEntries,
            live: store.entries,
            timeline: audioAnchors.isEmpty ? nil : AudioTimeline(anchors: audioAnchors),
            speakerNames: speakerNames,
            recordingSpeakerCount: captionSpeakerCount,
            audioFileName: recorder != nil ? SessionRecorder.fileName(for: sessionID) : nil,
            chunkNotes: liveNotes,
            notesEndEntryID: notesEndEntryID,
            attachments: liveAttachments)
        Task { await journalWriter.write(building: inputs) }
    }

    private func endSession() async {
        guard phase != .idle else { return }
        await endTurn()
        phase = .idle
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        thermalWatch?.cancel()
        thermalWatch = nil
        removeSystemObservers()
        statusMessages.removeAll()
        await streamingDiarizer.stop()
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
                entries: archivableEntries,
                mode: .captions,
                speakerNames: speakerNames,
                startedAt: startedAt,
                artifacts: SessionArtifacts(
                    sessionID: sessionID ?? UUID(),
                    audioFileName: audioFileName,
                    chunkNotes: liveNotes,
                    notesEndEntryID: notesEndEntryID,
                    speakerCount: captionSpeakerCount,
                    timeline: audioFileName != nil && !audioAnchors.isEmpty
                        ? AudioTimeline(anchors: audioAnchors) : nil,
                    attachments: liveAttachments))
            if saved == nil {
                if let audioFileName {
                    try? FileManager.default.removeItem(
                        at: SessionArchive.recordingURL(fileName: audioFileName))
                }
                for attachment in liveAttachments {
                    try? FileManager.default.removeItem(
                        at: SessionArchive.attachmentURL(fileName: attachment.fileName))
                }
                // Never delete a recording in silence: say why it vanished.
                showNotice(String(
                    localized: "Nothing was captured, so the session wasn't saved."))
            }
            if let saved, saved.entries.isEmpty {
                // Audio-only save (speech never transcribed): nothing to
                // summarize, so skip the scenario card but confirm the save.
                showNotice(String(
                    localized: "Recording saved to Sessions — no speech was transcribed."))
            }
            lastFinishedSessionID = saved.flatMap {
                $0.entries.isEmpty ? nil : $0.id
            }
            lastFinishedWasInterrupted = false
        }
        let savedLabel = liveNotes.first?.headline
        // Stop further journal snapshots before clearing: writeJournal guards
        // on a non-nil sessionID, so any stray call during the await below
        // early-returns and can't resurrect the file.
        sessionStartedAt = nil
        sessionID = nil
        // Clean shutdown: the archive (not the journal) owns the session now.
        // Awaiting the serial writer drops any queued snapshot and removes the
        // file, so an in-flight per-utterance write can't resurrect the journal.
        await journalWriter.clear()
        audioAnchors.removeAll()
        evictedEntries.removeAll()
        liveAttachments.removeAll()
        liveNotes.removeAll()
        notesEndEntryID = nil
        publishSessionEnded(label: savedLabel)
        jobs.resumeAfterRecording()
    }

    /// Mirror session state to the lock screen (Live Activity) and the
    /// widget extension (Control Center toggle reads the app group).
    private func publishSessionStarted(route: RecognitionRoute) {
        liveActivity.start(startedAt: sessionStartedAt ?? .now, title: route.displayName)
        #if os(iOS)
        RecordingSharedState.write(.init(isRunning: true, startedAt: sessionStartedAt))
        ControlCenter.shared.reloadControls(ofKind: RecordingSharedState.controlKind)
        #endif
    }

    /// `label` lets the "Saved" state show the session's first note
    /// headline when live mapping produced one — content beats boilerplate.
    private func publishSessionEnded(label: String? = nil) {
        liveActivity.end(finalLabel: label ?? String(localized: "Saved"))
        #if os(iOS)
        RecordingSharedState.write(.init(isRunning: false, startedAt: nil))
        ControlCenter.shared.reloadControls(ofKind: RecordingSharedState.controlKind)
        #endif
    }

    // MARK: System events (interruptions, route changes, backgrounding)

    private func installSystemObservers() {
        #if os(iOS)
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
                    self.restartCurrentTurn(reason: "audio route changed; rebinding microphone")
                }
            }
        })
        #endif
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
                guard case .listening(let route) = phase else { return }
                logger.info("audio interrupted (call/Siri); pausing session")
                await endTurn()
                phase = .paused(.interrupted(resume: route))
                setStatus(.interruption, String(
                    localized: "Paused — another app is using the microphone"))
                liveActivity.update(
                    statusLabel: String(localized: "Paused"), isPaused: true)
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
                    try await beginTurn(route: resume)
                    liveActivity.update(
                        statusLabel: String(localized: "Recording"), isPaused: false)
                } catch {
                    lastError = error.localizedDescription
                    await endSession()
                }
            }
        }
    }

    private func restartCurrentTurn(reason: String) {
        Task {
            try? await self.serialized { [self] in
                guard case .listening(let route) = phase else { return }
                logger.info("restarting turn: \(reason)")
                await endTurn()
                do {
                    try await beginTurn(route: route)
                } catch {
                    lastError = error.localizedDescription
                    await endSession()
                }
            }
        }
    }

    /// Scene is leaving the foreground. Stop live speaker separation before
    /// background: its FluidAudio/CoreML path submits Metal command buffers,
    /// and iOS kills background submissions instead of handing us an error.
    ///
    /// Post-hoc LLM/ASR jobs are ABANDONED here, at `.inactive` (which
    /// fires before `.background`): cancel the job, flag the LLM so its
    /// generation loop stops at the next boundary, and touch nothing else —
    /// no draining, no cleanup. Waiting on the GPU during a scene
    /// transition can wedge MLX's global eval lock forever (the frozen-app
    /// bug); abandoning costs at most one checkpointed chunk, and even a
    /// buffer abort surfaces as a caught error in LLMService (forked mlx)
    /// that suspends the job for a foreground restart. Transient
    /// `.inactive` (control center, app switcher) pays the same small
    /// price.
    func handleInactive() {
        pauseLiveDiarizationForSceneExit()
        // Skip the .inactive that precedes .active on the way back from
        // background (isBackgrounded still set): only act when actually
        // leaving the foreground.
        guard !isBackgrounded else { return }
        jobs.setBackgrounded(true)
        forwardLLMSceneState(backgrounded: true)
    }

    /// Ordered forwarding of scene state to the LLM actor: each handoff is
    /// chained behind the previous one, so a rapid inactive→active flip can
    /// never deliver set-true after set-false and leave generation parked
    /// forever.
    private func forwardLLMSceneState(backgrounded: Bool) {
        llmSceneForward = Task { [llm, previous = llmSceneForward] in
            await previous?.value
            await llm.setBackgrounded(backgrounded)
        }
    }

    /// Scene went to background. A running session keeps capturing — the
    /// audio background mode keeps ASR and the AAC recorder alive with the
    /// screen locked — but ALL Metal-backed work pauses. Refinement jobs
    /// fall back to their drafts; note jobs are held for foreground catch-up.
    /// Idle in background frees the big models instead.
    func handleBackground() {
        pauseLiveDiarizationForSceneExit()
        isBackgrounded = true
        // No Metal work may run in the background — it aborts the process
        // uncatchably (an in-flight ASR decode included). Post-hoc jobs were
        // already cancelled at `.inactive` (earlier, so their GPU work could
        // drain); this re-asserts the suspension defensively (idempotent).
        // Imports/summaries resume from their checkpoints on foreground.
        forwardLLMSceneState(backgrounded: true)
        jobs.setBackgrounded(true)
        // Persistence is asynchronous and coalesced; land whatever's queued
        // before a background jetsam can drop it. The grace keeps iOS from
        // suspending the process mid-flush — without it this Task races
        // suspension and a jetsam can revert the session to its pre-job
        // state (e.g. a summary checkpoint that never reached disk).
        let flushGrace = BackgroundTaskGrace()
        flushGrace.begin(name: "persist-flush")
        Task { [archive] in
            await archive.flushPersistence()
            flushGrace.end()
        }
        // Photo descriptions pause in BOTH branches: post-hoc jobs can be
        // mid-generation with no session running.
        Task { [describeQueue] in await describeQueue?.setPaused(true) }
        if isRunning {
            Task { [refinement, noteQueue, llm] in
                await refinement?.setPaused(true)
                await noteQueue?.setPaused(true)
                // Request an unload; LLMService defers MLX cleanup until
                // foreground if iOS has already revoked GPU access.
                await llm.unload()
            }
        } else {
            backgroundUnload = Task { [llm, streamingDiarizer, weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                // A paused import still holds its activity slot until
                // foreground resumes it, so hasActiveWork covers it here too.
                // The resident weights worth shedding are the LLM and the
                // streaming model; LLMService defers MLX cleanup if needed.
                guard self?.jobs.hasActiveWork != true else { return }
                await llm.unload()
                await streamingDiarizer.unload()
            }
        }
    }

    func handleForeground() {
        isBackgrounded = false
        resumeLiveDiarizationAfterSceneExit()
        // Un-park the model and restart any LLM job background cancelled.
        forwardLLMSceneState(backgrounded: false)
        jobs.setBackgrounded(false)
        backgroundUnload?.cancel()
        backgroundUnload = nil
        if SystemResources.availableMemoryBytes() >= Self.memoryShedFloor {
            lastMemoryShed = nil
            // Drop the "paused (low memory)" banner once headroom is back —
            // outside a live session nothing else clears it.
            setStatus(.memory, nil)
        }
        Task { [describeQueue] in await describeQueue?.setPaused(false) }
        guard isRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            if await self.llmIsReady() {
                // Held note jobs catch up in the coming silence gaps.
                if self.thermal.policy == .full {
                    await self.refinement?.setPaused(false)
                }
                await self.noteQueue?.setPaused(false)
            } else {
                // A background memory warning may have unloaded the LLM;
                // the load's success path unpauses both queues.
                self.loadLLMIfAllowed()
            }
        }
    }

    private func pauseLiveDiarizationForSceneExit() {
        guard isRunning, diarizationActive else { return }
        diarizationPausedForSceneExit = true
        diarizationActive = false
        setStatus(.diarizer, nil)
        Task { [streamingDiarizer] in await streamingDiarizer.unload() }
    }

    private func resumeLiveDiarizationAfterSceneExit() {
        guard diarizationPausedForSceneExit else { return }
        diarizationPausedForSceneExit = false
        guard isRunning,
              let speakerCap = VoiceprintService.clusterCap(
                forPickerValue: captionSpeakerCount)
        else { return }
        diarizationActive = true
        _ = speakerCap  // Sortformer's slot count is fixed; cap only gates on/off.
        utteranceStartAudioSeconds = nil
        utteranceEndAudioSeconds = nil
        Task { [weak self] in
            guard let self else { return }
            if await self.streamingDiarizer.state != .ready {
                self.setStatus(.diarizer, String(localized: "Preparing speaker separation…"))
                try? await self.streamingDiarizer.loadIfNeeded(source: self.diarizerSource)
                self.setStatus(.diarizer, nil)
            }
            guard Self.shouldRunLiveDiarization(
                diarizationActive: self.diarizationActive,
                isBackgrounded: self.isBackgrounded) else { return }
            // Sortformer can't resume a stream across the background gap
            // (model was unloaded); start fresh. Earlier entries keep the
            // slots they already have on screen.
            await self.streamingDiarizer.start()
        }
    }

    // MARK: Turn plumbing

    /// Engine selection: "asr.engine" == "sensevoice" uses the SenseVoice
    /// backend when its model is installed, falling back to Apple with a
    /// status pill otherwise. Changing the setting invalidates cached
    /// engines (they are rebuilt per session via prepare anyway).
    private func engineKey(
        for source: RecognitionLanguageSelection, kind: String? = nil
    ) -> RecognitionLanguageSelection {
        let kind = kind ?? enginesKind
        return kind == "apple" ? .language(source.fallbackLanguage) : source
    }

    private func ensureEngine(for source: RecognitionLanguageSelection) {
        #if os(macOS)
        let wantsSenseVoice = false
        #else
        let wantsSenseVoice = UserDefaults.standard.string(forKey: "asr.engine") == "sensevoice"
        #endif
        let kind: String
        if wantsSenseVoice, SenseVoiceModelStore.isInstalled {
            kind = "sensevoice"
            setStatus(.asr, nil)
        } else {
            kind = "apple"
            setStatus(.asr, wantsSenseVoice
                ? String(localized: "SenseVoice model not downloaded — using Apple recognition.")
                : nil)
        }
        if enginesKind != kind {
            engines.removeAll()
            activeEngineKey = nil
            enginesKind = kind
        }
        let key = engineKey(for: source, kind: kind)
        if engines[key] == nil {
            engines[key] = kind == "sensevoice"
                ? SenseVoiceEngine(sourceSelection: source)
                : TranscriptionEngine(language: key.fallbackLanguage)
        }
    }

    private func beginTurn(route: RecognitionRoute) async throws {
        // Self-heal: a turn can ask for a direction the session was not
        // started with. Build whatever is missing on demand.
        ensureEngine(for: route.source)
        for direction in route.eagerTranslationDirections {
            await translator.addDirection(direction)
        }
        let key = engineKey(for: route.source)
        guard let engine = engines[key] else {
            throw TranscriptionError.assetsUnavailable(route.source.fallbackLanguage)
        }

        activeEngineKey = nil
        let format = try await engine.prepare(
            contextualStrings: route.source == .auto
                ? []
                : hotwords.biasStrings(for: route.source.fallbackLanguage))
        let (buffers, levels) = try audio.start(outputFormat: format)
        let events: AsyncStream<TranscriptionEvent>
        do {
            events = try await engine.start()
        } catch {
            audio.stop()
            throw error
        }
        activeEngineKey = key
        phase = .listening(route)

        // Anchor the audio timeline before buffers start flowing: audio
        // written so far ↔ now. Skipped without a recorder (no file to map).
        if let recorder {
            audioAnchors.append(
                AudioTimeline.Anchor(wall: .now, audio: await recorder.secondsWritten))
        }

        feedTask = Task { [weak self, streamingDiarizer] in
            for await chunk in buffers {
                guard let self else { return }
                await engine.feed(chunk)
                // Checked live (not captured): the speaker-count picker can
                // enable diarization mid-turn and the tee must follow.
                if Self.shouldRunLiveDiarization(
                    diarizationActive: self.diarizationActive,
                    isBackgrounded: self.isBackgrounded) {
                    await streamingDiarizer.ingest(chunk)
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
                await self?.handle(event, route: route)
            }
        }
    }

    /// Tear down the live turn, DRAINING the event stream so flushed final
    /// results are processed instead of dropped, then freeze any leftover
    /// volatile entry so the next turn can never adopt and overwrite it.
    /// Callers set the next phase afterwards.
    private func endTurn() async {
        audio.stop()  // finishes the buffer + level streams
        if case .listening(let route) = phase {
            await engines[engineKey(for: route.source)]?.stop()  // flushes + finishes events
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
            // Interruption pauses come through here; the journal must hold
            // the frozen text in case the process never comes back.
            writeJournal()
        }
        level = 0
    }

    // MARK: Event handling

    private func handle(_ event: TranscriptionEvent, route: RecognitionRoute) async {
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
            await describeQueue?.setSpeechActive(active)
            chunkGapTimer?.cancel()
            if Self.shouldRunLiveDiarization(
                diarizationActive: diarizationActive,
                isBackgrounded: isBackgrounded) {
                // Stamp the utterance's audio-time bounds in the diarizer's
                // own clock so the ASR final attributes against the timeline.
                let audioSeconds = await streamingDiarizer.audioSeconds
                if active {
                    utteranceStartAudioSeconds = audioSeconds
                    utteranceEndAudioSeconds = nil
                } else {
                    utteranceEndAudioSeconds = audioSeconds
                }
            }
            if !active {
                loadLLMIfAllowed()
                scheduleChunkGapClose()
            }
            return
        }

        guard let output = segmenter.process(
            event, fallbackLanguage: route.source.fallbackLanguage)
        else { return }
        let direction = LanguagePair(
            source: output.language,
            target: route.target ?? output.language)

        switch output.kind {
        case .volatileUpdate:
            let entryID = store.applyVolatile(text: output.text, direction: direction)
            if direction.source != direction.target {
                await translator.addDirection(direction)
                translator.draftDebounced(
                    output.text, direction: direction, entryID: entryID, store: store)
            }

        case .finalized(let refine):
            let diarize = Self.shouldRunLiveDiarization(
                diarizationActive: diarizationActive, isBackgrounded: isBackgrounded)

            // Mid-utterance speaker split: when the engine gives per-word
            // timings (Apple) and the diarizer maps the runs to two or more
            // voices, this one ASR utterance becomes several captions — the
            // UI groups consecutive entries by speaker, so they render apart.
            if diarize, let runs = output.timedRuns,
               let parts = await splitBySpeaker(runs: runs, language: direction.source) {
                let entries = store.finalizeActiveSplit(parts: parts, direction: direction)
                writeJournal()
                for entry in entries {
                    await processFinalizedEntry(entry, direction: direction, refine: refine)
                }
                return
            }

            // Single-entry path. Tier-0 hotword fixup restores near-miss
            // hotwords before anything else sees the text.
            let text = hotwords.matcher.fixup(output.text, language: direction.source)
            guard let entry = store.finalizeActive(text: text, direction: direction)
            else { return }
            // Attribute the whole utterance to a voice slot by overlapping its
            // audio-time bounds against Sortformer's timeline. Identities are
            // stable across the session, so there are no retroactive relabels.
            if diarize, let start = utteranceStartAudioSeconds,
               let slot = await streamingDiarizer.attribute(
                start: start, end: utteranceEndAudioSeconds ?? start) {
                store.setSpeaker(slot, for: entry.id)
            }
            writeJournal()
            await processFinalizedEntry(entry, direction: direction, refine: refine)

        case .discard:
            store.discardActiveIfEmpty()
        }
    }

    /// Per-entry work after a finalized caption lands: live-summary chunking,
    /// tier-1 translation, and tier-2 refinement. Factored out of the finalize
    /// handler so a speaker-split utterance can run it for each part.
    private func processFinalizedEntry(
        _ entry: CaptionEntry, direction: LanguagePair, refine: Bool
    ) async {
        // Live summary mapping: a closed chunk generates its note in the
        // next silence gap.
        if let closed = liveChunker.append(store.entry(for: entry.id) ?? entry) {
            await enqueueChunkNote(for: closed)
        }

        // Transcribe-only sessions (source == target) have nothing to refine:
        // the transcript IS the record of what was said.
        let translationEnabled = direction.source != direction.target
        guard translationEnabled else {
            store.setRefined(nil, for: entry.id)
            return
        }
        guard let draft = await produceDraft(for: entry) else { return }

        let matcher = hotwords.matcher
        let text = entry.sourceText
        // Hotword near-misses force refinement even for short utterances —
        // names usually appear in exactly those.
        let forced = matcher.shouldForceRefine(text, language: direction.source)
        let wantsRefinement = (refine || forced) && RefinementGate.shouldRefine(
            textLength: text.count,
            forced: forced,
            thermalState: thermal.thermalState,
            reduceHeat: reduceHeat)
        // !isBackgrounded: the paused queue silently DROPS enqueued jobs — a
        // backgrounded entry marked refining would spin forever. It takes the
        // draft path instead.
        if wantsRefinement, llmEnabled, !isBackgrounded,
           thermal.policy == .full, await llmIsReady() {
            store.markRefining(entry.id)
            let history = store.recentHistory(limit: 6).map {
                PromptBuilder.HistoryTurn(
                    sourceLanguage: $0.direction.source,
                    sourceText: $0.sourceText,
                    translation: $0.displayTranslation ?? "")
            }
            await refinement?.enqueue(RefinementQueue.Job(
                entryID: entry.id,
                source: text,
                draft: draft,
                direction: direction,
                history: history,
                glossary: matcher.glossaryLines(
                    direction: direction, sourceText: text)))
        } else {
            store.setRefined(nil, for: entry.id)
        }
    }

    /// Group a final utterance's timed runs into consecutive same-speaker
    /// parts (hotword fixup applied per part). Returns nil — meaning "don't
    /// split, take the single-entry path" — when the runs resolve to one
    /// speaker or can't be attributed. A nil-slot run joins the part before it.
    private func splitBySpeaker(
        runs: [TimedRun], language: AppLanguage
    ) async -> [(text: String, speaker: Int?, offset: TimeInterval)]? {
        guard runs.count > 1 else { return nil }
        let diarizerRuns = Self.runsInDiarizerClock(
            runs, utteranceStart: utteranceStartAudioSeconds)
        var slots: [Int?] = []
        slots.reserveCapacity(runs.count)
        for run in diarizerRuns {
            slots.append(await streamingDiarizer.attribute(start: run.start, end: run.end))
        }
        // Worth splitting only when two or more distinct voices appear.
        guard Set(slots.compactMap { $0 }).count > 1 else { return nil }

        let matcher = hotwords.matcher
        let firstStart = runs.first?.start ?? 0
        let cleaned = Self.groupRuns(runs, slots: slots).compactMap {
            part -> (text: String, speaker: Int?, offset: TimeInterval)? in
            let fixed = matcher.fixup(
                part.text.trimmingCharacters(in: .whitespacesAndNewlines),
                language: language)
            return fixed.hasSpeechContent
                ? (text: fixed, speaker: part.speaker, offset: max(0, part.start - firstStart))
                : nil
        }
        return cleaned.count > 1 ? cleaned : nil
    }

    /// Convert ASR run times into the streaming diarizer's session clock.
    /// Apple's per-run ranges can come from the recognizer timeline, while
    /// Sortformer's clock starts when live diarization begins.
    nonisolated static func runsInDiarizerClock(
        _ runs: [TimedRun], utteranceStart: TimeInterval?
    ) -> [TimedRun] {
        guard let utteranceStart, let firstStart = runs.first?.start else {
            return runs
        }
        return runs.map { run in
            let start = max(0, run.start - firstStart)
            let end = max(start, run.end - firstStart)
            return TimedRun(
                text: run.text,
                start: utteranceStart + start,
                end: utteranceStart + end)
        }
    }

    /// Group runs into consecutive same-speaker parts, concatenating their
    /// text. A run the diarizer couldn't attribute (nil slot) joins the part
    /// before it. Pure, so the grouping is unit-testable without the model.
    nonisolated static func groupRuns(
        _ runs: [TimedRun], slots: [Int?]
    ) -> [(text: String, speaker: Int?, start: TimeInterval)] {
        var parts: [(text: String, speaker: Int?, start: TimeInterval)] = []
        for (run, slot) in zip(runs, slots) {
            let effective = slot ?? parts.last?.speaker
            if !parts.isEmpty, parts[parts.count - 1].speaker == effective {
                parts[parts.count - 1].text += run.text
            } else {
                parts.append((text: run.text, speaker: effective, start: run.start))
            }
        }
        return parts
    }

    /// Tier-1 draft for a finalized entry: cancel pending volatile work,
    /// translate, and store. Returns nil and marks the entry on failure.
    private func produceDraft(for entry: CaptionEntry) async -> String? {
        translator.cancelPending(entryID: entry.id)
        await translator.addDirection(entry.direction)
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
        if isBackgrounded {
            // Enqueue blind: the paused queue HOLDS jobs for foreground
            // catch-up. Running the readiness gate here would stop live
            // mapping the first time the screen locks (the LLM is never
            // "ready" while backgrounded), killing notes for the session.
            guard llmEnabled else {
                liveMappingStopped = true
                return
            }
        } else {
            guard llmEnabled, thermal.policy == .full, await llmIsReady() else {
                liveMappingStopped = true
                return
            }
        }
        let sourceIDs = chunk.indices.map { String(format: "m%03d", $0 + 1) }
        let text = zip(sourceIDs, chunk).map { id, entry in
            let label = entry.speaker.map {
                speakerNames[$0] ?? String(localized: "Speaker \($0 + 1)")
            }
            return "\(id)\t" + (label.map { "[\($0)] " } ?? "") + entry.sourceText
        }.joined(separator: "\n")
        let language = AppLanguage.devicePreferred ?? chunk[0].direction.target
        // Scored against the chunk's source language, where the
        // mis-hearings the glossary corrects actually live.
        let vocabulary = hotwords.matcher.noteGlossaryLines(
            language: chunk[0].direction.source, text: text)
        await noteQueue?.enqueue(ChunkNoteQueue.Job(
            chunkText: text,
            anchorEntryID: chunk[0].id,
            endEntryID: chunk[chunk.count - 1].id,
            startedAt: chunk[0].createdAt,
            fallbackHeadline: String(chunk[0].sourceText.prefix(24)),
            language: language,
            chunkID: "c" + chunk[0].id.uuidString.prefix(8),
            timeRange: liveChunkTimeRange(chunk),
            sourceIDs: sourceIDs,
            vocabulary: vocabulary))
    }

    private func liveChunkTimeRange(_ chunk: [CaptionEntry]) -> String {
        guard let first = chunk.first else { return "未明确" }
        let base = sessionStartedAt ?? first.createdAt
        let start = max(0, first.createdAt.timeIntervalSince(base))
        let end = max(start, chunk.last?.createdAt.timeIntervalSince(base) ?? start)
        func clock(_ seconds: TimeInterval) -> String {
            let total = max(0, Int(seconds.rounded()))
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
        return "\(clock(start))-\(clock(end))"
    }

    /// Change the speaker count, live: existing utterances are re-clustered
    /// into the new cap and relabeled on screen. The audio tee follows
    /// automatically (checked per-chunk in the feed loop).
    func updateSpeakerCount(_ count: Int) {
        UserDefaults.standard.set(count, forKey: "captions.speakerCount")
        guard isRunning else { return }
        let cap = VoiceprintService.clusterCap(forPickerValue: count)
        diarizationActive = cap != nil
        utteranceStartAudioSeconds = nil
        utteranceEndAudioSeconds = nil
        Task { [weak self] in
            guard let self else { return }
            if cap != nil {
                if await self.streamingDiarizer.state != .ready {
                    self.setStatus(.diarizer, String(localized: "Preparing speaker separation…"))
                    try? await self.streamingDiarizer.loadIfNeeded(source: self.diarizerSource)
                    self.setStatus(.diarizer, nil)
                }
                // Fresh stream from now; entries already labeled keep their slots.
                await self.streamingDiarizer.start()
            } else {
                await self.streamingDiarizer.stop()
            }
        }
    }

    /// Apply a changed mic-pickup preset. Every knob it tunes lives in
    /// per-turn state — VAD config inside the engines, boost inside the
    /// capture tap — so a live session rebinds by restarting its turn,
    /// the same machinery as a route change; endTurn's drain finalizes
    /// in-flight speech first. Idle sessions just pick the preset up at
    /// the next start.
    func updateMicSensitivity() {
        guard isRunning else { return }
        restartCurrentTurn(reason: "mic pickup preset changed")
    }

    /// Apply a new translation target live. Existing transcript entries keep
    /// their concrete directions/translations; the next turn uses the new
    /// target.
    func updateTranslationTarget(_ target: AppLanguage?) {
        guard isRunning else { return }
        Task {
            try? await self.serialized { [self] in
                guard case .listening(let route) = phase else { return }
                let next = RecognitionRoute(source: route.source, target: target)
                guard next != route else { return }
                logger.info("restarting turn: translation target changed")
                await endTurn()
                do {
                    try await beginTurn(route: next)
                    liveActivity.update(statusLabel: next.displayName, isPaused: false)
                } catch {
                    lastError = error.localizedDescription
                    await endSession()
                }
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

    /// Opt-in low-heat / low-power mode (Settings). Trades caption latency
    /// and refinement frequency for less sustained compute.
    var reduceHeat: Bool { UserDefaults.standard.bool(forKey: "perf.reduceHeat") }

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

    /// Decode active-seconds of the live SenseVoice engine, or 0 when the
    /// active engine is Apple's recognizer (no in-process decode cost).
    func activeSenseVoiceDecodeSeconds() async -> Double {
        if let activeEngineKey,
           let sv = engines[activeEngineKey] as? SenseVoiceEngine {
            return await sv.decodeActiveSeconds
        }
        return 0
    }

    private func loadLLMIfAllowed() {
        // The background guard also blocks the 10s deferred load at session
        // start when the user locks immediately: 1.3GB of weights must not
        // load (and Metal must not warm) with the screen off.
        if let shed = lastMemoryShed, shed.duration(to: .now) < .seconds(60) {
            setStatus(.llm, nil)
            return
        }
        guard llmEnabled, thermal.policy == .full, !isBackgrounded else {
            setStatus(.llm, nil)
            return
        }
        Task { [llm] in
            await llm.setModel(ModelCatalog.liveModel)
            // Called on every silence gap; only show status when there is
            // actually a load to do (llm.load joins in-flight loads).
            if case .ready = await llm.loadState {
                self.setStatus(.llm, nil)
                return
            }
            self.setStatus(.llm, String(localized: "Warming up the AI model…"))
            do {
                // Never auto-download mid-session: weights are gigabytes and
                // the user never asked. Downloads happen only from explicit
                // UI (Settings, or a consent prompt on an AI feature).
                try await llm.load(policy: .requireDownloaded)
                await self.refinement?.setPaused(false)
                await self.noteQueue?.setPaused(false)
                self.lastMemoryShed = nil
                self.setStatus(.llm, nil)
                self.setStatus(.memory, nil)
            } catch LLMServiceError.modelNotDownloaded {
                self.setStatus(.memory, nil)
                self.setStatus(.llm, String(
                    localized: "AI model not downloaded — transcribing only (see Settings)"))
            } catch LLMServiceError.insufficientMemory {
                self.lastMemoryShed = .now
                await self.refinement?.setPaused(true)
                self.setStatus(.llm, nil)
                self.setStatus(.memory, String(
                    localized: "AI features paused (low memory)"))
            } catch is CancellationError {
                self.setStatus(.llm, nil)
            } catch {
                self.setStatus(.memory, nil)
                self.setStatus(.llm, String(localized: "AI features unavailable"))
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
                        self.setStatus(.llm, nil)
                        self.setStatus(.thermal, String(
                            localized: "AI features paused (device warm)"))
                    case .llmUnloaded:
                        await self.refinement?.setPaused(true)
                        await self.llm.unload()
                        self.setStatus(.llm, nil)
                        self.setStatus(.thermal, String(
                            localized: "AI features off (device hot)"))
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Memory-warning hook (RootView forwards the notification). The system
    /// is about to kill us — drop what can be dropped without background GPU.
    /// Tier-1 captions keep working; the LLM reloads on the next quiet gap.
    func handleMemoryWarning() {
        // Coalesce bursts of critical-pressure events — one shed is enough —
        // but gate on time since the last shed rather than the (session-scoped)
        // status banner: a genuine later event, e.g. after a background
        // summarize/import job reloaded the model, must still be able to shed
        // again. The headroom check at the dispatch source already stops
        // system-wide thrash.
        if let shed = lastMemoryShed, shed.duration(to: .now) < .seconds(3) { return }
        // While a summarize/import/re-transcribe is actively running in the
        // foreground, unloading the weights is self-defeating: the job's
        // very next generate self-heals with a full reload, so the warning
        // buys churn (10s+ of load, extra allocation spikes) instead of
        // headroom. Shed the MLX buffer cache and keep working; a warning
        // with no job running (or backgrounded — jobs are held there)
        // still unloads fully.
        let shedOnly = !isBackgrounded && jobs.hasRunningLLMJob
        #if os(iOS)
        let sceneState = UIApplication.shared.applicationState.rawValue
        logger.warning(
            "memory warning: \(shedOnly ? "shedding cache (job running)" : "unloading models") (appState=\(sceneState))")
        #else
        logger.warning("memory warning: unloading models")
        #endif
        lastMemoryShed = .now
        setStatus(.llm, nil)
        setStatus(.memory, String(localized: "AI features paused (low memory)"))
        let shouldUnloadVoiceprint = Self.shouldUnloadVoiceprintOnMemoryWarning(
            isRunning: isRunning,
            diarizationActive: diarizationActive)
        Task { [llm, streamingDiarizer, refinement, shouldUnloadVoiceprint, shedOnly] in
            await refinement?.setPaused(true)
            if shedOnly {
                await llm.clearCache()
            } else {
                await llm.unload()
            }
            // The live diarizer is the memory target during a session; the
            // offline voiceprint isn't loaded while recording.
            if shouldUnloadVoiceprint {
                await streamingDiarizer.unload()
            }
        }
    }
}
