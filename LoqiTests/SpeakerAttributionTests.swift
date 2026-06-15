import Foundation
import Testing
@testable import Loqi

struct SpeakerAttributionTests {
    private typealias Segment = SpeakerAttribution.Segment

    @Test func containedUtteranceTakesItsSegmentsSlot() {
        let segments = [
            Segment(slot: 0, start: 0, end: 10),
            Segment(slot: 1, start: 10, end: 20),
        ]
        let slots = SpeakerAttribution.attribute(
            utterances: [(2, 5), (12, 18)], to: segments)
        #expect(slots == [0, 1])
    }

    @Test func straddlingUtteranceTakesTheLargerOverlap() {
        let segments = [
            Segment(slot: 0, start: 0, end: 10),
            Segment(slot: 1, start: 10, end: 20),
        ]
        // 2s in slot 0, 6s in slot 1.
        let slots = SpeakerAttribution.attribute(
            utterances: [(8, 16)], to: segments)
        #expect(slots == [1])
    }

    @Test func overlapIsSummedAcrossASlotsSegments() {
        // Slot 0 speaks around an interjection by slot 1: 3s + 3s beats 4s.
        let segments = [
            Segment(slot: 0, start: 0, end: 3),
            Segment(slot: 1, start: 3, end: 7),
            Segment(slot: 0, start: 7, end: 10),
        ]
        let slots = SpeakerAttribution.attribute(
            utterances: [(0, 10)], to: segments)
        #expect(slots == [0])
    }

    @Test func exactTieGoesToTheLowerSlot() {
        let segments = [
            Segment(slot: 0, start: 0, end: 5),
            Segment(slot: 1, start: 5, end: 10),
        ]
        let slots = SpeakerAttribution.attribute(
            utterances: [(3, 7)], to: segments)
        #expect(slots == [0])
    }

    @Test func nearbySegmentClaimsAStrandedUtterance() {
        // ASR heard speech where the diarizer found none (boundary
        // disagreement): the nearest segment within the gap limit wins.
        let segments = [
            Segment(slot: 0, start: 0, end: 4),
            Segment(slot: 1, start: 10, end: 14),
        ]
        let slots = SpeakerAttribution.attribute(
            utterances: [(5, 6)], to: segments)
        #expect(slots == [0])
    }

    @Test func equidistantNearestSegmentsTieToLowerSlotRegardlessOfOrder() {
        // Utterance [10,11] sits 1s from both a slot-0 segment ending at 9 and
        // a slot-1 segment starting at 12. The result must be deterministic
        // (lower slot), not dependent on the order segments are listed in.
        let a = Segment(slot: 0, start: 5, end: 9)
        let b = Segment(slot: 1, start: 12, end: 16)
        #expect(SpeakerAttribution.attribute(utterances: [(10, 11)], to: [a, b]) == [0])
        #expect(SpeakerAttribution.attribute(utterances: [(10, 11)], to: [b, a]) == [0])
    }

    @Test func utteranceFarFromAnySegmentStaysUnattributed() {
        let segments = [Segment(slot: 0, start: 0, end: 4)]
        let slots = SpeakerAttribution.attribute(
            utterances: [(20, 22)], to: segments)
        #expect(slots == [nil])
    }

    @Test func noSegmentsLeavesEverythingUnattributed() {
        let slots = SpeakerAttribution.attribute(
            utterances: [(0, 5), (5, 10)], to: [])
        #expect(slots == [nil, nil])
    }
}
