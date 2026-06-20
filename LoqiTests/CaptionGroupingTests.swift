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
