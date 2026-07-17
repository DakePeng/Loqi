import Foundation
import Testing

@testable import Loqi

struct CaptionGroupingTests {
    private func entry(
        _ text: String,
        speaker: Int? = nil,
        at offset: TimeInterval
    ) -> CaptionEntry {
        var entry = CaptionEntry(
            sourceText: text,
            direction: LanguagePair(source: .english, target: .english),
            state: .finalized,
            createdAt: Date(timeIntervalSince1970: offset))
        entry.speaker = speaker
        return entry
    }

    @Test func consecutiveSameSpeakerWithinGapGroup() {
        let segments = CaptionGrouping.segments(
            from: [entry("a", speaker: 0, at: 0), entry("b", speaker: 0, at: 1)],
            gap: 12,
            maxEntries: 4)

        #expect(segments.count == 1)
        #expect(segments[0].entries.count == 2)
        #expect(segments[0].id == segments[0].entries[0].id)
    }

    @Test func speakerChangeSplits() {
        let segments = CaptionGrouping.segments(
            from: [entry("a", speaker: 0, at: 0), entry("b", speaker: 1, at: 1)],
            gap: 12,
            maxEntries: 4)

        #expect(segments.count == 2)
    }

    @Test func longPauseSplitsSameSpeaker() {
        let segments = CaptionGrouping.segments(
            from: [entry("a", speaker: 0, at: 0), entry("b", speaker: 0, at: 100)],
            gap: 12,
            maxEntries: 4)

        #expect(segments.count == 2)
    }

    @Test func capForcesNewSegment() {
        let entries = (0..<5).map { entry("x", speaker: 0, at: Double($0)) }
        let segments = CaptionGrouping.segments(from: entries, gap: 12, maxEntries: 4)

        #expect(segments[0].entries.count == 4)
        #expect(segments[1].entries.count == 1)
    }

    @Test func nilSpeakerJoinsRunningSegment() {
        let segments = CaptionGrouping.segments(
            from: [entry("a", speaker: 0, at: 0), entry("b", speaker: nil, at: 1)],
            gap: 12,
            maxEntries: 4)

        #expect(segments.count == 1)
    }
}

struct CaptionRunGroupingTests {
    private func entry(
        _ text: String,
        state: CaptionEntry.State = .finalized,
        at offset: TimeInterval
    ) -> CaptionEntry {
        CaptionEntry(
            sourceText: text,
            direction: LanguagePair(source: .japanese, target: .chinese),
            state: state,
            createdAt: Date(timeIntervalSince1970: offset))
    }

    @Test func unpunctuatedFragmentsJoinPunctuatedSplit() {
        let fragments = [
            entry("会議の予算は", at: 0),
            entry("来年からです。", at: 5),
            entry("次の議題。", at: 9),
        ]
        let runs = CaptionRunGrouping.runs(entries: fragments, lastEntryID: nil)
        #expect(runs.count == 2)
        #expect(runs[0].entries.count == 2)
        #expect(runs[0].id == fragments[0].id)
        #expect(runs[0].displayEntry.sourceText == "会議の予算は来年からです。")
        #expect(runs[1].entries.count == 1)
    }

    @Test func latestAndVolatileAlwaysRenderAlone() {
        let a = entry("それで", at: 0)
        let b = entry("続きです", at: 3)
        // b is the live entry: never joined even though a is unpunctuated.
        #expect(CaptionRunGrouping.runs(entries: [a, b], lastEntryID: b.id).count == 2)
        // A volatile entry never joins either side.
        let v = entry("入力中", state: .volatile, at: 3)
        #expect(CaptionRunGrouping.runs(entries: [a, v], lastEntryID: nil).count == 2)
    }

    @Test func joinGapBoundsARun() {
        let a = entry("間が空いた", at: 0)
        let b = entry("続き", at: 20)   // beyond the 12s join gap
        #expect(CaptionRunGrouping.runs(entries: [a, b], lastEntryID: nil).count == 2)
    }

    @Test func displayEntryFoldsTranslationsAndStates() {
        var a = entry("予算の話が", at: 0)
        a.draftTranslation = "预算的话"
        var b = entry("続いています", at: 4)
        b.state = .refining
        let folded = CaptionRunGrouping.runs(
            entries: [a, b], lastEntryID: nil)[0].displayEntry
        // Nil translations are skipped, available ones join.
        #expect(folded.displayTranslation == "预算的话")
        // Any refining fragment marks the run refining.
        #expect(folded.state == .refining)
        // draftFailed only when nothing translated AND something failed.
        #expect(!folded.draftFailed)
        var c = entry("失敗", at: 8)
        c.draftFailed = true
        let failed = CaptionRunGrouping.runs(
            entries: [entry("これは", at: 6), c], lastEntryID: nil)[0].displayEntry
        #expect(failed.draftFailed)
    }
}
