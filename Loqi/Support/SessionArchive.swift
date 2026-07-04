import Foundation
import Observation
import os

/// Saved-session storage: one JSON file per session in Application Support.
/// Everything stays on-device.
/// Extra per-session outputs produced by the pipeline (recording, live
/// summary notes), bundled so `save` doesn't sprout parameters.
struct SessionArtifacts: Sendable {
    var sessionID: UUID
    var audioFileName: String?
    var chunkNotes: [SessionRecord.ChunkNote] = []
    var notesEndEntryID: UUID?
    var speakerCount: Int?
    /// Wall-clock → audio-file mapping for stamping entry offsets.
    var timeline: AudioTimeline?
    /// Photos attached while recording.
    var attachments: [SessionRecord.Attachment] = []
}

@MainActor
@Observable
final class SessionArchive {
    private(set) var sessions: [SessionRecord] = []
    private var didLoad = false
    @ObservationIgnored private var deletedSessionIDs: Set<UUID> = []
    /// Encode + disk I/O for record JSON, off the main actor.
    @ObservationIgnored private let persister = RecordPersister(
        directory: SessionArchive.directory)
    /// Tail of the ordered persist handoff chain; see `enqueuePersist`.
    @ObservationIgnored private var persistHandoff: Task<Void, Never>?

