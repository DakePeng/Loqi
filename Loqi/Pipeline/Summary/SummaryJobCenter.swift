import Foundation
import Observation

/// Owns every post-hoc session job — import, re-transcribe & summarize,
/// summarize — so their lifecycle is independent of any one screen:
/// progress survives navigation, every view instance of a session reads
/// the same state, and a session can never run two jobs at once.
/// Live-session work stays in CaptionPipeline; this is its post-hoc
/// counterpart.
///
/// Jobs never download weights unless the caller passed the user's explicit
/// consent (`allowDownload`); without it a missing model fails fast with
/// `.modelNotDownloaded` instead of silently pulling gigabytes.
@MainActor
@Observable
final class SummaryJobCenter {
    enum Activity: Equatable {
        /// Consented weights download running before the job proper.
        case downloadingModel(Double)
        /// Map/reduce in flight; `total > 1` once real chunk counts exist.
        case summarizing(done: Int, total: Int)
        case retranscribing(SessionRetranscriber.Phase)
        /// File import filling its placeholder record.
        case importing(FileImportEngine.Phase)
        /// In the serial re-transcribe queue, not yet started. Occupying
        /// the activity slot makes every existing isBusy guard cover it.
        case queuedRetranscribe
        /// A recording started; this job yields memory and resumes after.
        case pausedForRecording
    }

    enum JobError: LocalizedError {
        case aiDisabled

        var errorDescription: String? {
            String(localized: "AI features are turned off in Settings.")
        }
    }

    /// A finished background arrival (import completed) — the Sessions
    /// list flashes the row. Equatable so onChange can watch it.
    struct Completion: Equatable {
        let id: UUID
        let at: Date
    }

    private(set) var activities: [UUID: Activity] = [:]
    /// Most recent failure per session; cleared when its next job starts.
    private(set) var errors: [UUID: String] = [:]
    /// Smoothed time-remaining per session, written at most ~1/s so list
    /// rows don't re-render on every raw progress tick.
    private(set) var remaining: [UUID: TimeInterval] = [:]
    private(set) var lastCompleted: Completion?

    /// Live job handles for cancellation; never drives UI.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var etas: [UUID: ProcessingETA] = [:]
    @ObservationIgnored private var phaseKeys: [UUID: String] = [:]
    @ObservationIgnored private var graces: [UUID: BackgroundTaskGrace] = [:]
    /// FIFO of pending re-transcribes; one worker drains it so only one
    /// ASR decode ever runs at a time (two ONNX models don't fit).
    @ObservationIgnored private var retranscribeQueue: [RetranscribeRequest] = []
    @ObservationIgnored private var retranscribeWorker: Task<Void, Never>?
    @ObservationIgnored private var pausedForRecording = false
    /// The request that spawned a running re-transcribe task, kept so
    /// yieldToRecording() can re-enqueue it without reconstructing.
    @ObservationIgnored private var activeRetranscribeRequest: [UUID: RetranscribeRequest] = [:]
    /// True while the scene is backgrounded; LLM-generation jobs must not run.
    @ObservationIgnored private var isBackgrounded = false
    /// The summarize params of a job currently in (or entering) its LLM phase,
    /// so backgrounding can cancel the in-flight generation and restart it on
    /// foreground. Covers both plain summarize and a re-transcribe's summary
    /// phase (its transcript is already archived by then).
    @ObservationIgnored private var activeSummarizeRequest: [UUID: SummarizeRequest] = [:]
    /// Jobs cancelled by backgrounding, awaiting a foreground restart.
    @ObservationIgnored private var suspendedSummaries: [UUID: SummarizeRequest] = [:]

    private struct RetranscribeRequest {
        let sessionID: UUID
        let style: SummaryStyle
        let length: SummaryLength
        let allowDownload: Bool
    }

    private struct SummarizeRequest {
        let style: SummaryStyle
        let length: SummaryLength
        let allowDownload: Bool
        let suggestVocabulary: Bool
    }

