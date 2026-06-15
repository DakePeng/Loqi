import AVFoundation
import Foundation
import Observation
import UIKit
import WidgetKit
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
    /// The one pipeline instance. App Intents (Action Button, Siri, the
    /// Live Activity stop button, the Control Center toggle) execute in
    /// the app process and must reach the same pipeline the UI drives.
    static let shared = CaptionPipeline()

    let store = CaptionStore()
    let translator = TranslationCoordinator()
    let thermal = ThermalMonitor()
    let hotwords = HotwordStore()
    let voiceprint = VoiceprintService()
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
        if case .listening(let direction) = phase { return direction }
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

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "pipeline")

    private let audio = AudioCaptureService()
    private let segmenter = TranscriptSegmenter()
    private var engines: [AppLanguage: any SpeechEngine] = [:]
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
    /// Fires on critical system memory pressure, foreground or background.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastMemoryShed: ContinuousClock.Instant?
    /// Serializes crash-journal writes off the main actor, coalescing the
    /// per-utterance snapshots so encoding + disk I/O never blocks captions.
    private let journalWriter = JournalWriter()
    /// Scene is in the background. While true, no LLM work may start (no
    /// loads, no refinement, no note generation) — captions and the
    /// recorder run alone.
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
        evictedEntries + store.entries(in: sessionMode)
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
    /// Auto, 2+ = hard cap (see VoiceprintService.clusterCap).
    var captionSpeakerCount: Int {
        UserDefaults.standard.integer(forKey: "captions.speakerCount")
    }

    /// Persisted download source for the speaker model (Settings key
    /// matches SettingsView's @AppStorage).
    var diarizerSource: DiarizerSource { .current }

    private var diarizationActive = false

    /// All live sessions are captions-mode now; the enum survives for old
    /// archived records.
    var sessionMode: SessionMode { .captions }

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

        // A journal on disk means the last process died mid-recording —
        // recover BEFORE the orphan sweep, which would otherwise delete
        // the very audio recovery exists to save.
        recoverInterruptedSession()
        archive.sweepOrphans()

        // UIKit's memory warning only arrives in the foreground; a
        // dispatch source also fires while recording with the screen
        // locked — exactly where jetsam was killing long sessions.
        //
        // BUT the source reports SYSTEM-WIDE pressure, which sits at
        // critical chronically on 6GB devices — reacting to every event
        // shed-thrashed the LLM (unload → silence-gap reload → pressure →
        // unload…) and killed in-flight summaries. Only shed when OUR
        // headroom is actually gone.
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: .critical, queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard os_proc_available_memory() < Self.memoryShedFloor else { return }
                self?.handleMemoryWarning()
            }
        }
        pressure.activate()
        memoryPressureSource = pressure
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
            RecordingSharedState.write(.init(isRunning: false, startedAt: nil))
            ControlCenter.shared.reloadControls(ofKind: RecordingSharedState.controlKind)
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
        // Fresh page per session: the previous session's transcript (already
        // archived — or deliberately discarded) must not lead the new one,
        // on screen or in refinement history.
        store.clear(sessionMode)
        jobs.yieldToRecording()
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

        // Diarization: cluster utterances into N voices ("Auto" = a generous
        // cap with the count discovered by similarity). The model load must
        // not block session start — captions begin immediately and
        // attribution kicks in once the model is ready.
        let speakerCap = VoiceprintService.clusterCap(forPickerValue: captionSpeakerCount)
        diarizationActive = speakerCap != nil
        if let speakerCap {
            await voiceprint.startDiarization(maxSpeakers: speakerCap)
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

        ensureEngine(for: direction.source)

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
        // First journal heartbeat: from here on, a dead process leaves
        // enough on disk to recover the session.
        writeJournal()
        publishSessionStarted(direction: direction)
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
            anchorEntryID: store.entries(in: sessionMode)
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

    /// Deliver an OCR result to wherever the attachment lives now: the
    /// live session if it's still running, the archived record otherwise.
    private func applyAttachmentText(
        _ text: String, attachmentID: UUID, sessionID: UUID
    ) {
        updateAttachment(attachmentID, sessionID: sessionID) { $0.ocrText = text }
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
            language: language))
    }

    /// Snapshot the running session to the crash journal: a ready-to-archive
    /// record mirroring exactly what a clean stop would save right now.
    /// Called at utterance cadence — a small atomic JSON write.
    private func writeJournal() {
        guard let sessionID, let startedAt = sessionStartedAt else { return }
        var record = SessionRecord(
            id: sessionID,
            mode: sessionMode,
            startedAt: startedAt,
            endedAt: .now,
            entries: SessionArchive.mappedEntries(
                from: archivableEntries,
                startedAt: startedAt,
                timeline: audioAnchors.isEmpty ? nil : AudioTimeline(anchors: audioAnchors)),
            speakerNames: speakerNames)
        if recorder != nil {
            record.audioFileName = SessionRecorder.fileName(for: sessionID)
        }
        if !liveNotes.isEmpty {
            record.chunkNotes = liveNotes
            record.liveNotesEndEntryID = notesEndEntryID
        }
        if !liveAttachments.isEmpty { record.attachments = liveAttachments }
        let snapshot = record
        Task { await journalWriter.write(snapshot) }
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
                entries: archivableEntries,
                mode: sessionMode,
                speakerNames: speakerNames,
                startedAt: startedAt,
                artifacts: SessionArtifacts(
                    sessionID: sessionID ?? UUID(),
                    audioFileName: audioFileName,
                    chunkNotes: liveNotes,
                    notesEndEntryID: notesEndEntryID,
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
    private func publishSessionStarted(direction: LanguagePair) {
        let title = direction.source == direction.target
            ? direction.source.displayName
            : direction.displayName
        liveActivity.start(startedAt: sessionStartedAt ?? .now, title: title)
        RecordingSharedState.write(.init(isRunning: true, startedAt: sessionStartedAt))
        ControlCenter.shared.reloadControls(ofKind: RecordingSharedState.controlKind)
    }

    /// `label` lets the "Saved" state show the session's first note
    /// headline when live mapping produced one — content beats boilerplate.
    private func publishSessionEnded(label: String? = nil) {
        liveActivity.end(finalLabel: label ?? String(localized: "Saved"))
        RecordingSharedState.write(.init(isRunning: false, startedAt: nil))
        ControlCenter.shared.reloadControls(ofKind: RecordingSharedState.controlKind)
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
                    self.restartCurrentTurn(reason: "audio route changed; rebinding microphone")
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
                    try await beginTurn(direction: resume)
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
                guard case .listening(let direction) = phase else { return }
                logger.info("restarting turn: \(reason)")
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

    /// Scene went to background. A running session keeps capturing — the
    /// audio background mode keeps ASR, the AAC recorder, and diarization
    /// alive with the screen locked — but ALL LLM work pauses: submitting
    /// Metal work from the background risks process termination, so this
    /// is a hard requirement, not a battery preference. Refinement jobs
    /// fall back to their drafts; note jobs are held for foreground
    /// catch-up. Idle in background frees the big models instead.
    func handleBackground() {
        isBackgrounded = true
        // No Metal work may run in the background — it aborts the process
        // uncatchably. Park new generations at the model, and cancel any
        // post-hoc LLM job already mid-generation (summarize / a
        // re-transcribe's summary phase). Imports and ASR keep running under
        // their grace — they never touch Metal — and park if they reach the
        // LLM. This is the post-hoc twin of the live-session pausing below.
        Task { [llm] in await llm.setBackgrounded(true) }
        jobs.setBackgrounded(true)
        // Photo descriptions pause in BOTH branches: post-hoc jobs can be
        // mid-generation with no session running.
        Task { [describeQueue] in await describeQueue?.setPaused(true) }
        if isRunning {
            Task { [refinement, noteQueue, llm] in
                await refinement?.setPaused(true)
                await noteQueue?.setPaused(true)
                // All LLM work is paused back here, so the loaded weights
                // are pure dead weight — and the single largest jetsam
                // target during long locked-screen recordings. Drop them;
                // handleForeground reloads and the queues catch up.
                await llm.unload()
            }
        } else {
            backgroundUnload = Task { [llm, voiceprint, weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                // A background import/re-transcribe may still be running in
                // its grace window — unloading voiceprint would race its
                // diarization. The job's own teardown frees memory instead.
                guard self?.jobs.hasActiveWork != true else { return }
                await llm.unload()
                await voiceprint.unload()
            }
        }
    }

    func handleForeground() {
        isBackgrounded = false
        // Un-park the model and restart any LLM job background cancelled.
        Task { [llm] in await llm.setBackgrounded(false) }
        jobs.setBackgrounded(false)
        backgroundUnload?.cancel()
        backgroundUnload = nil
        if os_proc_available_memory() >= Self.memoryShedFloor {
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

    // MARK: Turn plumbing

    /// Engine selection: "asr.engine" == "sensevoice" uses the SenseVoice
    /// backend when its model is installed, falling back to Apple with a
    /// status pill otherwise. Changing the setting invalidates cached
    /// engines (they are rebuilt per session via prepare anyway).
    private func ensureEngine(for language: AppLanguage) {
        let wantsSenseVoice = UserDefaults.standard.string(forKey: "asr.engine") == "sensevoice"
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
            enginesKind = kind
        }
        if engines[language] == nil {
            engines[language] = kind == "sensevoice"
                ? SenseVoiceEngine(language: language)
                : TranscriptionEngine(language: language)
        }
    }

    private func beginTurn(direction: LanguagePair) async throws {
        // Self-heal: a turn can ask for a direction the session was not
        // started with. Build whatever is missing on demand.
        ensureEngine(for: direction.source)
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

        // Anchor the audio timeline before buffers start flowing: audio
        // written so far ↔ now. Skipped without a recorder (no file to map).
        if let recorder {
            audioAnchors.append(
                AudioTimeline.Anchor(wall: .now, audio: await recorder.secondsWritten))
        }

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
            // Interruption pauses come through here; the journal must hold
            // the frozen text in case the process never comes back.
            writeJournal()
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
            await describeQueue?.setSpeechActive(active)
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

            // Heartbeat the crash journal with the newly finalized text
            // before the (slow) translation/refinement work below.
            writeJournal()

            // Transcribe-only sessions (source == target) have nothing to
            // refine: the transcript IS the record of what was said, and
            // LLM rewriting of it was removed — only the deterministic
            // hotword fixup (already applied above) touches source text.
            let translationEnabled = direction.source != direction.target
            guard translationEnabled else {
                store.setRefined(nil, for: entry.id)
                return
            }
            guard let draft = await produceDraft(for: entry) else { return }

            // Hotword near-misses force refinement even for short
            // utterances — names usually appear in exactly those.
            let wantsRefinement = refine
                || matcher.shouldForceRefine(text, language: direction.source)
            // !isBackgrounded: the paused queue silently DROPS enqueued
            // jobs — a backgrounded entry marked refining would spin
            // forever. It takes the draft path instead.
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

        case .discard:
            store.discardActiveIfEmpty()
        }
    }

    /// Tier-1 draft for a finalized entry: cancel pending volatile work,
    /// translate, and store. Returns nil and marks the entry on failure.
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
        let text = chunk.map { entry in
            let label = entry.speaker.map {
                speakerNames[$0] ?? String(localized: "Speaker \($0 + 1)")
            }
            return (label.map { "[\($0)] " } ?? "") + entry.sourceText
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
            vocabulary: vocabulary))
    }

    /// Change the speaker count, live: existing utterances are re-clustered
    /// into the new cap and relabeled on screen. The audio tee follows
    /// automatically (checked per-chunk in the feed loop).
    func updateSpeakerCount(_ count: Int) {
        UserDefaults.standard.set(count, forKey: "captions.speakerCount")
        guard isRunning else { return }
        let cap = VoiceprintService.clusterCap(forPickerValue: count)
        diarizationActive = cap != nil
        Task { [weak self] in
            guard let self else { return }
            if let cap {
                if await self.voiceprint.state != .ready {
                    self.setStatus(.diarizer, String(localized: "Preparing speaker separation…"))
                    try? await self.voiceprint.loadIfNeeded(source: self.diarizerSource)
                    self.setStatus(.diarizer, nil)
                }
                let relabels = await self.voiceprint.startDiarization(maxSpeakers: cap)
                for (entryID, slot) in relabels {
                    self.store.setSpeaker(slot, for: entryID)
                }
            } else {
                await self.voiceprint.stopDiarization()
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
        // The background guard also blocks the 10s deferred load at session
        // start when the user locks immediately: 1.3GB of weights must not
        // load (and Metal must not warm) with the screen off.
        if let shed = lastMemoryShed, shed.duration(to: .now) < .seconds(60) { return }
        guard llmEnabled, thermal.policy != .llmUnloaded, !isBackgrounded else { return }
        Task { [llm] in
            // Called on every silence gap; only show status when there is
            // actually a load to do (llm.load joins in-flight loads).
            if case .ready = await llm.loadState { return }
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
                        self.setStatus(.thermal, String(
                            localized: "AI features paused (device warm)"))
                    case .llmUnloaded:
                        await self.refinement?.setPaused(true)
                        await self.llm.unload()
                        self.setStatus(.thermal, String(
                            localized: "AI features off (device hot)"))
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
        // Coalesce bursts of critical-pressure events — one shed is enough —
        // but gate on time since the last shed rather than the (session-scoped)
        // status banner: a genuine later event, e.g. after a background
        // summarize/import job reloaded the model, must still be able to shed
        // again. The headroom check at the dispatch source already stops
        // system-wide thrash.
        if let shed = lastMemoryShed, shed.duration(to: .now) < .seconds(3) { return }
        logger.warning("memory warning: unloading models")
        lastMemoryShed = .now
        setStatus(.llm, nil)
        setStatus(.memory, String(localized: "AI features paused (low memory)"))
        Task { [llm, voiceprint, refinement] in
            await refinement?.setPaused(true)
            await llm.unload()
            await voiceprint.unload()
        }
    }
}
