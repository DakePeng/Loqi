import Foundation
import Testing
@testable import Loqi

struct AudioTimelineTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func singleAnchorMapsElapsedWallTime() {
        let timeline = AudioTimeline(anchors: [.init(wall: t0, audio: 0)])
        #expect(timeline.offset(for: t0) == 0)
        #expect(timeline.offset(for: t0.addingTimeInterval(12.5)) == 12.5)
    }

    @Test func dateBeforeFirstAnchorHasNoOffset() {
        let timeline = AudioTimeline(anchors: [.init(wall: t0, audio: 0)])
        #expect(timeline.offset(for: t0.addingTimeInterval(-1)) == nil)
        #expect(AudioTimeline(anchors: []).offset(for: t0) == nil)
    }

    @Test func interruptionGapCollapsesOnAudioTimeline() {
        // Turn 1 runs 60s of audio; a 30s interruption follows (wall clock
        // advances, audio doesn't); turn 2 re-anchors at audio=60, wall=+90.
        let timeline = AudioTimeline(anchors: [
            .init(wall: t0, audio: 0),
            .init(wall: t0.addingTimeInterval(90), audio: 60),
        ])
        // Entry mid-turn-1: wall +40 → audio 40.
        #expect(timeline.offset(for: t0.addingTimeInterval(40)) == 40)
        // Entry 10s into turn 2: wall +100 → audio 70, not 100.
        #expect(timeline.offset(for: t0.addingTimeInterval(100)) == 70)
    }

    @Test func multipleRestartsPickTheLatestAnchor() {
        let timeline = AudioTimeline(anchors: [
            .init(wall: t0, audio: 0),
            .init(wall: t0.addingTimeInterval(20), audio: 18),
            .init(wall: t0.addingTimeInterval(50), audio: 40),
        ])
        #expect(timeline.offset(for: t0.addingTimeInterval(20)) == 18)
        #expect(timeline.offset(for: t0.addingTimeInterval(55)) == 45)
    }

    @Test func binarySearchPicksCorrectAnchorAcrossManyAnchorsAndExactBoundaries() {
        // 50 anchors, each turn +10s wall / +9s audio (a 1s gap per turn).
        let anchors = (0..<50).map { i in
            AudioTimeline.Anchor(
                wall: t0.addingTimeInterval(Double(i) * 10),
                audio: Double(i) * 9)
        }
        let timeline = AudioTimeline(anchors: anchors)
        // Exactly on anchor 20's wall (t0+200) → its audio, no elapsed.
        #expect(timeline.offset(for: t0.addingTimeInterval(200)) == 180)
        // Inside turn 19 (anchor 19: wall 190, audio 171) + 5s elapsed.
        #expect(timeline.offset(for: t0.addingTimeInterval(195)) == 176)
        // Inside turn 20 (anchor 20: wall 200, audio 180) + 5s elapsed.
        #expect(timeline.offset(for: t0.addingTimeInterval(205)) == 185)
        // Past the last anchor (49: wall 490, audio 441) + 510s elapsed.
        #expect(timeline.offset(for: t0.addingTimeInterval(1000)) == 951)
        // Before the first anchor → nil.
        #expect(timeline.offset(for: t0.addingTimeInterval(-1)) == nil)
    }

    @Test func resolvedAudioOffsetPrefersStampThenWallClock() {
        let record = SessionRecord(
            mode: .captions,
            startedAt: t0,
            endedAt: t0.addingTimeInterval(100),
            entries: [
                .init(
                    sourceText: "stamped",
                    direction: LanguagePair(source: .english, target: .english),
                    timestamp: t0.addingTimeInterval(30),
                    audioOffset: 21),
                .init(
                    sourceText: "legacy",
                    direction: LanguagePair(source: .english, target: .english),
                    timestamp: t0.addingTimeInterval(30)),
                .init(
                    sourceText: "before start",
                    direction: LanguagePair(source: .english, target: .english),
                    timestamp: t0.addingTimeInterval(-5)),
            ])
        #expect(record.resolvedAudioOffset(of: record.entries[0]) == 21)
        #expect(record.resolvedAudioOffset(of: record.entries[1]) == 30)
        #expect(record.resolvedAudioOffset(of: record.entries[2]) == 0)
    }

    @Test func entryAudioOffsetSurvivesCodableRoundTripAndLegacyDecode() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = SessionRecord.Entry(
            sourceText: "hi",
            direction: LanguagePair(source: .english, target: .chinese),
            timestamp: t0,
            audioOffset: 3.25)
        let decoded = try decoder.decode(
            SessionRecord.Entry.self, from: encoder.encode(entry))
        #expect(decoded.audioOffset == 3.25)

        // Legacy JSON without the field must keep decoding.
        let legacy = """
        {"id":"\(UUID().uuidString)","sourceText":"old","direction":\
        \(String(data: try encoder.encode(LanguagePair(source: .english, target: .english)), encoding: .utf8)!),\
        "timestamp":"2026-01-01T00:00:00Z"}
        """
        let old = try decoder.decode(
            SessionRecord.Entry.self, from: Data(legacy.utf8))
        #expect(old.audioOffset == nil)
    }
}
