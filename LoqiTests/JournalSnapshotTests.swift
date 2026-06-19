import Foundation
import Testing

@testable import Loqi

struct JournalSnapshotTests {
    private func finalized(
        _ text: String,
        at offset: TimeInterval,
        mode: SessionMode = .captions
    ) -> CaptionEntry {
        CaptionEntry(
            sourceText: text,
            direction: LanguagePair(source: .english, target: .english),
            mode: mode,
            state: .finalized,
            createdAt: Date(timeIntervalSince1970: offset))
    }

    @Test func buildsRecordWithMappedEntries() {
        let started = Date(timeIntervalSince1970: 0)
        let inputs = JournalSnapshotInputs(
            sessionID: UUID(),
            mode: .captions,
            startedAt: started,
            evicted: [finalized("old", at: 1)],
            live: [finalized("new", at: 2)],
            timeline: nil,
            speakerNames: [:],
            recordingSpeakerCount: 0,
            audioFileName: "rec.caf",
            chunkNotes: [],
            notesEndEntryID: nil,
            attachments: [])

        let record = JournalWriter.buildJournalRecord(from: inputs)
        #expect(record.entries.map(\.sourceText) == ["old", "new"])
        #expect(record.audioFileName == "rec.caf")
        #expect(record.startedAt == started)
    }

    @Test func dropsVolatileAndPreSessionEntries() {
        let started = Date(timeIntervalSince1970: 10)
        var volatile = finalized("typing", at: 11)
        volatile.state = .volatile
        let inputs = JournalSnapshotInputs(
            sessionID: UUID(),
            mode: .captions,
            startedAt: started,
            evicted: [],
            live: [finalized("before", at: 5), volatile, finalized("kept", at: 12)],
            timeline: nil,
            speakerNames: [:],
            recordingSpeakerCount: 0,
            audioFileName: nil,
            chunkNotes: [],
            notesEndEntryID: nil,
            attachments: [])

        let record = JournalWriter.buildJournalRecord(from: inputs)
        #expect(record.entries.map(\.sourceText) == ["kept"])
    }

    @Test func filtersEntriesToSnapshotMode() {
        let started = Date(timeIntervalSince1970: 0)
        let inputs = JournalSnapshotInputs(
            sessionID: UUID(),
            mode: .captions,
            startedAt: started,
            evicted: [finalized("chat", at: 1, mode: .conversation)],
            live: [finalized("caption", at: 2, mode: .captions)],
            timeline: nil,
            speakerNames: [:],
            recordingSpeakerCount: 0,
            audioFileName: nil,
            chunkNotes: [],
            notesEndEntryID: nil,
            attachments: [])

        let record = JournalWriter.buildJournalRecord(from: inputs)
        #expect(record.entries.map(\.sourceText) == ["caption"])
    }
}
