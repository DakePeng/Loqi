import AVFoundation
import Foundation
import Testing
@testable import Locally

struct LiveChunkerTests {
    private let direction = LanguagePair(source: .chinese, target: .chinese)
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func entry(
        _ text: String, speaker: Int? = nil, at offset: TimeInterval
    ) -> CaptionEntry {
        var entry = CaptionEntry(
            sourceText: text,
            direction: direction,
            state: .finalized,
            createdAt: base.addingTimeInterval(offset))
        entry.speaker = speaker
        return entry
    }

    @Test func budgetBreakClosesBeforeOverflowingEntry() {
        var chunker = LiveChunker(budget: 10, gap: 25)
        #expect(chunker.append(entry("一二三四五六", at: 0)) == nil)
        // 6 + 6 > 10: the second entry starts a fresh chunk.
        let closed = chunker.append(entry("七八九十百千", at: 1))
        #expect(closed?.count == 1)
        #expect(closed?.first?.sourceText == "一二三四五六")
        let flushed = chunker.flush()
        #expect(flushed?.first?.sourceText == "七八九十百千")
    }

    @Test func longPauseClosesChunk() {
        var chunker = LiveChunker(budget: 1000, gap: 25)
        #expect(chunker.append(entry("hello", at: 0)) == nil)
        let closed = chunker.append(entry("again", at: 30))
        #expect(closed?.count == 1)
    }

    @Test func speakerChangeBreaksOnlyWhenMostlyFull() {
        var chunker = LiveChunker(budget: 10, gap: 25)
        // 3 chars = 30% of budget: speaker change does NOT break yet.
        #expect(chunker.append(entry("一二三", speaker: 0, at: 0)) == nil)
        #expect(chunker.append(entry("四五六七", speaker: 1, at: 1)) == nil)
        // Now past 60% (7 > 6): next speaker change breaks.
        let closed = chunker.append(entry("八九十", speaker: 0, at: 2))
        #expect(closed?.count == 2)
    }

    @Test func closeForGapFiresOnlyAfterSilence() {
        var chunker = LiveChunker(budget: 1000, gap: 25)
        _ = chunker.append(entry("hello", at: 0))
        #expect(chunker.closeForGap(now: base.addingTimeInterval(10)) == nil)
        let closed = chunker.closeForGap(now: base.addingTimeInterval(26))
        #expect(closed?.count == 1)
        // Already closed: nothing left.
        #expect(chunker.closeForGap(now: base.addingTimeInterval(60)) == nil)
        #expect(chunker.flush() == nil)
    }

    /// The streaming chunker must produce the same boundaries as the batch
    /// `SummaryEngine.chunkEntries` it ports, for the same input.
    @Test func streamingMatchesBatchChunking() {
        var live: [CaptionEntry] = []
        var time: TimeInterval = 0
        for index in 0..<40 {
            // Vary length, speaker, and inject occasional long pauses.
            let text = String(repeating: "字", count: 40 + (index % 7) * 30)
            time += index % 9 == 0 ? 30 : 3
            live.append(entry(text, speaker: index % 3, at: time))
        }
        let batch = live.map {
            SessionRecord.Entry(
                id: $0.id, sourceText: $0.sourceText, translation: nil,
                speaker: $0.speaker, direction: $0.direction,
                timestamp: $0.createdAt, rawSourceText: nil)
        }

        var chunker = LiveChunker()
        var streamed: [[CaptionEntry]] = []
        for entry in live {
            if let closed = chunker.append(entry) { streamed.append(closed) }
        }
        if let rest = chunker.flush() { streamed.append(rest) }

        let expected = SummaryEngine.chunkEntries(batch)
        #expect(streamed.count == expected.count)
        for (streamedChunk, expectedChunk) in zip(streamed, expected) {
            #expect(streamedChunk.map(\.id) == expectedChunk.map(\.id))
        }
    }
}

struct LiveNoteCoverageTests {
    private let direction = LanguagePair(source: .chinese, target: .chinese)

