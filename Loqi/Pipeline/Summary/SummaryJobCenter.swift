import Foundation
import Observation
import os
#if os(iOS)
import UIKit
#endif

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
        /// Scene left the foreground; Metal-backed work resumes on active.
        case pausedForBackground
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
    /// Retranscribe workers canceled by backgrounding. Foreground resume waits
    /// for their cleanup before reusing the same activity/task slots.
    @ObservationIgnored private var backgroundPausedRetranscribeTasks: [UUID: Task<Void, Never>] = [:]
    /// Decoded segments awaiting a batched checkpoint write (see
    /// `retranscribeCheckpointBatch`).
    @ObservationIgnored private var retranscribeSegmentBuffers: [UUID: [SessionRecord.ImportCheckpoint.Segment]] = [:]
    /// One-at-a-time gate every heavy post-hoc job acquires before touching
    /// the GPU/ASR. Re-summary fired during a file import used to run both
    /// at once and the OS killed the process; now the second job queues.
    @ObservationIgnored private let heavyGate = SerialGate()

    private struct RetranscribeRequest {
        enum Kind {
            case manual
            case newRecording(
                backend: OfflineTranscriber.Backend?,
                speakerCount: Int?,
                suggestVocabulary: Bool)
        }

        let sessionID: UUID
        let style: SummaryStyle
        let length: SummaryLength
        let allowDownload: Bool
        let kind: Kind
    }

    private struct SummarizeRequest {
        let style: SummaryStyle
        let length: SummaryLength
        let allowDownload: Bool
        let suggestVocabulary: Bool
    }

    private let logger = Logger(
        subsystem: "com.kunzhipeng.loqi", category: "summaryJobs")

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
        #if os(iOS)
        // The accuracy pass defers to the charger; hear about plug-ins.
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resumePendingPostProcesses()
            }
        }
        #endif
    }

    /// True when the device is on external power — the only time the
    /// automatic accuracy pass is allowed to burn 20-30 minutes of CPU.
    /// `.unknown` fails CLOSED (defer): a cold launch reads .unknown
    /// before the first battery sample, and running the hot pass on
    /// battery is the exact failure charge-gating exists to prevent. A
    /// deferral never strands the pass — the battery observer re-sweeps
    /// the moment the state becomes known. (Simulator reports .unknown;
    /// manual Re-transcribe stays available there.) Pure mapping split
    /// for testing.
    static func isPluggedIn() -> Bool {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        return pluggedIn(UIDevice.current.batteryState)
        #else
        return true
        #endif
    }

    #if os(iOS)
    nonisolated static func pluggedIn(_ state: UIDevice.BatteryState) -> Bool {
        state == .charging || state == .full
    }
    #endif

    /// Await any in-flight heavy job unwinding. The live pipeline calls this
    /// right after `yieldToRecording()` so live capture never shares the GPU
    /// with a still-tearing-down import or summarize.
    func waitForHeavyIdle() async { await heavyGate.waitUntilIdle() }

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
        suspendedSummaries[sessionID] = nil
        backgroundPausedRetranscribeTasks[sessionID] = nil
        // An explicit cancel must not resurrect the summary — or the
        // deferred accuracy pass — at the next launch/charge sweep.
        clearPendingSummary(sessionID)
        clearPendingPostProcess(sessionID)
        if let index = retranscribeQueue.firstIndex(where: { $0.sessionID == sessionID }) {
            retranscribeQueue.remove(at: index)
            activities[sessionID] = nil
            return
        }
        // A held or already-unwound import has no live task left to
        // observe this cancel — the placeholder + checkpoint would
        // survive and the next resume sweep would restart the job the
        // user just cancelled. Tear it down here, mirroring the import
        // task's own user-cancel path.
        if Self.isHeldActivity(activities[sessionID]) || tasks[sessionID] == nil,
           archive.sessions.first(where: { $0.id == sessionID })?.importing == true {
            hotwords.discardSuggestions(forSession: sessionID)
            archive.delete(id: sessionID)
            activities[sessionID] = nil
            return
        }
        if activities[sessionID] == .pausedForBackground {
            activities[sessionID] = nil
            return
        }
        tasks[sessionID]?.cancel()
    }

    /// Cancel heavy background work so a live recording gets full resources.
    /// Re-transcription requests are re-enqueued (restart from scratch after
    /// recording); imports checkpoint their progress as they go, so they
    /// just pause and pick back up via `resumeUnfinishedImports()`.
    /// Synchronously re-enqueues BEFORE cancelling tasks so a very short
    /// recording can't race the propagation.
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
            case .summarizing, .downloadingModel:
                // A live summary would hold the 2B model the recording needs
                // freed for the 0.8B tier. Suspend and restart after, exactly
                // like backgrounding does (the partial summary was never saved).
                guard let req = activeSummarizeRequest[sessionID] else { break }
                suspendedSummaries[sessionID] = req
                activities[sessionID] = .pausedForRecording
                tasks[sessionID]?.cancel()
            case .importing:
                // Marking pausedForRecording BEFORE cancelling tells the
                // import task's CancellationError handler this was a yield,
                // not a user cancel — it keeps the placeholder + checkpoint
                // instead of deleting them.
                activities[sessionID] = .pausedForRecording
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
                // Imports resume fresh via resumeUnfinishedImports() below;
                // retranscribes re-queue; summaries restart via
                // resumeLLMJobs, which clears their held activity first.
                if archive.sessions.first(where: { $0.id == sessionID })?.importing == true {
                    activities[sessionID] = nil
                } else if suspendedSummaries[sessionID] != nil {
                    activities[sessionID] = .pausedForBackground
                } else {
                    activities[sessionID] = .queuedRetranscribe
                }
            }
        }
        if Self.shouldResumeLLMJobsAfterRecording(isBackgrounded: isBackgrounded) {
            resumeLLMJobs()
        }
        drainRetranscribeQueue()
        resumeUnfinishedImports()
        // A recording blocks the sweeps; on-charger pending passes can go now.
        resumePendingPostProcesses()
    }

    /// Scene moved to/from the background. Metal-backed work can't run there:
    /// iOS aborts the process instead of throwing an error. Summary
    /// generation, second-pass re-transcribe, and file import all restart on
    /// foreground; imports resume from their checkpoint instead of scratch.
    func setBackgrounded(_ value: Bool) {
        guard value != isBackgrounded else { return }
        isBackgrounded = value
        if value { suspendBackgroundUnsafeJobs() } else { resumeBackgroundJobs() }
    }

    nonisolated static func shouldSuspendForBackground(_ activity: Activity) -> Bool {
        switch activity {
        case .downloadingModel, .summarizing, .retranscribing, .importing:
            true
        default:
            false
        }
    }

    /// A job that is actively USING (or about to use) the LLM. While one
    /// runs in the foreground, a memory warning sheds the MLX cache instead
    /// of unloading the weights — a full unload mid-job just forces an
    /// immediate self-heal reload, which costs more memory churn (and GPU
    /// time) than it frees. Imports are deliberately excluded EXCEPT their
    /// transcript-cleanup phase, which actively generates on the 230M; the
    /// decode/translate phases are ASR/translation only (the auto-summary
    /// afterwards is its own job), so under memory pressure the resident
    /// weights are pure reclaimable headroom there.
    var hasRunningLLMJob: Bool {
        activities.values.contains(where: Self.usesLLM)
    }

    nonisolated static func usesLLM(_ activity: Activity) -> Bool {
        switch activity {
        case .downloadingModel, .summarizing, .retranscribing: true
        case .importing(.cleaningUpTranscript): true
        default: false
        }
    }

    nonisolated static func shouldResumeLLMJobsAfterRecording(isBackgrounded: Bool) -> Bool {
        !isBackgrounded
    }

    /// A manual summarize whose style AND length match the existing
    /// summary is the user asking to REDO it — cached notes must not
    /// short-circuit the map. (A style/length change stays reduce-only;
    /// first-time summaries have no summary to match.)
    nonisolated static func isRedoRequest(
        _ record: SessionRecord?, style: SummaryStyle, length: SummaryLength
    ) -> Bool {
        guard let record, record.summary?.isEmpty == false else { return false }
        return record.summaryStyle == style.rawValue
            && record.summaryLength == length.rawValue
    }

    /// Drop the map coverage so the next summarize regenerates every
    /// chunk note instead of reducing over the cached ones.
    private func clearMapCoverage(_ sessionID: UUID) {
        guard var record = archive.sessions.first(where: { $0.id == sessionID })
        else { return }
        record.chunkNotes = nil
        record.liveNotesEndEntryID = nil
        archive.update(record)
    }

    /// Notes covering a resolvable prefix of the transcript — what
    /// `SummaryEngine.uncoveredEntries` can actually resume from, asked
    /// of the same function so the two can never diverge (this also means
    /// a checkpoint whose stub rollback discards everything counts as
    /// unusable, and hygiene correctly runs before the full remap). Live
    /// notes from a recording have the same shape; a resume can't tell
    /// them apart, so it skips hygiene for those too (a quality trade,
    /// not a correctness one).
    nonisolated static func hasUsableMapCheckpoint(_ record: SessionRecord) -> Bool {
        !SummaryEngine.uncoveredEntries(of: record).cachedNotes.isEmpty
    }

    private static func isHeldActivity(_ activity: Activity?) -> Bool {
        activity == .pausedForRecording || activity == .pausedForBackground
    }

    private func suspendBackgroundUnsafeJobs() {
        for (sessionID, activity) in activities {
            guard Self.shouldSuspendForBackground(activity) else { continue }
            logger.info("bg suspend: \(sessionID, privacy: .public) activity=\(String(describing: activity), privacy: .public)")
            if case .summarizing = activity,
               let req = activeSummarizeRequest[sessionID] {
                suspendedSummaries[sessionID] = req
            } else if case .downloadingModel = activity,
                      let req = activeSummarizeRequest[sessionID] {
                suspendedSummaries[sessionID] = req
            } else if case .retranscribing = activity,
                      let req = activeRetranscribeRequest[sessionID],
                      !retranscribeQueue.contains(where: { $0.sessionID == sessionID }) {
                retranscribeQueue.insert(req, at: 0)
                backgroundPausedRetranscribeTasks[sessionID] = retranscribeWorker ?? tasks[sessionID]
            }
            activities[sessionID] = .pausedForBackground
            tasks[sessionID]?.cancel()
        }
        retranscribeWorker?.cancel()
        retranscribeWorker = nil
    }

    private func resumeBackgroundJobs() {
        resumeLLMJobs()
        let pausedRetranscribes = activities.compactMap { sessionID, activity -> UUID? in
            guard activity == .pausedForBackground,
                  retranscribeQueue.contains(where: { $0.sessionID == sessionID })
            else { return nil }
            return sessionID
        }
        for sessionID in pausedRetranscribes {
            let oldTask = backgroundPausedRetranscribeTasks.removeValue(forKey: sessionID)
            Task { [weak self] in
                await oldTask?.value
                guard let self,
                      !self.isBackgrounded,
                      self.activities[sessionID] == .pausedForBackground,
                      self.retranscribeQueue.contains(where: { $0.sessionID == sessionID })
                else { return }
                self.activities[sessionID] = .queuedRetranscribe
                self.drainRetranscribeQueue()
            }
        }
        // Imports resume fresh via resumeUnfinishedImports() below (same
        // as the recording-preemption path); clear the held badge first so
        // a checkpoint-less one (killed before onAudioReady) doesn't show
        // "paused" forever instead of getting swept on next launch.
        for (sessionID, activity) in activities
        where activity == .pausedForBackground
            && archive.sessions.first(where: { $0.id == sessionID })?.importing == true {
            activities[sessionID] = nil
        }
        resumeUnfinishedImports()
        // Catch-all sweep for summaries whose job died without a held
        // activity (e.g. cancelled by a memory-warning unload).
        resumeUnfinishedSummaries()
        // Accuracy passes deferred to the charger, or orphaned by a kill.
        resumePendingPostProcesses()
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
                // Clear the held activity so the restart's isBusy guard passes;
                // the restart resumes from the chunk-note checkpoint.
                if self.activities[sessionID] == .pausedForBackground {
                    self.activities[sessionID] = nil
                }
                guard !self.isBusy(sessionID) else { return }
                self.logger.info("fg resume: restarting summarize \(sessionID, privacy: .public)")
                self.summarize(
                    sessionID: sessionID, style: req.style, length: req.length,
                    allowDownload: req.allowDownload,
                    suggestVocabulary: req.suggestVocabulary,
                    isResume: true)
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
        suggestVocabulary: Bool = false,
        isResume: Bool = false
    ) {
        guard !isRecording(), !isBusy(sessionID),
              archive.sessions.contains(where: { $0.id == sessionID })
        else { return }
        errors[sessionID] = nil
        markPendingSummary(
            sessionID: sessionID, style: style, length: length,
            allowDownload: allowDownload)
        activeSummarizeRequest[sessionID] = SummarizeRequest(
            style: style, length: length, allowDownload: allowDownload,
            suggestVocabulary: suggestVocabulary)
        activities[sessionID] = .summarizing(done: 0, total: 0)
        beginGrace(sessionID, name: "summarize")
        tasks[sessionID] = Task {
            defer { finishJob(sessionID) }
            do { try await heavyGate.acquire() } catch { return }
            defer { heavyGate.release() }
            do {
                try await loadModel(sessionID: sessionID, allowDownload: allowDownload)
                activities[sessionID] = .summarizing(done: 0, total: 0)
                // An explicit re-run with the SAME style and length is a
                // redo request: the user wants a better summary, not the
                // cached one re-rendered. Clear coverage so the map phase
                // regenerates the notes. A style/length change keeps the
                // cheap reduce-only path below.
                if !isResume, !suggestVocabulary,
                   Self.isRedoRequest(
                       archive.sessions.first(where: { $0.id == sessionID }),
                       style: style, length: length) {
                    logger.info("redo request: clearing map coverage for \(sessionID, privacy: .public)")
                    clearMapCoverage(sessionID)
                } else if !suggestVocabulary,
                   try await renderCachedSummaryIfPossible(
                    sessionID: sessionID, style: style, length: length) {
                    logger.info("summary rendered from cached notes (reduce-only)")
                    clearPendingSummary(sessionID)
                    return
                }
                try await runSummarize(
                    sessionID: sessionID, style: style, length: length,
                    suggestVocabulary: suggestVocabulary, isResume: isResume)
                clearPendingSummary(sessionID)
            } catch is CancellationError {
                // Suspended (recording/background) or user-cancelled; a
                // suspend resumes in-memory and an explicit cancel clears
                // the pending marker itself — keeping it here is what lets
                // a crashed/killed summary restart at next launch.
                requeueIfSilentlyCancelled(sessionID)
            } catch {
                errors[sessionID] = error.localizedDescription
                // A failed summary must not auto-retry every launch.
                clearPendingSummary(sessionID)
            }
        }
    }

    /// A `CancellationError` with the activity neither held for a
    /// recording/background resume nor explicitly cancelled (which clears
    /// the pending marker first) came from elsewhere — e.g. a
    /// memory-warning `unload()` cancelling the model load under the job.
    /// Without this the job dies silently: no error row, no retry until
    /// the next cold launch. Re-issue once teardown finishes.
    private func requeueIfSilentlyCancelled(_ sessionID: UUID) {
        guard !Self.isHeldActivity(activities[sessionID]),
              archive.sessions.first(where: { $0.id == sessionID })?.pendingSummary != nil
        else { return }
        // Scheduled, not called: the job's deferred finishJob must clear
        // the activity first or summarize()'s isBusy guard rejects the
        // restart. resumeUnfinishedSummaries re-checks everything anyway.
        Task { self.resumeUnfinishedSummaries() }
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

    /// Retry speaker separation for a session whose diarization failed
    /// (`speakerSeparationFailed`). Diarizes the saved audio and writes the
    /// slots back, leaving the transcript text, summary, and notes intact
    /// (entry IDs don't change). Tapping Retry is implied download consent —
    /// the offline diarizer is tens of MB, not the multi-GB LLM.
    func retryDiarization(sessionID: UUID) {
        guard !isRecording(), !isBusy(sessionID),
              let session = archive.sessions.first(where: { $0.id == sessionID }),
              let fileName = session.audioFileName
        else { return }
        let url = SessionArchive.recordingURL(fileName: fileName)
        let speakerCount = session.recordingSpeakerCount ?? -1
        guard FileManager.default.fileExists(atPath: url.path),
              VoiceprintService.separationEnabled(forPickerValue: speakerCount)
        else { return }

        errors[sessionID] = nil
        activities[sessionID] = .retranscribing(.identifyingSpeakers(0))
        beginGrace(sessionID, name: "retry-diarize")
        tasks[sessionID] = Task {
            defer { finishJob(sessionID) }
            do { try await heavyGate.acquire() } catch { return }
            defer { heavyGate.release() }
            do {
                let segments = try await voiceprint.diarizeFile(
                    url: url, speakerCount: speakerCount
                ) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.activities[sessionID] != nil else { return }
                        switch progress {
                        case .download(let fraction):
                            self.activities[sessionID] = .downloadingModel(fraction)
                        case .analysis(let fraction):
                            self.retranscribeProgress(
                                sessionID: sessionID, phase: .identifyingSpeakers(fraction))
                        }
                    }
                }
                try Task.checkCancellation()
                guard var record = archive.sessions.first(where: { $0.id == sessionID })
                else { return }
                SessionRetranscriber.applyDiarizationSegments(segments, to: &record)
                record.speakerSeparationFailed = nil
                archive.update(record)
            } catch is CancellationError {
                // User cancelled: no error row.
            } catch {
                errors[sessionID] = error.localizedDescription
            }
        }
    }

    /// Fresh-recording auto polish. Uses downloaded post-process models
    /// only; when none apply, it falls straight back to normal summarize.
    func postProcessAndSummarizeNewSession(
        sessionID: UUID,
        style: SummaryStyle,
        length: SummaryLength,
        allowDownload: Bool = false,
        suggestVocabulary: Bool = false
    ) {
        guard !isRecording(),
              !isBusy(sessionID),
              let session = archive.sessions.first(where: { $0.id == sessionID })
        else { return }

        let backend = OfflineTranscriber.postProcessBackend(
            sourceLanguages: Set(session.entries.map(\.direction.source)),
            senseVoiceInstalled: SenseVoiceModelStore.isInstalled,
            qwen3Installed: Qwen3ASRModelStore.isInstalled,
            dolphinInstalled: DolphinModelStore.isInstalled)
        let speakerCount: Int?
        if VoiceprintService.isOfflineDiarizerDownloaded,
           let count = session.recordingSpeakerCount,
           VoiceprintService.separationEnabled(forPickerValue: count) {
            speakerCount = count
        } else {
            speakerCount = nil
        }

        guard (backend != nil || speakerCount != nil),
              SessionRetranscriber.canRetranscribe(session)
        else {
            // Nothing heavy applies (also the swept-marker case after the
            // user removed the models) — consume any pending marker so the
            // charge sweep stops re-visiting this session.
            clearPendingPostProcess(sessionID)
            summarize(
                sessionID: sessionID, style: style, length: length,
                allowDownload: allowDownload, suggestVocabulary: suggestVocabulary)
            return
        }

        // Persist the intent BEFORE running: a kill mid-pass (or the
        // deferral below) restarts it at the next launch/charge sweep, and
        // the retranscribe checkpoint makes that restart cheap.
        markPendingPostProcess(
            sessionID: sessionID, style: style, length: length,
            suggestVocabulary: suggestVocabulary)

        // On battery, the accuracy pass would cost 20-30 hot minutes in
        // the user's hand — summarize the live transcript now and run the
        // pass when the charger connects. Vocabulary suggestions wait for
        // the accuracy pass (better text, better suggestions).
        guard Self.isPluggedIn() else {
            logger.info("accuracy pass deferred to charger: \(sessionID, privacy: .public)")
            summarize(
                sessionID: sessionID, style: style, length: length,
                allowDownload: allowDownload, suggestVocabulary: false)
            return
        }

        errors[sessionID] = nil
        activities[sessionID] = .queuedRetranscribe
        retranscribeQueue.append(RetranscribeRequest(
            sessionID: sessionID, style: style, length: length,
            allowDownload: allowDownload,
            kind: .newRecording(
                backend: backend,
                speakerCount: speakerCount,
                suggestVocabulary: suggestVocabulary)))
        drainRetranscribeQueue()
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
        guard !isRecording() else {
            logger.info("retranscribe rejected: recording in progress")
            return
        }
        for id in ids {
            guard archive.sessions.contains(where: { $0.id == id }) else { continue }
            guard !isBusy(id) else {
                // Silent before — "the button does nothing" reports were
                // undiagnosable without knowing what holds the session.
                logger.info("retranscribe rejected: \(id, privacy: .public) busy with \(String(describing: self.activities[id]), privacy: .public)")
                continue
            }
            errors[id] = nil
            activities[id] = .queuedRetranscribe
            retranscribeQueue.append(RetranscribeRequest(
                sessionID: id, style: style, length: length,
                allowDownload: allowDownload, kind: .manual))
        }
        drainRetranscribeQueue()
    }

    private func drainRetranscribeQueue() {
        guard !retranscribeQueue.isEmpty else { return }
        guard retranscribeWorker == nil else {
            logger.info("retranscribe drain: worker already running")
            return
        }
        guard !pausedForRecording, !isBackgrounded else {
            logger.info("retranscribe drain held: pausedForRecording=\(self.pausedForRecording) backgrounded=\(self.isBackgrounded)")
            return
        }
        retranscribeWorker = Task {
            defer { retranscribeWorker = nil }
            while !retranscribeQueue.isEmpty, !Task.isCancelled, !isBackgrounded {
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
        do { try await heavyGate.acquire() } catch { return }
        defer { heavyGate.release() }
        do {
            // The summarize that follows needs the model; check its
            // gates BEFORE the expensive re-transcription, not after.
            guard llmEnabled else { throw JobError.aiDisabled }
            if !request.allowDownload, !LLMService.isDownloaded(model: ModelCatalog.current) {
                throw LLMServiceError.modelNotDownloaded
            }
            let retranscriber = SessionRetranscriber(
                llm: llm, translator: translator, hotwords: hotwords,
                llmCleanupEnabled: llmEnabled)
            let updated: SessionRecord
            let suggestVocabulary: Bool
            switch request.kind {
            case .manual:
                let backend = OfflineTranscriber.currentBackend(
                    sourceLanguages: Set(session.entries.map(\.direction.source)))
                updated = try await retranscriber.retranscribe(
                    session,
                    backend: backend,
                    alreadyDecoded: seedRetranscribeCheckpoint(
                        sessionID: sessionID, backend: backend),
                    onSegmentComplete: retranscribeSegmentRecorder(
                        sessionID: sessionID, backend: backend)
                ) { [weak self] phase in
                    self?.retranscribeProgress(sessionID: sessionID, phase: phase)
                }
                suggestVocabulary = false
            case .newRecording(let backend, let speakerCount, let suggest):
                updated = try await retranscriber.postProcessNewRecording(
                    session,
                    backend: backend,
                    speakerCount: speakerCount,
                    voiceprint: voiceprint,
                    alreadyDecoded: backend.map {
                        seedRetranscribeCheckpoint(sessionID: sessionID, backend: $0)
                    } ?? [],
                    onSegmentComplete: backend.flatMap {
                        retranscribeSegmentRecorder(sessionID: sessionID, backend: $0)
                    }
                ) { [weak self] phase in
                    self?.retranscribeProgress(sessionID: sessionID, phase: phase)
                }
                suggestVocabulary = suggest
            }
            // A cancel that landed at the very end must not clobber the
            // archive with a half-finished record.
            try Task.checkCancellation()
            archive.update(updated)
            // Any completed accuracy pass (auto or manual) satisfies a
            // pending marker — the charge sweep must not run it again.
            clearPendingPostProcess(sessionID)
            // The transcript is archived; from here it's an LLM summarize that
            // backgrounding can cancel and restart on its own — persist that
            // intent so even a process kill restarts it at next launch.
            markPendingSummary(
                sessionID: sessionID, style: request.style, length: request.length,
                allowDownload: request.allowDownload)
            activeSummarizeRequest[sessionID] = SummarizeRequest(
                style: request.style, length: request.length,
                allowDownload: request.allowDownload,
                suggestVocabulary: suggestVocabulary)
            try await loadModel(sessionID: sessionID, allowDownload: request.allowDownload)
            activities[sessionID] = .summarizing(done: 0, total: 0)
            try await runSummarize(
                sessionID: sessionID, style: request.style, length: request.length,
                suggestVocabulary: suggestVocabulary)
            clearPendingSummary(sessionID)
        } catch is CancellationError {
            // Suspended or user-cancelled; see summarize()'s handling.
            requeueIfSilentlyCancelled(sessionID)
        } catch {
            errors[sessionID] = error.localizedDescription
            clearPendingSummary(sessionID)
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
        engine: String,
        sensitivity: MicSensitivity
    ) {
        guard !isRecording() else { return }
        let sessionID = UUID()
        var placeholder = SessionRecord(
            mode: .captions, startedAt: .now, endedAt: .now, entries: [])
        placeholder.id = sessionID
        placeholder.titleText = url.deletingPathExtension().lastPathComponent
        placeholder.importing = true
        archive.add(placeholder)
        runImportJob(sessionID: sessionID) { [weak self] onPhase in
            guard let self else { throw CancellationError() }
            await self.llm.setModel(ModelCatalog.summaryModel)
            let importer = FileImportEngine(
                translator: self.translator, voiceprint: self.voiceprint,
                llm: self.llm, hotwords: self.hotwords,
                llmCleanupEnabled: self.llmEnabled)
            return try await importer.importAudio(
                url: url,
                sessionID: sessionID,
                direction: direction,
                speakerCount: speakerCount,
                engine: engine,
                sensitivity: sensitivity,
                onAudioReady: { [weak self] recordingName, duration, recordedAt in
                    self?.recordImportAudioReady(
                        sessionID: sessionID, recordingName: recordingName,
                        duration: duration, recordedAt: recordedAt,
                        direction: direction, speakerCount: speakerCount,
                        engine: engine, sensitivity: sensitivity)
                },
                onSegmentComplete: { [weak self] segment in
                    self?.recordImportSegment(sessionID: sessionID, segment: segment)
                },
                onPhase: onPhase)
        }
    }

    /// Resume a previously-checkpointed import — a killed/relaunched
    /// process, a background kill, or one just paused by
    /// `yieldToRecording()`. Only called for sessions with a checkpoint and
    /// no already-running task; see `resumeUnfinishedImports()`.
    private func resumeImport(
        sessionID: UUID, checkpoint: SessionRecord.ImportCheckpoint, audioFileName: String
    ) {
        runImportJob(sessionID: sessionID) { [weak self] onPhase in
            guard let self else { throw CancellationError() }
            await self.llm.setModel(ModelCatalog.summaryModel)
            let importer = FileImportEngine(
                translator: self.translator, voiceprint: self.voiceprint,
                llm: self.llm, hotwords: self.hotwords,
                llmCleanupEnabled: self.llmEnabled)
            return try await importer.resumeImport(
                checkpoint: checkpoint,
                sessionID: sessionID,
                audioFileName: audioFileName,
                onSegmentComplete: { [weak self] segment in
                    self?.recordImportSegment(sessionID: sessionID, segment: segment)
                },
                onPhase: onPhase)
        }
    }

    /// Scans for imports interrupted mid-flight and restarts each from its
    /// checkpoint. Safe to call opportunistically — already-running imports
    /// are skipped via the `tasks` check. Called after a cold launch
    /// (`SessionArchive.loadIfNeeded()` keeps resumable records instead of
    /// sweeping them) and after a recording that yielded one ends.
    func resumeUnfinishedImports() {
        // The background guard lives HERE so every caller is safe:
        // resumeAfterRecording can fire while still backgrounded (recording
        // stopped from the lock screen), and Metal-backed ASR must wait
        // for handleForeground.
        guard !isRecording(), !isBackgrounded else { return }
        for session in archive.sessions
        where session.importing == true && tasks[session.id] == nil
            && activities[session.id] == nil {
            guard let checkpoint = session.importCheckpoint,
                  let audioFileName = session.audioFileName
            else { continue }
            resumeImport(sessionID: session.id, checkpoint: checkpoint, audioFileName: audioFileName)
        }
    }

    /// Re-issues summaries that were requested but never finished — a
    /// process kill mid-summary (jetsam, or the uncatchable background-GPU
    /// abort) leaves the persisted intent behind. Cheap to redo: the map
    /// phase resumes from the chunk-note checkpoint. Called on cold launch
    /// after `resumeUnfinishedImports` (an importing placeholder re-arms
    /// its auto-summary through the import resume itself).
    func resumeUnfinishedSummaries() {
        // Backgrounded covers the background-launch case too: iOS can
        // relaunch the app in the background (background URLSession
        // events), where the startup sweep must not start LLM work.
        guard !isRecording(), !isBackgrounded else { return }
        for session in archive.sessions
        where session.pendingSummary != nil && session.importing != true
            && !isBusy(session.id) {
            guard let pending = session.pendingSummary,
                  let style = SummaryStyle(rawValue: pending.styleRaw),
                  let length = SummaryLength(rawValue: pending.lengthRaw)
            else {
                // Unparseable marker (style/length from a future build):
                // drop it rather than rescan every launch.
                clearPendingSummary(session.id)
                continue
            }
            logger.info("pending-summary sweep: restarting \(session.id, privacy: .public) notes=\(session.chunkNotes?.count ?? 0)")
            summarize(
                sessionID: session.id, style: style, length: length,
                // Carry the consent the user gave when they requested this
                // summary — a restart mid-download must keep downloading.
                allowDownload: pending.allowDownload ?? false,
                isResume: true)
        }
    }

    /// Starts accuracy passes that are waiting for power — deferred at
    /// recording time, or orphaned by a mid-pass kill. Called at launch,
    /// on foreground resume, and when the charger connects. Each hit
    /// re-runs the normal post-process decision, so model installs/removals
    /// since the marker was written are honored (and a marker with nothing
    /// left to do is consumed there).
    func resumePendingPostProcesses() {
        // Cheap early-out before touching UIDevice: battery notifications
        // can bounce (plug/unplug, charge/full) and most fires find
        // nothing pending.
        guard archive.sessions.contains(where: { $0.pendingPostProcess != nil })
        else { return }
        guard !isRecording(), !isBackgrounded, Self.isPluggedIn() else { return }
        for session in archive.sessions
        where session.pendingPostProcess != nil && session.importing != true
            && !isBusy(session.id) {
            guard let pending = session.pendingPostProcess,
                  let style = SummaryStyle(rawValue: pending.styleRaw),
                  let length = SummaryLength(rawValue: pending.lengthRaw)
            else {
                // Unparseable marker (style/length from a future build).
                clearPendingPostProcess(session.id)
                continue
            }
            logger.info("pending accuracy pass: starting \(session.id, privacy: .public)")
            postProcessAndSummarizeNewSession(
                sessionID: session.id, style: style, length: length,
                suggestVocabulary: pending.suggestVocabulary ?? false)
        }
    }

    private func markPendingPostProcess(
        sessionID: UUID, style: SummaryStyle, length: SummaryLength,
        suggestVocabulary: Bool
    ) {
        guard var record = archive.sessions.first(where: { $0.id == sessionID }) else { return }
        record.pendingPostProcess = SessionRecord.PendingPostProcess(
            styleRaw: style.rawValue, lengthRaw: length.rawValue,
            suggestVocabulary: suggestVocabulary)
        archive.update(record)
    }

    private func clearPendingPostProcess(_ sessionID: UUID) {
        guard var record = archive.sessions.first(where: { $0.id == sessionID }),
              record.pendingPostProcess != nil
        else { return }
        record.pendingPostProcess = nil
        archive.update(record)
    }

    private func markPendingSummary(
        sessionID: UUID, style: SummaryStyle, length: SummaryLength,
        allowDownload: Bool = false
    ) {
        guard var record = archive.sessions.first(where: { $0.id == sessionID }) else { return }
        record.pendingSummary = SessionRecord.PendingSummary(
            styleRaw: style.rawValue, lengthRaw: length.rawValue,
            allowDownload: allowDownload)
        archive.update(record)
    }

    private func clearPendingSummary(_ sessionID: UUID) {
        guard var record = archive.sessions.first(where: { $0.id == sessionID }),
              record.pendingSummary != nil
        else { return }
        record.pendingSummary = nil
        archive.update(record)
    }

    /// Shared task-lifecycle plumbing for a fresh import and a resumed one:
    /// the gate, the background grace, progress wiring, and what happens on
    /// success/cancel/failure. `engine` does the actual transcribe/diarize/
    /// translate work and returns the finished record.
    private func runImportJob(
        sessionID: UUID,
        engine: @escaping (
            @escaping @MainActor @Sendable (FileImportEngine.Phase) -> Void
        ) async throws -> SessionRecord
    ) {
        activities[sessionID] = .importing(.transcribing(0))
        beginGrace(sessionID, name: "import")
        tasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            defer { self.finishJob(sessionID) }
            do { try await self.heavyGate.acquire() } catch { return }
            defer { self.heavyGate.release() }
            do {
                var record = try await engine { [weak self] phase in
                    self?.importProgress(sessionID: sessionID, phase: phase)
                }
                record.unseen = true
                self.archive.update(record)
                self.lastCompleted = Completion(id: sessionID, at: .now)
                // Imports have no post-stop scenario card, so summarize them
                // automatically once transcription lands.
                self.autoSummarizeAfterImport(sessionID: sessionID)
            } catch is CancellationError {
                let held = self.activities[sessionID] == .pausedForRecording
                    || self.activities[sessionID] == .pausedForBackground
                let checkpointed = self.archive.sessions
                    .first(where: { $0.id == sessionID })?.importCheckpoint != nil
                if held, checkpointed {
                    // Preempted by a recording or the scene backgrounding —
                    // the checkpoint stays; resumeAfterRecording()/
                    // resumeBackgroundJobs() re-enqueues it.
                } else {
                    // User cancel, or a preempt BEFORE the durable audio +
                    // checkpoint landed (e.g. still extracting a video's
                    // audio) — nothing can resume this placeholder, and a
                    // held one would sit "importing" with no job until a
                    // relaunch sweep. Delete it, clearing the held badge.
                    self.hotwords.discardSuggestions(forSession: sessionID)
                    self.archive.delete(id: sessionID)
                    self.activities[sessionID] = nil
                }
            } catch {
                self.errors[sessionID] = error.localizedDescription
                // A failed import must not auto-retry (the finishJob
                // re-sweep would restart it immediately, and a
                // deterministic failure — e.g. no recognizable speech —
                // would loop forever). Dropping the checkpoint makes the
                // resume sweeps skip it; the checkpoint-less placeholder
                // is swept at next launch, same as pre-resume behavior.
                if var record = self.archive.sessions.first(where: { $0.id == sessionID }) {
                    record.importCheckpoint = nil
                    self.archive.update(record)
                }
            }
        }
    }

    /// Persists the durable audio + a fresh checkpoint as soon as the
    /// import engine has copied the file — before transcription even
    /// starts, so a kill in the first second still leaves something to
    /// resume from.
    private func recordImportAudioReady(
        sessionID: UUID, recordingName: String, duration: TimeInterval, recordedAt: Date,
        direction: LanguagePair, speakerCount: Int, engine: String, sensitivity: MicSensitivity
    ) {
        guard var record = archive.sessions.first(where: { $0.id == sessionID }) else { return }
        record.audioFileName = recordingName
        record.importCheckpoint = SessionRecord.ImportCheckpoint(
            direction: direction, speakerCount: speakerCount, engine: engine,
            sensitivityRaw: sensitivity.rawValue, recordedAt: recordedAt, duration: duration)
        archive.update(record)
    }

    /// Appends one freshly-decoded segment to the checkpoint and persists
    /// it — same per-checkpoint write frequency already proven safe by the
    /// live summary map phase.
    private func recordImportSegment(
        sessionID: UUID, segment: SessionRecord.ImportCheckpoint.Segment
    ) {
        guard var record = archive.sessions.first(where: { $0.id == sessionID }),
              record.importCheckpoint != nil
        else { return }
        record.importCheckpoint?.segments.append(segment)
        archive.update(record)
    }

    /// Arms (or reuses) the accuracy pass's resume checkpoint and returns
    /// the segments a matching prior attempt already decoded. A checkpoint
    /// written by a different backend is replaced — its segments are not
    /// reusable. The Apple backend reports no segments, so there's nothing
    /// to arm.
    private func seedRetranscribeCheckpoint(
        sessionID: UUID, backend: OfflineTranscriber.Backend
    ) -> [SessionRecord.ImportCheckpoint.Segment] {
        guard backend != .apple,
              var record = archive.sessions.first(where: { $0.id == sessionID })
        else { return [] }
        let reusable = SessionRetranscriber.reusableSegments(
            checkpoint: record.retranscribeCheckpoint, backend: backend)
        if record.retranscribeCheckpoint?.backendRaw != backend.rawValue {
            record.retranscribeCheckpoint = SessionRecord.RetranscribeCheckpoint(
                backendRaw: backend.rawValue)
            archive.update(record)
        }
        if !reusable.isEmpty {
            logger.info("retranscribe resume: \(reusable.count) cached segments for \(sessionID, privacy: .public)")
        }
        return reusable
    }

    /// How many decoded segments accumulate before the checkpoint persists.
    /// Unlike an import (whose record starts empty), a retranscribe rides a
    /// fully-populated SessionRecord — per-segment archive.update would
    /// re-encode the whole multi-hundred-KB record continuously for the
    /// 20-30 min pass. Batching trades ≤9 segments (~1 min of decode) of
    /// resume progress for ~10x less encode/flash churn.
    private static let retranscribeCheckpointBatch = 10

    /// Batched checkpoint writer for the accuracy pass. nil for Apple
    /// (no segments). The tail of a partial batch is deliberately not
    /// flushed — a cancelled pass just re-decodes those few segments.
    private func retranscribeSegmentRecorder(
        sessionID: UUID, backend: OfflineTranscriber.Backend
    ) -> (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? {
        guard backend != .apple else { return nil }
        retranscribeSegmentBuffers[sessionID] = []
        return { [weak self] segment in
            self?.bufferRetranscribeSegment(sessionID: sessionID, segment: segment)
        }
    }

    private func bufferRetranscribeSegment(
        sessionID: UUID, segment: SessionRecord.ImportCheckpoint.Segment
    ) {
        retranscribeSegmentBuffers[sessionID, default: []].append(segment)
        guard let buffered = retranscribeSegmentBuffers[sessionID],
              buffered.count >= Self.retranscribeCheckpointBatch,
              var record = archive.sessions.first(where: { $0.id == sessionID }),
              record.retranscribeCheckpoint != nil
        else { return }
        record.retranscribeCheckpoint?.segments.append(contentsOf: buffered)
        retranscribeSegmentBuffers[sessionID] = []
        archive.update(record)
    }

    /// Summarize a freshly imported session with the user's default style.
    /// Only when the LLM is already downloaded — a fresh install must not
    /// trigger a silent multi-GB fetch or leave an error row on the import.
    /// Deferred to its own task so the import job's `finishJob` clears the
    /// busy state before `summarize`'s `isBusy` guard runs.
    private func autoSummarizeAfterImport(sessionID: UUID) {
        guard llmEnabled, LLMService.isDownloaded(model: ModelCatalog.current)
        else { return }
        let style = SummaryStyle(
            rawValue: UserDefaults.standard.string(forKey: "summary.defaultStyle") ?? "")
            ?? .meeting
        let length = SummaryLength(
            rawValue: UserDefaults.standard.string(forKey: "summary.defaultLength") ?? "")
            ?? .standard
        Task { @MainActor [weak self] in
            self?.summarize(
                sessionID: sessionID, style: style, length: length,
                suggestVocabulary: true)
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
        case .cleaningUpTranscript(let f):
            setProgress(sessionID, .importing(.cleaningUpTranscript(Self.percent(f))),
                        phaseKey: "import.cleanup", fraction: f)
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
        case .cleaningUpTranscript(let f):
            setProgress(sessionID, .retranscribing(.cleaningUpTranscript(Self.percent(f))),
                        phaseKey: "re.cleanup", fraction: f)
        case .identifyingSpeakers(let f):
            setProgress(sessionID, .retranscribing(.identifyingSpeakers(Self.percent(f))),
                        phaseKey: "re.diarize", fraction: f)
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
        if !Self.isHeldActivity(activities[sessionID]) {
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
        retranscribeSegmentBuffers[sessionID] = nil
        // A resume sweep that ran while this job was still unwinding
        // skipped its session (`tasks` non-nil). Now that teardown is
        // done, re-sweep — otherwise a checkpointed import cancelled by
        // backgrounding/yield whose unwind outlived the foreground sweep
        // stays stranded until the next cold launch. The sweep's own
        // guards (foreground, not recording, no badge, checkpoint
        // present) make this a no-op in every other case.
        resumeUnfinishedImports()
        // Same rationale for deferred accuracy passes: the charger can
        // connect while the battery-time summarize is still running — the
        // battery observer's sweep skips the busy session, and no later
        // battery event may come. Re-sweep now that this job's slot is
        // clear; the sweep's own guards no-op every other case.
        resumePendingPostProcesses()
    }

    /// Respect the gates, then make the model ready. With consent the load
    /// may download, reporting progress through the session's activity.
    private func loadModel(sessionID: UUID, allowDownload: Bool) async throws {
        guard llmEnabled else { throw JobError.aiDisabled }
        await llm.setModel(ModelCatalog.summaryModel)
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
        suggestVocabulary: Bool,
        isResume: Bool = false
    ) async throws {
        // Re-fetch after the (possibly minutes-long) model download: edits
        // made meanwhile must not be clobbered by a stale snapshot, and a
        // deleted session simply ends the job.
        guard let session = archive.sessions.first(where: { $0.id == sessionID })
        else { return }
        let engine = SummaryEngine(llm: llm, matcher: hotwords.matcher)
        logger.info("runSummarize: isResume=\(isResume) notes=\(session.chunkNotes?.count ?? 0) usableCheckpoint=\(Self.hasUsableMapCheckpoint(session))")
        let refreshed = await refreshAttachmentText(in: session)
        if refreshed.changed { archive.update(refreshed.record) }
        // Hygiene first: retro-apply hotword fixes and catch up refinement
        // the live session dropped, so the notes map over the cleanest text
        // we can produce. Skipped when resuming onto an existing map
        // checkpoint: hygiene already ran before that map started, and
        // re-running it re-rolls hotword restores that failed last time
        // (LLM, nondeterministic) — one changed entry inside the covered
        // range wipes the checkpoint and remaps the whole transcript (the
        // background→foreground progress-reset bug).
        let hygiene: (record: SessionRecord, changed: Bool)
        if isResume, Self.hasUsableMapCheckpoint(refreshed.record) {
            hygiene = (refreshed.record, false)
            logger.info("hygiene skipped (resume onto checkpoint)")
        } else {
            hygiene = await engine.hygienePass(refreshed.record)
            if hygiene.changed, refreshed.record.chunkNotes != nil,
               hygiene.record.chunkNotes == nil {
                logger.warning("hygiene reset coverage: notes wiped, full remap ahead")
            }
        }
        let cleaned = hygiene.record
        if hygiene.changed { archive.update(cleaned) }
        let result = try await engine.summarize(
            cleaned, style: style, length: length,
            in: SummaryEngine.summaryLanguage(for: cleaned),
            progress: { [weak self] done, total in
                guard let self, self.activities[sessionID] != nil else { return }
                self.activities[sessionID] = .summarizing(done: done, total: total)
            },
            checkpoint: { [weak self] notes, coveredThroughID in
                // Persist each completed map chunk so a mid-summary
                // interruption (background, or a hard Metal crash) resumes
                // from here instead of remapping the whole transcript.
                // Re-fetch to avoid clobbering a concurrent edit.
                guard let self,
                      var record = self.archive.sessions.first(where: { $0.id == sessionID })
                else { return }
                record.chunkNotes = notes
                record.liveNotesEndEntryID = coveredThroughID
                self.archive.update(record)
                self.logger.info("summary checkpoint: \(notes.count) notes, coverage full=\(coveredThroughID == record.entries.last?.id)")
            })
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
        let transcript = record.plainTranscript(includeSpeakers: false)
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

    func renderCachedSummaryIfPossible(
        sessionID: UUID,
        style: SummaryStyle,
        length: SummaryLength
    ) async throws -> Bool {
        guard let session = archive.sessions.first(where: { $0.id == sessionID }),
              let notes = session.chunkNotes, !notes.isEmpty,
              session.liveNotesEndEntryID == session.entries.last?.id,
              !notes.contains(where: { $0.isFallback == true })
        else { return false }

        let refreshed = await refreshAttachmentText(in: session)
        var record = refreshed.record
        let engine = SummaryEngine(llm: llm, matcher: hotwords.matcher)
        let hygiene = await engine.hygienePass(record)
        record = hygiene.record
        if hygiene.changed {
            archive.update(record)
            return false
        }
        let summary = try await engine.reduce(
            notes: AttachmentNotes.merged(notes, attachments: record.attachments),
            style: style,
            length: length,
            maxInputCharacters: SummaryEngine.reduceInputCharacterBudget,
            in: SummaryEngine.summaryLanguage(for: record))
        record.summary = summary
        record.summaryEdited = nil
        record.summaryStyle = style.rawValue
        record.summaryLength = length.rawValue
        if refreshed.changed {
            record.attachments = refreshed.record.attachments
        }
        archive.update(record)
        return true
    }

    private func refreshAttachmentText(
        in record: SessionRecord
    ) async -> (record: SessionRecord, changed: Bool) {
        #if os(iOS)
        guard var attachments = record.attachments, !attachments.isEmpty else {
            return (record, false)
        }
        var changed = false
        for index in attachments.indices where attachments[index].ocrText == nil {
            let url = SessionArchive.attachmentURL(fileName: attachments[index].fileName)
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data),
                  let text = await ImageTextExtractor.recognizeText(in: image)
            else { continue }
            attachments[index].ocrText = text
            attachments[index].summaryRecords = nil
            changed = true
        }
        // VLM description back-fill. The summary's model is (about to be)
        // loaded here, so this is the reliable place to describe photos — the
        // live queue only runs when the model is already warm, which a short
        // session rarely is. When the summary model is text-only (e.g. the
        // experimental Bonsai tier), describe via the live VLM, then restore
        // the summary model for reduce.
        // ponytail: a model swap per summarize only when text-only + undescribed
        // photos exist; the default Qwen path keeps the current model untouched.
        let summaryModel = await llm.model
        let needsDescribe = attachments.contains { $0.vlmDescription == nil }
        if needsDescribe, !summaryModel.supportsVision {
            await llm.setModel(ModelCatalog.liveModel)
        }
        if await llm.model.supportsVision {
            let language = SummaryEngine.summaryLanguage(for: record)
            let prompts = PromptBuilder()
            for index in attachments.indices where attachments[index].vlmDescription == nil {
                let url = SessionArchive.attachmentURL(fileName: attachments[index].fileName)
                let prompt = prompts.imageDescriptionPrompt(
                    in: language,
                    context: transcriptContext(around: attachments[index], in: record))
                guard let raw = try? await llm.describeImage(
                          at: url, system: prompt.system, user: prompt.user)
                else { continue }
                let text = prompts.plainDescription(raw)
                guard !text.isEmpty, !PromptBuilder.hasDegenerateRepetition(text)
                else { continue }
                attachments[index].vlmDescription = text
                attachments[index].summaryRecords = nil
                changed = true
            }
        }
        if await llm.model.id != summaryModel.id {
            await llm.setModel(summaryModel)
        }
        guard changed else { return (record, false) }
        var updated = record
        updated.attachments = attachments
        return (updated, true)
        #else
        return (record, false)
        #endif
    }

    /// Transcript lines around a photo's anchor (or the tail when unanchored),
    /// capped, to ground the description in what was being discussed.
    private func transcriptContext(
        around attachment: SessionRecord.Attachment, in record: SessionRecord
    ) -> String {
        let entries = record.entries
        let window: [SessionRecord.Entry]
        if let anchor = attachment.anchorEntryID,
           let idx = entries.firstIndex(where: { $0.id == anchor }) {
            window = Array(entries[max(0, idx - 2)..<min(entries.count, idx + 3)])
        } else {
            window = Array(entries.suffix(4))
        }
        let text = window.map(\.sourceText).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(400))
    }
}

/// One-at-a-time FIFO gate for the heavy post-hoc jobs (ASR decode, MLX
/// generation). Each needs most of the device's spare memory; two at once —
/// e.g. a re-summary fired during a file import — overrun the budget and the
/// OS kills the process. A job acquires the single slot, runs, then releases
/// it to the next in line. Main-actor confined; never touched off it.
@MainActor
final class SerialGate {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// Jobs parked behind the current holder. For tests.
    var waiterCount: Int { waiters.count }

    /// Park until the slot is free. Throws `CancellationError` if cancelled
    /// while still queued — the caller then owns nothing and must NOT release.
    func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.drop(id) }
        }
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    /// Resolve once the slot is free. The live pipeline calls this after it
    /// preempts post-hoc work, so a cancelled import/summarize fully unwinds
    /// (releasing its GPU/ASR memory) before live capture touches the GPU.
    /// Queues last and immediately releases — it only needs to observe the
    /// drain, not hold the slot.
    func waitUntilIdle() async {
        guard busy else { return }
        do { try await acquire() } catch { return }
        release()
    }

    /// Hand the slot to the next waiter, or free it if none are queued.
    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume(returning: ())
        }
    }

    private func drop(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
