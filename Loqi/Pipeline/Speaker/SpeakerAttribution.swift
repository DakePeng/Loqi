import Foundation

/// Pure time-range math mapping ASR utterances onto diarization speaker
/// segments — separated from the CoreML plumbing so it's unit-testable.
enum SpeakerAttribution {
    /// One diarized stretch of speech: `slot` is a dense 0-based speaker
    /// number ordered by first appearance in the recording.
    struct Segment: Sendable, Equatable {
        var slot: Int
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Attribute each utterance to the slot whose segments overlap it the
    /// most (a speaker's run is often split across several segments, so
    /// overlap is summed per slot). ASR and diarization disagree slightly
    /// about where speech starts and ends; an utterance overlapping nothing
    /// is given the nearest segment's slot when that gap is at most
    /// `maxGap` seconds, else left unattributed (nil).
    static func attribute(
        utterances: [(start: TimeInterval, end: TimeInterval)],
        to segments: [Segment],
        maxGap: TimeInterval = 3.0
    ) -> [Int?] {
        utterances.map { utterance in
            var overlapBySlot: [Int: TimeInterval] = [:]
            var nearest: (slot: Int, gap: TimeInterval)?
            for segment in segments {
                let overlap = min(utterance.end, segment.end)
                    - max(utterance.start, segment.start)
                if overlap > 0 {
                    overlapBySlot[segment.slot, default: 0] += overlap
                } else {
                    let gap = -overlap
                    // Break gap ties by the lower slot so attribution is
                    // deterministic, not dependent on `segments` ordering
                    // (matches the overlap path's lower-key tie-break above).
                    if let current = nearest {
                        if gap < current.gap
                            || (gap == current.gap && segment.slot < current.slot) {
                            nearest = (segment.slot, gap)
                        }
                    } else {
                        nearest = (segment.slot, gap)
                    }
                }
            }
            if let best = overlapBySlot.max(by: {
                ($0.value, $1.key) < ($1.value, $0.key)
            }) {
                return best.key
            }
            if let nearest, nearest.gap <= maxGap {
                return nearest.slot
            }
            return nil
        }
    }

    /// Remap attributed slots to dense, 0-based labels in first-appearance
    /// order. Auto diarization can produce a slot whose segments never win
    /// an utterance's overlap — it then labels no entry, leaving holes in
    /// the speaker numbers (1, 3, 4, 6, … with 2 and 5 missing). Collapsing
    /// to only the slots that actually landed on an entry keeps the labels
    /// gap-free and in the order speakers first appear. Pure for testing.
    static func denselyRenumbered(_ slots: [Int?]) -> [Int?] {
        var dense: [Int: Int] = [:]
        for case let slot? in slots where dense[slot] == nil {
            dense[slot] = dense.count
        }
        return slots.map { $0.flatMap { dense[$0] } }
    }
}
