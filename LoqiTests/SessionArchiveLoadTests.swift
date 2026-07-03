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

    private func record(
        at offset: TimeInterval, importing: Bool = false, resumable: Bool = false
    ) -> SessionRecord {
        var record = SessionRecord(
            mode: .captions,
            startedAt: Date(timeIntervalSince1970: offset),
            endedAt: Date(timeIntervalSince1970: offset + 1),
            entries: [])
        if importing { record.importing = true }
        if resumable {
            record.audioFileName = "\(record.id.uuidString).m4a"
            record.importCheckpoint = SessionRecord.ImportCheckpoint(
                direction: LanguagePair(source: .chinese, target: .english),
                speakerCount: 1, engine: "apple", sensitivityRaw: "balanced",
                recordedAt: Date(timeIntervalSince1970: offset), duration: 10)
        }
        return record
    }

    @Test func decodesSortsDescendingAndDropsUnresumableImporting() throws {
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

    @Test func isResumableImportRequiresCheckpointAndAudio() {
        #expect(!SessionArchive.isResumableImport(record(at: 100)))
        #expect(!SessionArchive.isResumableImport(record(at: 100, importing: true)))

        var checkpointOnly = record(at: 100, importing: true)
        checkpointOnly.importCheckpoint = SessionRecord.ImportCheckpoint(
            direction: LanguagePair(source: .chinese, target: .english),
            speakerCount: 1, engine: "apple", sensitivityRaw: "balanced",
            recordedAt: .now, duration: 10)
        #expect(!SessionArchive.isResumableImport(checkpointOnly))  // no audio file

        #expect(SessionArchive.isResumableImport(
            record(at: 100, importing: true, resumable: true)))
    }

    @Test func mergedSnapshotKeepsResumableImportsButDropsAbandonedOnes() {
        let resumable = record(at: 200, importing: true, resumable: true)
        let abandoned = record(at: 250, importing: true)

        let merged = SessionArchive.mergedLoadedSessions(
            decoded: [record(at: 100), resumable, abandoned],
            current: [],
            deletedIDs: [])

        #expect(merged.contains { $0.id == resumable.id })
        #expect(!merged.contains { $0.id == abandoned.id })
    }

    @Test func persisterCoalescesWritesAndHonorsRemoval() async {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persister = RecordPersister(directory: directory)

        var kept = record(at: 100)
        await persister.write(kept)
        kept.titleText = "latest snapshot wins"
        await persister.write(kept)
        let removed = record(at: 200)
        await persister.write(removed)
        await persister.remove(id: removed.id)
        await persister.flush()

        let decoded = SessionArchive.decodeAll(in: directory)
        #expect(decoded.map(\.id) == [kept.id])
        #expect(decoded.first?.titleText == "latest snapshot wins")
    }
}
