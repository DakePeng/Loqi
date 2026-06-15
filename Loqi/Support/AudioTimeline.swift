import Foundation

/// Maps wall-clock dates to positions in the session's audio file.
/// Interruptions and route changes stop the recorder while wall time keeps
/// running, so the file timeline lags wall clock by every gap; one anchor
/// per turn start (wall date ↔ seconds of audio written so far) lets entry
/// timestamps land on the right audio position regardless.
struct AudioTimeline: Sendable, Equatable {
    struct Anchor: Sendable, Equatable {
        var wall: Date
        var audio: TimeInterval
    }

    /// One per turn start, in chronological order.
    var anchors: [Anchor]

    /// Audio position for a wall-clock date: the last anchor at or before
    /// the date, plus the wall time elapsed since it. nil before the first
    /// anchor (no audio existed yet).
    ///
    /// Anchors are chronological, so this binary-searches for the last anchor
    /// with `wall <= date` rather than scanning — this is called per entry on
    /// every crash-journal snapshot, where a linear scan made the mapping
    /// O(entries × anchors).
    func offset(for date: Date) -> TimeInterval? {
        guard let first = anchors.first, first.wall <= date else { return nil }
        var low = 0
        var high = anchors.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if anchors[mid].wall <= date {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let anchor = anchors[found]
        return anchor.audio + date.timeIntervalSince(anchor.wall)
    }
}