    private let llm: LLMService
    private let archive: SessionArchive
    private let hotwords: HotwordStore
    private let translator: TranslationCoordinator
    private let voiceprint: VoiceprintService
    /// Post-hoc jobs must not fight a live session for the audio file
    /// or the model; injected so tests can construct this without a pipeline.
    private let isRecording: @MainActor () -> Bool

    init(
        llm: LLMService,
        archive: SessionArchive,
        hotwords: HotwordStore,
        translator: TranslationCoordinator,
        voiceprint: VoiceprintService,
        isRecording: @escaping @MainActor () -> Bool
    ) {
        self.llm = llm
        self.archive = archive
        self.hotwords = hotwords
        self.translator = translator
        self.voiceprint = voiceprint
        self.isRecording = isRecording
    }

    func isBusy(_ sessionID: UUID) -> Bool { activities[sessionID] != nil }
    func activity(for sessionID: UUID) -> Activity? { activities[sessionID] }
    func error(for sessionID: UUID) -> String? { errors[sessionID] }
    func clearError(for sessionID: UUID) { errors[sessionID] = nil }
    /// Anything running or queued — gates idle teardown (e.g. the
    /// background voiceprint unload) that would race a job.
    var hasActiveWork: Bool { !activities.isEmpty }

    /// Cancel a session's running or queued job. Cancellation is
    /// cooperative: a running ASR decode stops at its next segment check.
    func cancel(_ sessionID: UUID) {
        errors[sessionID] = nil
        if let index = retranscribeQueue.firstIndex(where: { $0.sessionID == sessionID }) {
            retranscribeQueue.remove(at: index)
            activities[sessionID] = nil
            return
        }
        tasks[sessionID]?.cancel()
    }

    /// Cancel heavy background work so a live recording gets full resources.
    /// Re-transcription requests are re-enqueued (restart from scratch after
    /// recording); imports cancel permanently (temp-file state is
    /// indeterminate). Synchronously re-enqueues BEFORE cancelling tasks so
    /// a very short recording can't race the propagation.
    func yieldToRecording() {
        pausedForRecording = true
        for (sessionID, activity) in activities {
            switch activity {
            case .retranscribing:
                if let req = activeRetranscribeRequest[sessionID] {
                    retranscribeQueue.insert(req, at: 0)
                }
                activities[sessionID] = .pausedForRecording
                tasks[sessionID]?.cancel()
            case .importing:
                tasks[sessionID]?.cancel()
            case .queuedRetranscribe:
                activities[sessionID] = .pausedForRecording
            default:
                break
            }
        }
        retranscribeWorker?.cancel()
        retranscribeWorker = nil
    }

    /// Recording ended — restore paused jobs and restart the queue drain.
    func resumeAfterRecording() {
        guard pausedForRecording else { return }
        pausedForRecording = false
        for (sessionID, activity) in activities {
            if case .pausedForRecording = activity {
                activities[sessionID] = .queuedRetranscribe
            }
        }
        drainRetranscribeQueue()
    }

    /// Scene moved to/from the background. LLM-generation jobs can't run there
    /// — a Metal command buffer submitted from the background aborts the whole
    /// process — so an in-flight summary generation is cancelled and restarted
    /// on foreground. Imports keep running (ASR + the system translator never
    /// touch Metal); a re-transcribe still doing its ASR pass keeps running
    /// too — when it reaches its summary phase the LLM itself parks it
    /// (`LLMService.setBackgrounded`), so only a generation already in flight
    /// needs the harder cancel/restart.
    func setBackgrounded(_ value: Bool) {
        guard value != isBackgrounded else { return }
        isBackgrounded = value
        if value { suspendLLMJobs() } else { resumeLLMJobs() }
    }

    private func suspendLLMJobs() {
        for (sessionID, activity) in activities {
            switch activity {
            case .summarizing, .downloadingModel:
                // Possibly mid-generation: the LLM park-gate guards only the
                // start of a generation, so an in-flight Metal submission can
                // be stopped only by cancelling the task.
                if let req = activeSummarizeRequest[sessionID] {
                    suspendedSummaries[sessionID] = req
                }
                activities[sessionID] = .pausedForRecording  // survive finishJob
                tasks[sessionID]?.cancel()
            default:
                // .retranscribing (ASR) / .importing / queued: GPU-free now,
                // and their later generation parks at the LLM gate.
                break
            }
        }
    }

