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

/// One rendered paragraph inside a segment card: consecutive finalized
/// fragments of the same sentence (VAD cuts at pauses and the 12s cap),
/// joined for DISPLAY only. Store entries and every entry id are
/// untouched — the live data path (refinement keying, journal, note
/// anchors) never sees this.
struct CaptionRun: Identifiable, Equatable {
    /// First fragment's id — stable across updates, and identical to the
    /// segment id for the first run (scroll anchoring keeps resolving).
    let id: UUID
    var entries: [CaptionEntry]

    /// Folded pseudo-entry for CaptionRow: joined source text, joined
    /// available translations (nil while none exist), `.refining` while
    /// any fragment refines, `.refined` only when all are.
    var displayEntry: CaptionEntry {
        guard entries.count > 1, let first = entries.first else {
            return entries.first ?? CaptionEntry(
                direction: LanguagePair(source: .english, target: .english))
        }
        var folded = first
        for entry in entries.dropFirst() {
            folded.sourceText += UtteranceMerger.joiner(
                between: folded.sourceText, and: entry.sourceText) + entry.sourceText
        }
        let translations = entries.compactMap(\.displayTranslation)
        folded.refinedTranslation = nil
        folded.draftTranslation = translations.isEmpty
            ? nil
            : translations.dropFirst().reduce(translations[0]) {
                $0 + UtteranceMerger.joiner(between: $0, and: $1) + $1
            }
        if entries.contains(where: { $0.state == .refining }) {
            folded.state = .refining
        } else if entries.allSatisfy({ $0.state == .refined }) {
            folded.state = .refined
        } else {
            folded.state = .finalized
        }
        // Unavailable-translation notice only when nothing translated at
        // all and some fragment actually failed.
        folded.draftFailed = translations.isEmpty
            && entries.contains(where: \.draftFailed)
        return folded
    }
}

enum CaptionRunGrouping {
    /// createdAt is FINALIZE time, so consecutive finals are separated by
    /// the next fragment's whole duration (pause + up-to-12s of speech),
    /// not the audio gap. Punctuation is the real join signal; this gap
    /// only mirrors the card-grouping bound so a run can't span a lull
    /// the card itself would have split on.
    static let defaultJoinGap: TimeInterval = CaptionGrouping.defaultGap

    /// An entry joins the previous run when: neither it nor the previous
    /// entry is volatile, neither is `lastEntryID` (the live entry always
    /// renders alone — big-type styling and follow anchoring stay
    /// per-entry), the previous fragment's text lacks terminal
    /// punctuation, and the createdAt gap is ≤ `joinGap`.
    static func runs(
        entries: [CaptionEntry],
        lastEntryID: UUID?,
        joinGap: TimeInterval = defaultJoinGap
    ) -> [CaptionRun] {
        var runs: [CaptionRun] = []
        for entry in entries {
            if var last = runs.last,
               let previous = last.entries.last,
               previous.state != .volatile,
               entry.state != .volatile,
               previous.id != lastEntryID,
               entry.id != lastEntryID,
               !UtteranceMerger.endsSentence(previous.sourceText),
               entry.createdAt.timeIntervalSince(previous.createdAt) <= joinGap {
                last.entries.append(entry)
                runs[runs.count - 1] = last
            } else {
                runs.append(CaptionRun(id: entry.id, entries: [entry]))
            }
        }
        return runs
    }
}
