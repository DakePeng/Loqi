import Foundation
import Testing

@testable import Loqi

struct SessionArchiveLoadTests {
    private func writeRecord(_ record: SessionRecord, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: directory.appending(path: "\(record.id.uuidString).json"))
    }

    private func record(at offset: TimeInterval, importing: Bool = false) -> SessionRecord {
        var record = SessionRecord(
            mode: .captions,
            startedAt: Date(timeIntervalSince1970: offset),
            endedAt: Date(timeIntervalSince1970: offset + 1),
            entries: [])
        if importing { record.importing = true }
        return record
    }

    @Test func decodesSortsDescendingAndDropsImporting() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecord(record(at: 100), to: directory)
        try writeRecord(record(at: 300), to: directory)
        try writeRecord(record(at: 200, importing: true), to: directory)

        let decoded = SessionArchive.decodeAll(in: directory)
        let kept = decoded.filter { $0.importing != true }
            .sorted { $0.startedAt > $1.startedAt }

        #expect(decoded.count == 3)
        #expect(kept.map(\.startedAt) == [
            Date(timeIntervalSince1970: 300),
            Date(timeIntervalSince1970: 100),
        ])
    }

    @Test func missingDirectoryDecodesEmpty() {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(SessionArchive.decodeAll(in: directory).isEmpty)
    }

    @Test func loadedSnapshotMergesWithCurrentMutations() {
        let old = record(at: 100)
        var updated = old
        updated.endedAt = Date(timeIntervalSince1970: 150)
        let added = record(at: 300)
        let deleted = record(at: 200)

        let merged = SessionArchive.mergedLoadedSessions(
            decoded: [old, deleted],
            current: [updated, added],
            deletedIDs: [deleted.id])

        #expect(merged.map(\.id) == [added.id, updated.id])
        #expect(merged.first { $0.id == updated.id }?.endedAt == updated.endedAt)
    }
}