    nonisolated private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Sessions", directoryHint: .isDirectory)
    }

    // nonisolated: the recorder actor builds paths off the main actor.
    nonisolated static var recordingsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    nonisolated static func recordingURL(fileName: String) -> URL {
        recordingsDirectory.appending(path: fileName)
    }

    nonisolated static var attachmentsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
    }

    nonisolated static func attachmentURL(fileName: String) -> URL {
        attachmentsDirectory.appending(path: fileName)
    }

    init() {}

    /// Delete recording/attachment files no session references. Called by
    /// the pipeline AFTER crash recovery has claimed the interrupted
    /// session's files — sweeping in init would destroy exactly the audio
    /// recovery exists to save.
    func sweepOrphans() {
        guard didLoad else { return }
        sweepOrphanedRecordings()
        sweepOrphanedAttachments()
    }

    /// Archive-shape entries from live caption entries: finalized text
    /// created during this session, stamped with audio offsets when a
    /// timeline exists. Shared by the clean save and the crash journal so
    /// a recovered session is byte-identical to a saved one.
    nonisolated static func mappedEntries(
        from entries: [CaptionEntry], startedAt: Date, timeline: AudioTimeline?
    ) -> [SessionRecord.Entry] {
        entries
            .filter {
                $0.state != .volatile && !$0.sourceText.isEmpty
                    && $0.createdAt >= startedAt
            }
            .map { entry in
                // Reuse the live entry's id: live chunk notes anchor to it.
                SessionRecord.Entry(
                    id: entry.id,
                    sourceText: entry.sourceText,
                    translation: entry.displayTranslation,
                    speaker: entry.speaker,
                    direction: entry.direction,
                    timestamp: entry.createdAt,
                    rawSourceText: entry.rawSourceText,
                    audioOffset: timeline?.offset(for: entry.createdAt))
            }
    }

    /// An audio-only session (recording exists, nothing transcribed) is
    /// kept from this duration up — the audio is the user's data even when
    /// ASR produced nothing. Below it, a stray pocket-tap stays junk.
    nonisolated static let audioOnlyMinimumDuration: TimeInterval = 5

    /// Whether a stopping session is worth archiving. Any finalized speech
    /// keeps it (a one-line voice memo is a real note); otherwise a
    /// non-trivial recording keeps it. Pure for tests.
    nonisolated static func shouldArchive(
        entryCount: Int, hasAudio: Bool, duration: TimeInterval
    ) -> Bool {
        entryCount >= 1 || (hasAudio && duration >= audioOnlyMinimumDuration)
    }

    /// Build a record from live entries and persist it. Returns nil (and
    /// saves nothing) only when there is neither speech nor audio worth
    /// keeping — see `shouldArchive`.
    @discardableResult
    func save(
        entries: [CaptionEntry],
        mode: SessionMode,
        speakerNames: [Int: String],
        startedAt: Date,
        artifacts: SessionArtifacts? = nil
    ) -> SessionRecord? {
        // Only this session's entries: the filter guards against any
        // pre-session text still in the store; re-archiving it would
        // duplicate transcripts across records.
        let saved = Self.mappedEntries(
            from: entries, startedAt: startedAt, timeline: artifacts?.timeline)
        guard Self.shouldArchive(
            entryCount: saved.count,
            hasAudio: artifacts?.audioFileName != nil,
            duration: Date.now.timeIntervalSince(startedAt))
        else { return nil }

        var record = SessionRecord(
            id: artifacts?.sessionID ?? UUID(),
            mode: mode,
            startedAt: startedAt,
            endedAt: .now,
            entries: saved,
            speakerNames: speakerNames)
        record.recordingSpeakerCount = artifacts?.speakerCount
        // Fresh arrival: the Sessions list dots it until first opened.
        record.unseen = true
        if let artifacts {
            record.audioFileName = artifacts.audioFileName
            if !artifacts.chunkNotes.isEmpty {
                record.chunkNotes = artifacts.chunkNotes
                record.liveNotesEndEntryID = artifacts.notesEndEntryID
            }
            if !artifacts.attachments.isEmpty {
                record.attachments = artifacts.attachments
            }
        }
        sessions.insert(record, at: 0)
        persist(record)
        return record
    }

    /// Insert a prebuilt record (e.g. an imported audio file) in date order.
    func add(_ record: SessionRecord) {
        let index = sessions.firstIndex { $0.startedAt < record.startedAt } ?? sessions.count
        sessions.insert(record, at: index)
        persist(record)
    }

    func update(_ record: SessionRecord) {
        guard let index = sessions.firstIndex(where: { $0.id == record.id }) else { return }
        if sessions[index].startedAt == record.startedAt {
            sessions[index] = record
        } else {
            // startedAt changed (an import placeholder created "now" filled
            // in with the file's real creation date): re-seat in date order
            // or the row sits mis-sorted until the next launch.
            sessions.remove(at: index)
            let newIndex = sessions.firstIndex { $0.startedAt < record.startedAt }
                ?? sessions.count
            sessions.insert(record, at: newIndex)
        }
        persist(record)
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            let record = sessions[index]
            deletedSessionIDs.insert(record.id)
            // Through the persister so a queued snapshot can't land after
            // (and undo) the deletion.
            removePersisted(id: record.id)
            if let fileName = record.audioFileName {
                try? FileManager.default.removeItem(
                    at: Self.recordingURL(fileName: fileName))
            }
            for attachment in record.attachments ?? [] {
                try? FileManager.default.removeItem(
                    at: Self.attachmentURL(fileName: attachment.fileName))
            }
        }
        sessions.remove(atOffsets: offsets)
        // Deletions must survive an immediate force-quit:
        // `deletedSessionIDs` is in-memory only, so an unflushed queued
        // removal would resurrect the record (audio already gone) at next
        // launch. Land it now instead of waiting for the next background
        // flush.
        Task { [weak self] in await self?.flushPersistence() }
    }

    /// Delete a whole session: record JSON, audio file, in-memory entry.
    func delete(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        delete(at: IndexSet(integer: index))
    }

    /// Delete only the audio file, keeping transcript and summary — for
    /// privacy or disk space. No-op when the session has no audio.
    func discardAudio(for id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              let fileName = sessions[index].audioFileName else { return }
        try? FileManager.default.removeItem(at: Self.recordingURL(fileName: fileName))
        sessions[index].audioFileName = nil
        persist(sessions[index])
    }

    /// On-disk size of a recording, for "frees X MB" copy. nil when the
    /// file is missing.
    nonisolated static func recordingSizeBytes(fileName: String) -> Int64? {
        let url = recordingURL(fileName: fileName)
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return Int64(bytes)
    }

    /// Delete recording files no session references (e.g. a crash between
    /// recording and archiving). Pure decision logic is static for tests.
    nonisolated static func orphanedRecordings(
        onDisk: Set<String>,
        referenced: Set<String>,
        protectedBasenames: Set<String> = []
    ) -> Set<String> {
        let protected = onDisk.filter {
            protectedBasenames.contains(
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)
        }
        return onDisk.subtracting(referenced).subtracting(protected)
    }

    private func sweepOrphanedRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.recordingsDirectory, includingPropertiesForKeys: nil) else { return }
        let onDisk = Set(files.map(\.lastPathComponent))
        let referenced = Set(sessions.compactMap(\.audioFileName))
        let importingIDs = Set(sessions.compactMap {
            $0.importing == true ? $0.id.uuidString : nil
        })
        for orphan in Self.orphanedRecordings(
            onDisk: onDisk,
            referenced: referenced,
            protectedBasenames: importingIDs) {
            try? fm.removeItem(at: Self.recordingURL(fileName: orphan))
        }
    }

    /// Same crash-orphan logic for attachment images (e.g. a crash between
    /// attaching and archiving, or a trivial session that never saved).
    private func sweepOrphanedAttachments() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.attachmentsDirectory, includingPropertiesForKeys: nil) else { return }
        let onDisk = Set(files.map(\.lastPathComponent))
        let referenced = Set(sessions.flatMap { ($0.attachments ?? []).map(\.fileName) })
        for orphan in Self.orphanedRecordings(onDisk: onDisk, referenced: referenced) {
            try? fm.removeItem(at: Self.attachmentURL(fileName: orphan))
        }
    }

    // MARK: Persistence

    nonisolated static func decodeAll(in directory: URL) -> [SessionRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
    }

    /// A killed-mid-import record survives relaunch only if it has both a
    /// durable audio file and checkpointed progress to resume from —
    /// anything less is a tombstone (no transcript worth keeping).
    nonisolated static func isResumableImport(_ record: SessionRecord) -> Bool {
        record.importing == true && record.importCheckpoint != nil
            && record.audioFileName != nil
    }

    nonisolated static func mergedLoadedSessions(
        decoded: [SessionRecord],
        current: [SessionRecord],
        deletedIDs: Set<UUID>
    ) -> [SessionRecord] {
        var byID: [UUID: SessionRecord] = [:]
        for record in decoded
        where (record.importing != true || isResumableImport(record))
            && !deletedIDs.contains(record.id) {
            byID[record.id] = record
        }
        for record in current where !deletedIDs.contains(record.id) {
            byID[record.id] = record
        }
        return byID.values.sorted { $0.startedAt > $1.startedAt }
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        let directory = Self.directory
        let decoded = await Task.detached {
            Self.decodeAll(in: directory)
        }.value
        // Records still marked importing are either resumable (checkpointed
        // progress + durable audio survive) or tombstones of a kill before
        // either existed — only the latter gets swept.
        let fm = FileManager.default
        let currentIDs = Set(sessions.map(\.id))
        for abandoned in decoded where abandoned.importing == true
            && !Self.isResumableImport(abandoned)
            && !currentIDs.contains(abandoned.id) {
            try? fm.removeItem(
                at: directory.appending(path: "\(abandoned.id.uuidString).json"))
        }
        sessions = Self.mergedLoadedSessions(
            decoded: decoded,
            current: sessions,
            deletedIDs: deletedSessionIDs)
        didLoad = true
    }

    /// Await all queued record writes hitting disk. Called when the scene
    /// backgrounds (a jetsam must not lose the last coalesced checkpoint)
    /// and by tests that read the directory right after a mutation.
    func flushPersistence() async {
        await persistHandoff?.value
        await persister.flush()
    }

    /// Hand one operation to the persister, chained behind the previous
    /// handoff: independent fire-and-forget tasks could reach the actor out
    /// of order, letting an update overtake a delete and resurrect the
    /// record's file.
    private func enqueuePersist(
        _ operation: @escaping @Sendable (RecordPersister) async -> Void
    ) {
        let persister = persister
        persistHandoff = Task { [previous = persistHandoff] in
            await previous?.value
            await operation(persister)
        }
    }

    private func persist(_ record: SessionRecord) {
        enqueuePersist { await $0.write(record) }
    }

    private func removePersisted(id: UUID) {
        enqueuePersist { await $0.remove(id: id) }
    }
}

