import Foundation
import Observation

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

    private static var directory: URL {
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

    init() {
        load()
    }

    /// Delete recording/attachment files no session references. Called by
    /// the pipeline AFTER crash recovery has claimed the interrupted
    /// session's files — sweeping in init would destroy exactly the audio
    /// recovery exists to save.
    func sweepOrphans() {
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
            try? FileManager.default.removeItem(
                at: Self.directory.appending(path: "\(sessions[index].id.uuidString).json"))
            if let fileName = sessions[index].audioFileName {
                try? FileManager.default.removeItem(
                    at: Self.recordingURL(fileName: fileName))
            }
            for attachment in sessions[index].attachments ?? [] {
                try? FileManager.default.removeItem(
                    at: Self.attachmentURL(fileName: attachment.fileName))
            }
        }
        sessions.remove(atOffsets: offsets)
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
        onDisk: Set<String>, referenced: Set<String>
    ) -> Set<String> {
        onDisk.subtracting(referenced)
    }

    private func sweepOrphanedRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.recordingsDirectory, includingPropertiesForKeys: nil) else { return }
        let onDisk = Set(files.map(\.lastPathComponent))
        let referenced = Set(sessions.compactMap(\.audioFileName))
        for orphan in Self.orphanedRecordings(onDisk: onDisk, referenced: referenced) {
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

    private func load() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
        // Records still marked importing are tombstones of a kill
        // mid-import: no transcript was ever written, so sweep them.
        for abandoned in decoded where abandoned.importing == true {
            try? fm.removeItem(
                at: Self.directory.appending(path: "\(abandoned.id.uuidString).json"))
        }
        sessions = decoded
            .filter { $0.importing != true }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func persist(_ record: SessionRecord) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(
                to: Self.directory.appending(path: "\(record.id.uuidString).json"),
                options: .atomic)
        }
    }
}
