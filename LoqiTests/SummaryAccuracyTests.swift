import Foundation
import Testing
@testable import Loqi

/// Pure-logic coverage for the summary-accuracy work: vocabulary injection
/// into the map phase, grounding in the reduce phase, and fallback-stub
/// handling end to end.
struct SummaryAccuracyTests {
    let builder = PromptBuilder()

    // MARK: Map-phase vocabulary injection

    @Test func chunkNotePromptCarriesVocabularyOnlyWhenPresent() {
        let bare = builder.chunkNotePrompt(chunkText: "text", in: .english)
        #expect(!bare.system.contains("known terms"))
        #expect(!bare.user.contains("Known terms:"))
        #expect(bare.user == "Excerpt:\ntext")

        let primed = builder.chunkNotePrompt(
            chunkText: "text",
            vocabulary: ["志鹏 (person name)", "Qwen (model family)"],
            in: .english)
        #expect(primed.system.contains("mis-hearing of one of the known terms"))
        #expect(primed.user == """
        Known terms: 志鹏 (person name); Qwen (model family)
        Excerpt:
        text
        """)
    }

    @Test func chunkNotePromptDemandsVerbatimSpecifics() {
        let prompt = builder.chunkNotePrompt(chunkText: "x", in: .chinese)
        #expect(prompt.system.contains(
            "Copy names, numbers, dates, and amounts exactly"))
        #expect(prompt.system.contains(
            "Do not add anything that is not in the excerpt."))
        #expect(prompt.system.contains("Write in Chinese."))
    }

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

    // MARK: Reduce-phase grounding

    @Test func everyStyleReducePromptIsGrounded() {
        for style in SummaryStyle.allCases {
            let system = builder.reduceSummaryPrompt(
                notes: "x", style: style, in: .english).system
            #expect(system.contains(
                "Use only information from the notes; never invent names, "
                + "numbers, or events."))
            #expect(system.contains(
                "Keep names, numbers, and dates exactly as written in the notes."))
        }
    }

    @Test func segmentSectionPromptIsGrounded() {
        let system = builder.segmentSectionPrompt(notes: "x", in: .english).system
        #expect(system.contains(
            "Use only information from the notes; never invent names, "
            + "numbers, or events."))
    }

    // MARK: Fallback stubs

    @Test func reduceInputSkipsHeadlineOnlyStubs() {
        let full = SessionRecord.ChunkNote(
            headline: "Pricing review", startedAt: .now,
            facts: ["Plan costs ¥30"])
        let stub = SessionRecord.ChunkNote(
            headline: "嗯那个我们今天", startedAt: .now, isFallback: true)
        let input = SummaryEngine.reduceInput(
            notes: [stub, full], style: .meeting)
        #expect(input == """
        [1] Pricing review
        fact: Plan costs ¥30
        """)
    }

    @Test func reduceInputKeepsHeadlinesWhenEveryNoteIsAStub() {
        let stubs = [
            SessionRecord.ChunkNote(headline: "Opening", startedAt: .now),
            SessionRecord.ChunkNote(headline: "Closing", startedAt: .now),
        ]
        let input = SummaryEngine.reduceInput(notes: stubs, style: .meeting)
        #expect(input == "[1] Opening\n[2] Closing")
    }

    @Test func reduceInputDropsCrossNoteDuplicateBullets() {
        // The same fact restated in a later chunk (here only case/punctuation
        // differs) is dropped; distinct facts and both headlines survive.
        let notes = [
            SessionRecord.ChunkNote(
                headline: "A", startedAt: .now,
                facts: ["Ship June 10", "Budget is ¥30"]),
            SessionRecord.ChunkNote(
                headline: "B", startedAt: .now,
                facts: ["ship june 10.", "Hire two engineers"]),
        ]
        let input = SummaryEngine.reduceInput(notes: notes, style: .meeting)
        #expect(input == """
        [1] A
        fact: Ship June 10
        fact: Budget is ¥30
        [2] B
        fact: Hire two engineers
        """)
    }

    @Test func reduceInputKeepsDistinctSimilarBullets() {
        // "决定一" / "决定二" are distinct (one-char differences below the
        // near-duplicate threshold) and must not be merged.
        let note = SessionRecord.ChunkNote(
            headline: "A", startedAt: .now,
            decisions: ["决定一", "决定二", "决定三"])
        let input = SummaryEngine.reduceInput(notes: [note], style: .meeting)
        #expect(input.contains("decision: 决定一"))
        #expect(input.contains("decision: 决定二"))
        #expect(input.contains("decision: 决定三"))
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
