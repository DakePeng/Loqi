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

    init() {
        load()
        sweepOrphanedRecordings()
    }

    /// Build a record from live entries and persist it. Skips trivial
    /// sessions (nothing finalized worth keeping).
    @discardableResult
    func save(
        entries: [CaptionEntry],
        mode: SessionMode,
        speakerNames: [Int: String],
        startedAt: Date,
        artifacts: SessionArtifacts? = nil
    ) -> SessionRecord? {
        // Only this session's entries: the on-screen transcript may still
        // hold earlier sessions (the user controls Clear), and re-archiving
        // them would duplicate transcripts across records.
        let saved = entries
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
                    rawSourceText: entry.rawSourceText)
            }
        guard saved.count >= 2 else { return nil }

        var record = SessionRecord(
            id: artifacts?.sessionID ?? UUID(),
            mode: mode,
            startedAt: startedAt,
            endedAt: .now,
            entries: saved,
            speakerNames: speakerNames)
        if let artifacts {
            record.audioFileName = artifacts.audioFileName
            if !artifacts.chunkNotes.isEmpty {
                record.chunkNotes = artifacts.chunkNotes
                record.liveNotesEndEntryID = artifacts.notesEndEntryID
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
        sessions[index] = record
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
        }
        sessions.remove(atOffsets: offsets)
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

    // MARK: Persistence

    private func load() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func persist(_ record: SessionRecord) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(
                to: Self.directory.appending(path: "\(record.id.uuidString).json"))
        }
    }
}
