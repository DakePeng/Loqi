import Foundation

/// Streaming version of `SummaryEngine.chunkEntries`: accumulates finalized
/// entries during a live session and closes a chunk on the same boundaries
/// (budget, speaker change once mostly full, long pause). Closing on the
/// pause itself — rather than when the next entry arrives — means the chunk
/// note generates during the very silence gap that ended it.
struct LiveChunker: Sendable {
    var budget: Int
    var gap: TimeInterval

    init(budget: Int = SummaryEngine.chunkBudget,
         gap: TimeInterval = SummaryEngine.chunkGap) {
        self.budget = budget
        self.gap = gap
    }

    private var current: [CaptionEntry] = []
    private var currentSize = 0

    /// Add a finalized entry; returns a closed chunk when a boundary was
    /// crossed BEFORE this entry (the entry starts the next chunk).
    mutating func append(_ entry: CaptionEntry) -> [CaptionEntry]? {
        let size = entry.sourceText.count
        let pause = current.last.map {
            entry.createdAt.timeIntervalSince($0.createdAt)
        } ?? 0
        let speakerChanged = current.last.map { $0.speaker != entry.speaker } ?? false

        var closed: [CaptionEntry]?
        if !current.isEmpty,
           pause >= gap
            || currentSize + size > budget
            || (speakerChanged && currentSize > budget * 6 / 10) {
            closed = current
            current = []
            currentSize = 0
        }
        current.append(entry)
        currentSize += size
        return closed
    }

    /// Timer-driven close: a long silence ends the chunk even with no new
    /// entry arriving.
    mutating func closeForGap(now: Date = .now) -> [CaptionEntry]? {
        guard let last = current.last,
              now.timeIntervalSince(last.createdAt) >= gap,
              !current.isEmpty else { return nil }
        let closed = current
        current = []
        currentSize = 0
        return closed
    }

    /// Session end: whatever remains.
    mutating func flush() -> [CaptionEntry]? {
        guard !current.isEmpty else { return nil }
        let closed = current
        current = []
        currentSize = 0
        return closed
    }
}