    private func resumeLLMJobs() {
        let resumes = suspendedSummaries
        suspendedSummaries.removeAll()
        for (sessionID, req) in resumes {
            // Await the cancelled task's full teardown before restarting: a
            // fast background→foreground could otherwise let the old job's
            // finishJob clobber the fresh one (clearing its activity/task).
            let oldTask = tasks[sessionID]
            Task { [weak self] in
                await oldTask?.value
                guard let self, !self.isBackgrounded else { return }
                // Clear the held activity so the restart's isBusy guard passes,
                // then re-run from scratch (the partial summary was never saved).
                if self.activities[sessionID] == .pausedForRecording {
                    self.activities[sessionID] = nil
                }
                guard !self.isBusy(sessionID) else { return }
                self.summarize(
                    sessionID: sessionID, style: req.style, length: req.length,
                    allowDownload: req.allowDownload,
                    suggestVocabulary: req.suggestVocabulary)
            }
        }
    }

    /// The user-facing switch for all LLM work (same key as Settings).
    private var llmEnabled: Bool {
        UserDefaults.standard.object(forKey: "llm.enabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "llm.enabled")
    }

    /// Summarize a saved session. `suggestVocabulary` rides along after a
    /// fresh recording: suggestions land in the Vocabulary inbox (badged),
    /// not in transient view state, so they survive navigation.
    func summarize(
        sessionID: UUID,
        style: SummaryStyle,
        length: SummaryLength,
        allowDownload: Bool = false,
        suggestVocabulary: Bool = false
    ) {
        guard !isBusy(sessionID),
              archive.sessions.contains(where: { $0.id == sessionID })
        else { return }
        errors[sessionID] = nil
        activeSummarizeRequest[sessionID] = SummarizeRequest(
            style: style, length: length, allowDownload: allowDownload,
            suggestVocabulary: suggestVocabulary)
        activities[sessionID] = .summarizing(done: 0, total: 0)
        beginGrace(sessionID, name: "summarize")
        tasks[sessionID] = Task {
            defer { finishJob(sessionID) }
            do {
                try await loadModel(sessionID: sessionID, allowDownload: allowDownload)
                activities[sessionID] = .summarizing(done: 0, total: 0)
                try await runSummarize(
                    sessionID: sessionID, style: style, length: length,
                    suggestVocabulary: suggestVocabulary)
            } catch is CancellationError {
                // User cancelled: no error row.
            } catch {
                errors[sessionID] = error.localizedDescription
            }
        }
    }

    /// Second-pass accuracy path: offline re-transcription of the saved
    /// audio replaces the transcript (speakers inherited by time overlap),
    /// then the normal summarize runs over the better text. Routes through
    /// the serial queue — only one ASR decode ever runs at a time.
    func retranscribeAndSummarize(
        sessionID: UUID,
        style: SummaryStyle,
        length: SummaryLength,
        allowDownload: Bool = false
    ) {
        enqueueRetranscribe(
            ids: [sessionID], style: style, length: length,
            allowDownload: allowDownload)
    }

    /// Queue re-transcribes (batch selection or a single session). Queued
    /// sessions show `.queuedRetranscribe`; one worker drains them in
    /// order. Busy or missing sessions are skipped.
    func enqueueRetranscribe(
        ids: [UUID],
        style: SummaryStyle,
        length: SummaryLength,
        allowDownload: Bool = false
    ) {
        guard !isRecording() else { return }
        for id in ids {
            guard !isBusy(id),
                  archive.sessions.contains(where: { $0.id == id })
            else { continue }
            errors[id] = nil
            activities[id] = .queuedRetranscribe
            retranscribeQueue.append(RetranscribeRequest(
                sessionID: id, style: style, length: length,
                allowDownload: allowDownload))
        }
        drainRetranscribeQueue()
    }

    private func drainRetranscribeQueue() {
        guard retranscribeWorker == nil, !retranscribeQueue.isEmpty,
              !pausedForRecording else { return }
        retranscribeWorker = Task {
            defer { retranscribeWorker = nil }
            while !retranscribeQueue.isEmpty, !Task.isCancelled {
                let request = retranscribeQueue.removeFirst()
                let sessionID = request.sessionID
                // Re-check per dequeue: cancelled while queued, deleted,
                // or a live recording started since enqueue.
                guard activities[sessionID] == .queuedRetranscribe,
                      !isRecording(),
                      archive.sessions.contains(where: { $0.id == sessionID })
                else {
                    activities[sessionID] = nil
                    continue
                }
                // Child task per job so cancel(id:) stops one session
                // without killing the rest of the queue.
                activeRetranscribeRequest[sessionID] = request
                let job = Task { await self.runRetranscribe(request) }
                tasks[sessionID] = job
                await job.value
                activeRetranscribeRequest[sessionID] = nil
            }
        }
    }

    private func runRetranscribe(_ request: RetranscribeRequest) async {
        let sessionID = request.sessionID
        guard let session = archive.sessions.first(where: { $0.id == sessionID })
        else {
            activities[sessionID] = nil
            return
        }
        activities[sessionID] = .retranscribing(.transcribing(0))
        beginGrace(sessionID, name: "retranscribe")
        defer { finishJob(sessionID) }
        do {
            // The summarize that follows needs the model; check its
            // gates BEFORE the expensive re-transcription, not after.
            guard llmEnabled else { throw JobError.aiDisabled }
            if !request.allowDownload, !LLMService.isDownloaded(model: ModelCatalog.current) {
                throw LLMServiceError.modelNotDownloaded
            }
            let retranscriber = SessionRetranscriber(
                llm: llm, translator: translator, hotwords: hotwords)
            let updated = try await retranscriber.retranscribe(session) { [weak self] phase in
                self?.retranscribeProgress(sessionID: sessionID, phase: phase)
            }
            // A cancel that landed at the very end must not clobber the
            // archive with a half-finished record.
            try Task.checkCancellation()
            archive.update(updated)
            // The transcript is archived; from here it's an LLM summarize that
            // backgrounding can cancel and restart on its own.
            activeSummarizeRequest[sessionID] = SummarizeRequest(
                style: request.style, length: request.length,
                allowDownload: request.allowDownload, suggestVocabulary: false)
            try await loadModel(sessionID: sessionID, allowDownload: request.allowDownload)
            activities[sessionID] = .summarizing(done: 0, total: 0)
            try await runSummarize(
                sessionID: sessionID, style: request.style, length: request.length,
                suggestVocabulary: false)
        } catch is CancellationError {
            // User cancelled: no error row.
        } catch {
            errors[sessionID] = error.localizedDescription
        }
    }

    /// Import an audio file as a background job. A placeholder record
    /// lands in the archive immediately (the Sessions row carries the
    /// progress bar); completion fills it in and re-seats it in date
    /// order. Cancel deletes the placeholder; failure keeps it with the
    /// error so the row can explain itself.
    func startImport(
        url: URL,
        direction: LanguagePair,
        speakerCount: Int,
        engine: String
    ) {
        guard !isRecording() else { return }
        let sessionID = UUID()
        var placeholder = SessionRecord(
            mode: .captions, startedAt: .now, endedAt: .now, entries: [])
        placeholder.id = sessionID
        placeholder.titleText = url.deletingPathExtension().lastPathComponent
        placeholder.importing = true
        archive.add(placeholder)
        activities[sessionID] = .importing(.transcribing(0))
        beginGrace(sessionID, name: "import")
        tasks[sessionID] = Task {
            defer { finishJob(sessionID) }
            do {
                let importer = FileImportEngine(
                    translator: translator, voiceprint: voiceprint,
                    llm: llm, hotwords: hotwords)
                var record = try await importer.importAudio(
                    url: url,
                    sessionID: sessionID,
                    direction: direction,
                    speakerCount: speakerCount,
                    engine: engine
                ) { [weak self] phase in
                    self?.importProgress(sessionID: sessionID, phase: phase)
                }
                record.unseen = true
                archive.update(record)
                lastCompleted = Completion(id: sessionID, at: .now)
            } catch is CancellationError {
                hotwords.discardSuggestions(forSession: sessionID)
                archive.delete(id: sessionID)
            } catch {
                errors[sessionID] = error.localizedDescription
            }
        }
    }

    // MARK: Progress + teardown plumbing

    /// Quantize to whole percents before comparing: every `activities`
    /// write invalidates all observing views, so equal-looking ticks must
    /// be dropped.
    private static func percent(_ fraction: Double) -> Double {
        (fraction * 100).rounded() / 100
    }

    private func importProgress(sessionID: UUID, phase: FileImportEngine.Phase) {
        guard activities[sessionID] != nil else { return }
        switch phase {
        case .transcribing(let f):
            setProgress(sessionID, .importing(.transcribing(Self.percent(f))),
                        phaseKey: "import.asr", fraction: f)
        case .fetchingSpeakerModel(let f):
            setProgress(sessionID, .importing(.fetchingSpeakerModel(Self.percent(f))),
                        phaseKey: "import.fetch", fraction: f)
        case .identifyingSpeakers(let f):
            setProgress(sessionID, .importing(.identifyingSpeakers(Self.percent(f))),
                        phaseKey: "import.diarize", fraction: f)
        case .translating(let f):
            setProgress(sessionID, .importing(.translating(Self.percent(f))),
                        phaseKey: "import.translate", fraction: f)
        }
    }

    private func retranscribeProgress(
        sessionID: UUID, phase: SessionRetranscriber.Phase
    ) {
        guard activities[sessionID] != nil else { return }
        switch phase {
        case .transcribing(let f):
            setProgress(sessionID, .retranscribing(.transcribing(Self.percent(f))),
                        phaseKey: "re.asr", fraction: f)
        case .translating(let f):
            setProgress(sessionID, .retranscribing(.translating(Self.percent(f))),
                        phaseKey: "re.translate", fraction: f)
        }
    }

    /// Single write path: dedupe equal activities, feed the ETA every raw
    /// tick, publish `remaining` only on whole-second changes.
    private func setProgress(
        _ sessionID: UUID, _ activity: Activity, phaseKey: String, fraction: Double
    ) {
        if activities[sessionID] != activity { activities[sessionID] = activity }
        if phaseKeys[sessionID] != phaseKey {
            // New phase, new 0…1 scale: the previous rate means nothing.
            phaseKeys[sessionID] = phaseKey
            etas[sessionID] = ProcessingETA()
            if remaining[sessionID] != nil { remaining[sessionID] = nil }
        }
        var eta = etas[sessionID] ?? ProcessingETA()
        eta.update(fraction: fraction)
        etas[sessionID] = eta
        let old = remaining[sessionID]
        if let new = eta.remaining {
            if old == nil || abs(old! - new) >= 1 { remaining[sessionID] = new }
        } else if old != nil {
            remaining[sessionID] = nil
        }
    }

    private func beginGrace(_ sessionID: UUID, name: String) {
        let grace = BackgroundTaskGrace()
        grace.begin(name: name)
        graces[sessionID] = grace
    }

    private func finishJob(_ sessionID: UUID) {
        if activities[sessionID] != .pausedForRecording {
            activities[sessionID] = nil
        }
        // A background-suspended job has already copied this into
        // `suspendedSummaries`, so clearing here is safe.
        activeSummarizeRequest[sessionID] = nil
        remaining[sessionID] = nil
        etas[sessionID] = nil
        phaseKeys[sessionID] = nil
        tasks[sessionID] = nil
        graces[sessionID]?.end()
        graces[sessionID] = nil
    }

    /// Respect the gates, then make the model ready. With consent the load
    /// may download, reporting progress through the session's activity.
    private func loadModel(sessionID: UUID, allowDownload: Bool) async throws {
        guard llmEnabled else { throw JobError.aiDisabled }
        if allowDownload {
            try await llm.load { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.activities[sessionID] != nil else { return }
                    self.activities[sessionID] = .downloadingModel(fraction)
                }
            }
        } else {
            try await llm.load(policy: .requireDownloaded)
        }
    }