    private func record(
        entryCount: Int, notes: [SessionRecord.ChunkNote]? = nil,
        endID: UUID? = nil
    ) -> SessionRecord {
        let entries = (0..<entryCount).map {
            SessionRecord.Entry(
                sourceText: "entry \($0)", translation: nil, speaker: nil,
                direction: direction, timestamp: .now, rawSourceText: nil)
        }
        var record = SessionRecord(
            mode: .captions, startedAt: .now, endedAt: .now, entries: entries)
        record.chunkNotes = notes
        record.liveNotesEndEntryID = endID
        return record
    }

    @Test func noLiveNotesMapsEverything() {
        let record = record(entryCount: 5)
        let (entries, cached) = SummaryEngine.uncoveredEntries(of: record)
        #expect(entries.count == 5)
        #expect(cached.isEmpty)
    }

    @Test func partialCoverageMapsOnlyTail() {
        var record = record(entryCount: 5)
        record.chunkNotes = [.init(headline: "h", startedAt: .now)]
        record.liveNotesEndEntryID = record.entries[2].id
        let (entries, cached) = SummaryEngine.uncoveredEntries(of: record)
        #expect(entries.map(\.sourceText) == ["entry 3", "entry 4"])
        #expect(cached.count == 1)
    }

    @Test func fullCoverageMapsNothing() {
        var record = record(entryCount: 3)
        record.chunkNotes = [.init(headline: "h", startedAt: .now)]
        record.liveNotesEndEntryID = record.entries.last?.id
        let (entries, cached) = SummaryEngine.uncoveredEntries(of: record)
        #expect(entries.isEmpty)
        #expect(cached.count == 1)
    }

    @Test func unresolvableEndIDFallsBackToFullMap() {
        var record = record(entryCount: 4)
        record.chunkNotes = [.init(headline: "h", startedAt: .now)]
        record.liveNotesEndEntryID = UUID()  // pruned / foreign id
        let (entries, cached) = SummaryEngine.uncoveredEntries(of: record)
        #expect(entries.count == 4)
        #expect(cached.isEmpty)
    }
}

struct SessionRecorderSettingsTests {
    @Test func aacSettingsFollowStreamFormat() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 1, interleaved: false))
        let settings = SessionRecorder.aacSettings(for: format)
        #expect(settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        #expect(settings[AVSampleRateKey] as? Double == 48_000)
        #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
    }
}

struct OrphanedRecordingTests {
    @Test func orphansAreOnDiskFilesNoSessionReferences() {
        let orphans = SessionArchive.orphanedRecordings(
            onDisk: ["a.m4a", "b.m4a", "c.m4a"],
            referenced: ["b.m4a"])
        #expect(orphans == ["a.m4a", "c.m4a"])
    }

    @Test func noFilesMeansNoOrphans() {
        #expect(SessionArchive.orphanedRecordings(
            onDisk: [], referenced: ["x.m4a"]).isEmpty)
    }
}

@MainActor
struct SessionArchiveArtifactsTests {
    @Test func savedEntriesReuseLiveIDsAndCarryArtifacts() {
        let archive = SessionArchive()
        let direction = LanguagePair(source: .chinese, target: .chinese)
        let live = ["你好大家", "今天开会"].map {
            CaptionEntry(sourceText: $0, direction: direction, state: .finalized)
        }
        let note = SessionRecord.ChunkNote(
            headline: "开会", startedAt: .now, anchorEntryID: live[0].id)
        let artifacts = SessionArtifacts(
            sessionID: UUID(),
            audioFileName: "test-artifact.m4a",
            chunkNotes: [note],
            notesEndEntryID: live[1].id)

        let record = archive.save(
            entries: live, mode: .captions, speakerNames: [:],
            startedAt: .distantPast, artifacts: artifacts)

        // Live ids must survive into the record: chunk notes anchor to them.
        #expect(record?.entries.map(\.id) == live.map(\.id))
        #expect(record?.id == artifacts.sessionID)
        #expect(record?.audioFileName == "test-artifact.m4a")
        #expect(record?.chunkNotes?.first?.id == note.id)
        #expect(record?.liveNotesEndEntryID == live[1].id)

        // Clean up the persisted test session.
        if let record,
           let index = archive.sessions.firstIndex(where: { $0.id == record.id }) {
            archive.delete(at: [index])
        }
    }
}
