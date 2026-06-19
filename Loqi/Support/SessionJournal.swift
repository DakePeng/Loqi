import Foundation

/// Crash insurance for the running session. The pipeline snapshots the
/// live session (as a ready-to-archive SessionRecord) after every finalized
/// utterance / note / photo; a clean stop deletes the file. If the journal
/// still exists at launch, the process died mid-recording — the snapshot,
/// plus the crash-tolerant CAF audio, is everything recovery needs.
///
/// Atomic whole-file writes: a snapshot is either the previous complete
/// state or the next one, never a torn read.
enum SessionJournal {
    nonisolated static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "live-session.json")
    }

    nonisolated static func write(_ record: SessionRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The interrupted session's snapshot, or nil after a clean shutdown.
    nonisolated static func read() -> SessionRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    nonisolated static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

struct JournalSnapshotInputs: Sendable {
    let sessionID: UUID
    let mode: SessionMode
    let startedAt: Date
    let evicted: [CaptionEntry]
    let live: [CaptionEntry]
    let timeline: AudioTimeline?
    let speakerNames: [Int: String]
    let recordingSpeakerCount: Int
    let audioFileName: String?
    let chunkNotes: [SessionRecord.ChunkNote]
    let notesEndEntryID: UUID?
    let attachments: [SessionRecord.Attachment]
}

/// Serializes crash-journal disk writes off the caller (the @MainActor
/// pipeline) and coalesces bursts: only the latest snapshot between drains is
/// encoded and written, so a finalized utterance never blocks the main actor
/// on JSON encoding + an atomic file write. A `clear` supersedes any pending
/// snapshot and removes the file, so a clean stop can't be overtaken by an
/// in-flight write that would resurrect the journal.
actor JournalWriter {
    private var pending: SessionRecord?
    private var draining = false

    nonisolated static func buildJournalRecord(from inputs: JournalSnapshotInputs) -> SessionRecord {
        var record = SessionRecord(
            id: inputs.sessionID,
            mode: inputs.mode,
            startedAt: inputs.startedAt,
            endedAt: .now,
            entries: SessionArchive.mappedEntries(
                from: (inputs.evicted + inputs.live).filter { $0.mode == inputs.mode },
                startedAt: inputs.startedAt,
                timeline: inputs.timeline),
            speakerNames: inputs.speakerNames)
        record.recordingSpeakerCount = inputs.recordingSpeakerCount
        if inputs.audioFileName != nil { record.audioFileName = inputs.audioFileName }
        if !inputs.chunkNotes.isEmpty {
            record.chunkNotes = inputs.chunkNotes
            record.liveNotesEndEntryID = inputs.notesEndEntryID
        }
        if !inputs.attachments.isEmpty { record.attachments = inputs.attachments }
        return record
    }

    /// Queue the latest session snapshot. Returns immediately; the encode and
    /// disk write happen on this actor's executor.
    func write(_ record: SessionRecord) {
        pending = record
        startDraining()
    }

    func write(building inputs: JournalSnapshotInputs) {
        pending = Self.buildJournalRecord(from: inputs)
        startDraining()
    }

    /// Drop any queued snapshot and delete the journal file. Awaiting this
    /// guarantees no queued write lands afterwards: the actor serializes work,
    /// so this runs after any in-flight drain, and `pending` is cleared here.
    func clear() {
        pending = nil
        SessionJournal.clear()
    }

    private func startDraining() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() {
        // No `await` inside, so this runs atomically on the actor: a `write`
        // arriving meanwhile is picked up on the next iteration (last wins).
        while let record = pending {
            pending = nil
            SessionJournal.write(record)
        }
        draining = false
    }
}
