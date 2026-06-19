import Foundation
import Testing
@testable import Loqi

/// Pure-logic coverage for the summary-accuracy work: vocabulary injection
/// into the map phase, grounding in the reduce phase, and fallback-stub
/// handling end to end.
struct SummaryAccuracyTests {
    let builder = PromptBuilder()

    // MARK: Map-phase vocabulary injection

    @Test func noteGlossaryListsOnlyPlausiblyPresentTerms() {
        let matcher = HotwordMatcher(hotwords: [
            Hotword(
                term: "Zhipeng",
                renderings: [.english: "Zhipeng", .chinese: "志鹏"],
                note: "person name"),
            Hotword(term: "Kubernetes", note: "platform"),
        ])
        let lines = matcher.noteGlossaryLines(
            language: .english, text: "I asked Zhipemg to review it")
        #expect(lines == ["Zhipeng (person name)"])

        // CJK homophone scoring works monolingually too.
        let cjk = matcher.noteGlossaryLines(
            language: .chinese, text: "请智朋看一下")
        #expect(cjk == ["志鹏 (person name)"])

        #expect(matcher.noteGlossaryLines(
            language: .english, text: "nothing relevant here").isEmpty)
    }

    // MARK: Fallback stubs

    @Test func renderDropsCrossKindAndParaphrasedDuplicates() {
        // The same statement extracted as a point in one chunk and a decision
        // in another (kinds differ, so deduped() keeps both) must render once;
        // a near-paraphrase of it is also suppressed. Distinct facts survive.
        let notes = [
            SessionRecord.ChunkNote(
                headline: "A", startedAt: .now,
                facts: ["Ship the release on June 10"]),
            SessionRecord.ChunkNote(
                headline: "B", startedAt: Date().addingTimeInterval(1),
                facts: ["Hire two engineers"],
                decisions: ["Ship the release on June 10."]),
        ]
        let output = SummaryRecordReducer.render(
            records: SummaryRecordReducer.records(from: notes),
            style: .meeting, length: .standard, in: .english)
        let occurrences = output.components(separatedBy: "Ship the release on June 10")
            .count - 1
        #expect(occurrences == 1)
        #expect(output.contains("Hire two engineers"))
    }

    @Test func renderKeepsDistinctRecords() {
        // Guard against over-merging: two clearly different facts both survive.
        let notes = [
            SessionRecord.ChunkNote(
                headline: "A", startedAt: .now,
                facts: ["Budget is ¥30", "Launch in Tokyo first"]),
        ]
        let output = SummaryRecordReducer.render(
            records: SummaryRecordReducer.records(from: notes),
            style: .meeting, length: .standard, in: .english)
        #expect(output.contains("Budget is ¥30"))
        #expect(output.contains("Launch in Tokyo first"))
    }

    @Test func parsedChunkNoteIsEmptyOnlyWhenFullyEmpty() {
        #expect(PromptBuilder.ParsedChunkNote().isEmpty)
        #expect(!PromptBuilder.ParsedChunkNote(headline: "h").isEmpty)
        #expect(!PromptBuilder.ParsedChunkNote(facts: ["f"]).isEmpty)
    }

    @Test func summarizeRollsCoverageBackToFirstFallbackStub() {
        let direction = LanguagePair(source: .chinese, target: .chinese)
        let entries = (0..<6).map {
            SessionRecord.Entry(
                sourceText: "entry \($0)", translation: nil, speaker: nil,
                direction: direction, timestamp: .now, rawSourceText: nil)
        }
        var record = SessionRecord(
            mode: .captions, startedAt: .now, endedAt: .now, entries: entries)
        record.chunkNotes = [
            .init(headline: "good", startedAt: .now,
                  anchorEntryID: entries[0].id, facts: ["f"]),
            .init(headline: "stub", startedAt: .now,
                  anchorEntryID: entries[2].id, isFallback: true),
            .init(headline: "after", startedAt: .now,
                  anchorEntryID: entries[4].id, facts: ["g"]),
        ]
        record.liveNotesEndEntryID = entries[5].id

        let (uncovered, cached) = SummaryEngine.uncoveredEntries(of: record)
        // The stub chunk and everything after it get remapped; the good
        // note before it survives as cache.
        #expect(uncovered.map(\.sourceText)
            == ["entry 2", "entry 3", "entry 4", "entry 5"])
        #expect(cached.map(\.headline) == ["good"])

        // A stub whose anchor no longer resolves makes coverage
        // unknowable — remap everything.
        record.chunkNotes?[1].anchorEntryID = UUID()
        let (all, none) = SummaryEngine.uncoveredEntries(of: record)
        #expect(all.count == 6)
        #expect(none.isEmpty)
    }

    @Test func chunkNoteDecodesRecordsWithoutFallbackField() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","headline":"h",
         "startedAt":700000000,"facts":[],"decisions":[],
         "actions":[],"terms":[]}
        """
        let note = try JSONDecoder().decode(
            SessionRecord.ChunkNote.self, from: Data(legacy.utf8))
        #expect(note.isFallback == nil)
        #expect(!note.hasContent)
    }

    // MARK: Re-transcription speaker inheritance

    @Test func inheritedSpeakersFollowTimeOverlap() {
        let direction = LanguagePair(source: .chinese, target: .english)
        let start = Date.now
        var record = SessionRecord(
            mode: .captions, startedAt: start, endedAt: start,
            entries: [
                .init(sourceText: "a", translation: nil, speaker: 0,
                      direction: direction, timestamp: start, audioOffset: 0),
                .init(sourceText: "b", translation: nil, speaker: 1,
                      direction: direction,
                      timestamp: start.addingTimeInterval(10), audioOffset: 10),
            ])

        let speakers = SessionRetranscriber.inheritSpeakers(
            for: [(1, 4), (9.5, 12), (11, 15)], from: record)
        // (9.5, 12) overlaps slot 0 for 0.5s and slot 1 for 2s → slot 1.
        #expect(speakers == [0, 1, 1])

        // Records saved before audioOffset existed fall back to timestamp
        // deltas — same segments, same answer.
        for index in record.entries.indices {
            record.entries[index].audioOffset = nil
        }
        #expect(SessionRetranscriber.inheritSpeakers(
            for: [(1, 4), (11, 15)], from: record) == [0, 1])

        // No diarized old entries → nothing to inherit.
        for index in record.entries.indices {
            record.entries[index].speaker = nil
        }
        #expect(SessionRetranscriber.inheritSpeakers(
            for: [(1, 4)], from: record) == [nil])
    }

    // MARK: Hygiene pass cache invalidation

    @Test func hygieneFixupInvalidatesCoveredLiveNotes() async {
        let matcher = HotwordMatcher(hotwords: [
            Hotword(term: "Zhipeng", note: "person name"),
        ])
        let direction = LanguagePair(source: .english, target: .english)
        let entries = [
            SessionRecord.Entry(
                sourceText: "ask Zhipemg about the rollout", translation: nil,
                speaker: nil, direction: direction, timestamp: .now,
                rawSourceText: "ask Zhipemg about the rollout"),
        ]
        var record = SessionRecord(
            mode: .captions, startedAt: .now, endedAt: .now, entries: entries)
        record.chunkNotes = [.init(
            headline: "h", startedAt: .now,
            anchorEntryID: entries[0].id, facts: ["f"])]
        record.liveNotesEndEntryID = entries[0].id

        // rawSourceText set: the polish path is skipped, so only the
        // deterministic fixup runs — no LLM needed in this test.
        let engine = SummaryEngine(llm: LLMService(), matcher: matcher)
        let (cleaned, changed) = await engine.hygienePass(record)
        #expect(changed)
        #expect(cleaned.entries[0].sourceText == "ask Zhipeng about the rollout")
        #expect(cleaned.chunkNotes == nil)
        #expect(cleaned.liveNotesEndEntryID == nil)
    }

    @Test func hygieneWithoutHotwordsIsANoOp() async {
        let record = SessionRecord(
            mode: .captions, startedAt: .now, endedAt: .now, entries: [])
        let engine = SummaryEngine(
            llm: LLMService(), matcher: HotwordMatcher(hotwords: []))
        let (cleaned, changed) = await engine.hygienePass(record)
        #expect(!changed)
        #expect(cleaned.entries.isEmpty)
    }
}

@Suite(.serialized)
@MainActor
struct SummaryJobCenterCacheTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func cachedSummaryPathRunsHygieneBeforeUsingLiveNotes() async throws {
        let hotwordDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: hotwordDirectory) }
        let archive = SessionArchive()
        let hotwords = HotwordStore(directory: hotwordDirectory)
        hotwords.add(Hotword(term: "Zhipeng", note: "person name"))
        let jobs = SummaryJobCenter(
            llm: LLMService(), archive: archive, hotwords: hotwords,
            translator: TranslationCoordinator(), voiceprint: VoiceprintService(),
            isRecording: { false })

        let direction = LanguagePair(source: .english, target: .english)
        let entry = SessionRecord.Entry(
            sourceText: "ask Zhipemg about the rollout", translation: nil,
            speaker: nil, direction: direction, timestamp: .now,
            rawSourceText: "ask Zhipemg about the rollout")
        var record = SessionRecord(
            mode: .captions, startedAt: .now, endedAt: .now,
            entries: [entry])
        record.chunkNotes = [.init(
            headline: "h", startedAt: .now, anchorEntryID: entry.id,
            facts: ["f"])]
        record.liveNotesEndEntryID = entry.id
        archive.add(record)
        defer { archive.delete(id: record.id) }

        let rendered = try await jobs.renderCachedSummaryIfPossible(
            sessionID: record.id, style: .meeting, length: .standard)

        #expect(!rendered)
        let updated = try #require(archive.sessions.first { $0.id == record.id })
        #expect(updated.entries[0].sourceText == "ask Zhipeng about the rollout")
        #expect(updated.chunkNotes == nil)
        #expect(updated.liveNotesEndEntryID == nil)
        #expect(updated.summary == nil)
    }
}