    private func runSummarize(
        sessionID: UUID,
        style: SummaryStyle,
        length: SummaryLength,
        suggestVocabulary: Bool
    ) async throws {
        // Re-fetch after the (possibly minutes-long) model download: edits
        // made meanwhile must not be clobbered by a stale snapshot, and a
        // deleted session simply ends the job.
        guard let session = archive.sessions.first(where: { $0.id == sessionID })
        else { return }
        let engine = SummaryEngine(llm: llm, matcher: hotwords.matcher)
        // Hygiene first: retro-apply hotword fixes and catch up refinement
        // the live session dropped, so the notes map over the cleanest text
        // we can produce.
        let hygiene = await engine.hygienePass(session)
        let cleaned = hygiene.record
        if hygiene.changed { archive.update(cleaned) }
        let result = try await engine.summarize(
            cleaned, style: style, length: length,
            in: SummaryEngine.summaryLanguage(for: cleaned)
        ) { [weak self] done, total in
            guard let self, self.activities[sessionID] != nil else { return }
            self.activities[sessionID] = .summarizing(done: done, total: total)
        }
        var updated = cleaned
        updated.summary = result.summary
        updated.summaryEdited = nil
        updated.summaryStyle = style.rawValue
        updated.summaryLength = length.rawValue
        updated.chunkNotes = result.notes
        // Full coverage now: future re-summarize is reduce-only.
        updated.liveNotesEndEntryID = cleaned.entries.last?.id
        archive.update(updated)
        // Title the session while the model is hot. User renames are never
        // overwritten; failure keeps the fallback chain.
        if updated.titleEdited != true,
           let title = await generateTitle(for: updated) {
            updated.titleText = title
            archive.update(updated)
        }
        if suggestVocabulary {
            await enqueueVocabularySuggestions(for: updated)
        }
    }