/// Serializes record JSON writes off the main actor, coalescing bursts per
/// record — during an import checkpoint or a summary map phase the same
/// record is re-persisted once per segment/chunk, and a synchronous encode
/// of a large transcript on the main actor freezes the UI (and delays the
/// scenePhase delivery the GPU gates depend on). The latest snapshot per
/// record wins; a `remove` supersedes any queued write so a deleted record
/// can't be resurrected by an in-flight one. Mirrors `JournalWriter`.
actor RecordPersister {
    private enum Operation {
        case write(SessionRecord)
        case remove
    }

    private let directory: URL
    private var pending: [UUID: Operation] = [:]
    private var draining = false
    private let logger = Logger(
        subsystem: "com.kunzhipeng.loqi", category: "archive")

    init(directory: URL) {
        self.directory = directory
    }

    /// Queue the latest snapshot. Returns immediately; encode + disk write
    /// happen on this actor's executor.
    func write(_ record: SessionRecord) {
        pending[record.id] = .write(record)
        startDraining()
    }

    /// Queue the record file's deletion, dropping any queued snapshot.
    func remove(id: UUID) {
        pending[id] = .remove
        startDraining()
    }

    /// Process everything queued right now — lets tests (and shutdown
    /// paths) await durability. The background drain then finds nothing.
    func flush() {
        drainOnce()
    }

    private func startDraining() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() {
        // No `await` inside drainOnce, so each pass runs atomically on the
        // actor: an operation arriving meanwhile lands in the next pass.
        while !pending.isEmpty {
            drainOnce()
        }
        draining = false
    }

    private func drainOnce() {
        let batch = pending
        pending = [:]
        for (id, operation) in batch {
            let started = ContinuousClock.now
            perform(operation, id: id)
            let elapsed = started.duration(to: .now)
            if elapsed > .milliseconds(250) {
                logger.warning("slow record persist: \(String(describing: elapsed)) for \(id)")
            }
        }
    }

    private func perform(_ operation: Operation, id: UUID) {
        let url = directory.appending(path: "\(id.uuidString).json")
        switch operation {
        case .write(let record):
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(record) {
                try? data.write(to: url, options: .atomic)
            }
        case .remove:
            try? FileManager.default.removeItem(at: url)
        }
    }
}
