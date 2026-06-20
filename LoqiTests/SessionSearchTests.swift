import Foundation
import Testing
@testable import Loqi

struct SessionSearchTests {
    private func makeRecord() -> SessionRecord {
        SessionRecord(
            mode: .captions,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_125),
            entries: [
                .init(
                    sourceText: "大家好",
                    translation: "Hello everyone",
                    speaker: 0,
                    direction: LanguagePair(source: .chinese, target: .english),
                    timestamp: .now),
                .init(
                    sourceText: "今天讲翻译",
                    translation: "Today we discuss translation",
                    speaker: 0,
                    direction: LanguagePair(source: .chinese, target: .english),
                    timestamp: .now),
                .init(
                    sourceText: "有问题吗",
                    translation: "Any questions?",
                    speaker: 1,
                    direction: LanguagePair(source: .chinese, target: .english),
                    timestamp: .now),
            ],
            speakerNames: [0: "王老师"])
    }

    private func match(_ record: SessionRecord, _ query: String) -> SessionSearch.Match? {
        SessionSearch.match(
            record,
            lowercasedQuery: query.lowercased(),
            haystack: SessionSearch.haystack(for: record))
    }

    @Test func latinMatchIsCaseInsensitive() {
        let record = makeRecord()
        let hit = match(record, "HELLO")
        #expect(hit != nil)
        #expect(hit?.firstEntryID == record.entries[0].id)
    }

    @Test func cjkSubstringMatchesWithoutWordBoundaries() {
        let record = makeRecord()
        let hit = match(record, "翻译")
        // "翻译" appears inside "今天讲翻译" — substring containment, and
        // again in no other field, so the count is exactly 1.
        #expect(hit?.matchCount == 1)
        #expect(hit?.firstEntryID == record.entries[1].id)
    }

    @Test func translationOnlyMatchStillTargetsItsEntry() {
        let record = makeRecord()
        let hit = match(record, "questions")
        #expect(hit?.firstEntryID == record.entries[2].id)
        #expect(hit?.snippet.contains("Any questions?") == true)
    }

    @Test func summaryOnlyMatchHasNoJumpTarget() {
        var record = makeRecord()
        record.summary = "The meeting covered quarterly budgets."
        let hit = match(record, "budgets")
        #expect(hit != nil)
        #expect(hit?.firstEntryID == nil)
    }

    @Test func chunkNoteAndSpeakerNameMatch() {
        var record = makeRecord()
        record.chunkNotes = [
            .init(headline: "Roadmap review", startedAt: .now,
                  facts: ["Ship date is June"]),
        ]
        #expect(match(record, "roadmap") != nil)
        #expect(match(record, "ship date") != nil)
        let speakerHit = match(record, "王老师")
        #expect(speakerHit != nil)
        #expect(speakerHit?.firstEntryID == nil)
    }

    @Test func countsAreNonOverlapping() {
        #expect(SessionSearch.occurrences(of: "aa", in: "aaaa") == 2)
        #expect(SessionSearch.occurrences(of: "", in: "aaaa") == 0)
    }

    @Test func countAggregatesAcrossFields() {
        var record = makeRecord()
        record.summary = "Translation quality was discussed."
        // "translation" appears in entry 2's translation and the summary.
        #expect(match(record, "translation")?.matchCount == 2)
    }

    @Test func snippetClipsWithEllipsesAndKeepsCasing() {
        let text = String(repeating: "x", count: 60)
            + " Loqi stands out " + String(repeating: "y", count: 60)
        let snippet = SessionSearch.snippet(in: text, query: "loqi")
        #expect(snippet?.hasPrefix("…") == true)
        #expect(snippet?.hasSuffix("…") == true)
        #expect(snippet?.contains("Loqi") == true)   // original casing
    }

    @Test func snippetAtTextStartHasNoLeadingEllipsis() {
        let snippet = SessionSearch.snippet(
            in: "大家好，欢迎来到会议", query: "大家")
        #expect(snippet == "大家好，欢迎来到会议")
    }

    @MainActor @Test func whitespaceQueryMatchesNothing() {
        let matches = SessionSearchIndex().matches(in: [makeRecord()], query: "   \n")
        #expect(matches.isEmpty)
    }

    @Test func fingerprintTracksSearchableChanges() {
        var record = makeRecord()
        let before = SessionSearch.fingerprint(of: record)
        record.summary = "New summary"
        let afterSummary = SessionSearch.fingerprint(of: record)
        #expect(before != afterSummary)
        record.speakerNames[1] = "李同学"
        #expect(SessionSearch.fingerprint(of: record) != afterSummary)
    }

    @MainActor @Test func indexReturnsMatchesInSessionOrder() {
        var first = makeRecord()
        first.summary = "alpha"
        var second = makeRecord()
        second.summary = "alpha beta"
        let matches = SessionSearchIndex().matches(
            in: [first, second], query: "alpha")
        #expect(matches.map(\.sessionID) == [first.id, second.id])
    }

    // Transcript text edits at an unchanged entry count must invalidate the
    // search-blob cache (re-transcribe / hotword-restore swap words in place).
    @Test func sourceEditChangesFingerprintAtSameEntryCount() {
        let a = makeRecord()
        var b = a                                  // value copy: same id/endedAt/count
        b.entries[0].sourceText = "完全不同的内容"   // only the source text differs
        #expect(SessionSearch.fingerprint(of: a) != SessionSearch.fingerprint(of: b))
    }

    @Test func translationEditChangesFingerprint() {
        let a = makeRecord()
        var b = a
        b.entries[0].translation = "A completely different translation"
        #expect(SessionSearch.fingerprint(of: a) != SessionSearch.fingerprint(of: b))
    }
}