    /// One tiny generation right after summarize: list-row title from the
    /// note headlines (or the transcript opening for unmapped sessions).
    private func generateTitle(for record: SessionRecord) async -> String? {
        let builder = PromptBuilder()
        let context: String
        if let notes = record.chunkNotes, !notes.isEmpty {
            context = notes.prefix(6).map(\.headline).joined(separator: "\n")
        } else {
            context = String(
                record.entries.map(\.sourceText).joined(separator: "\n").prefix(600))
        }
        let prompt = builder.titlePrompt(
            context: context, in: SummaryEngine.summaryLanguage(for: record))
        guard let raw = try? await llm.generate(
            system: prompt.system, user: prompt.user, maxTokens: 24, temperature: 0.3)
        else { return nil }
        return builder.parseTitle(raw)
    }

    /// Post-summarize vocabulary mining for fresh recordings. Best-effort;
    /// results go to the Vocabulary inbox where they keep working even if
    /// the user has navigated away.
    private func enqueueVocabularySuggestions(for record: SessionRecord) async {
        let builder = PromptBuilder()
        let transcript = record.plainTranscript()
        let budget = PromptBuilder.suggestionBudget(transcriptLength: transcript.count)
        let direction = record.entries.last?.direction
        let prompt = builder.hotwordSuggestionPrompt(
            transcript: transcript,
            sourceLanguage: direction?.source,
            targetLanguage: direction?.target,
            limit: budget)
        guard let raw = try? await llm.generate(
            system: prompt.system, user: prompt.user, maxTokens: 200) else { return }
        let suggestions = builder.parseHotwordSuggestions(
            raw, limit: budget, targetLanguage: direction?.target)
            .filter { !hotwords.isKnown($0.term) }
        hotwords.enqueueSuggestions(
            suggestions, sessionID: record.id, sessionTitle: record.title)
    }
}
