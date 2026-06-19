import Foundation

/// One card per coherent stretch of speech.
struct CaptionSegment: Identifiable, Equatable {
    let id: UUID
    let speaker: Int?
    var entries: [CaptionEntry]
}

enum CaptionGrouping {
    static let defaultGap: TimeInterval = 12
    static let defaultMaxEntries = 4

    static func segments(
        from entries: [CaptionEntry],
        gap: TimeInterval = defaultGap,
        maxEntries: Int = defaultMaxEntries
    ) -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        for entry in entries {
            if var last = segments.last,
               entry.speaker == nil || entry.speaker == last.speaker,
               last.entries.count < maxEntries,
               let previous = last.entries.last,
               entry.createdAt.timeIntervalSince(previous.createdAt) < gap {
                last.entries.append(entry)
                segments[segments.count - 1] = last
            } else {
                segments.append(CaptionSegment(
                    id: entry.id,
                    speaker: entry.speaker,
                    entries: [entry]))
            }
        }
        return segments
    }
}
