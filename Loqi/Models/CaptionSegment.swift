import Foundation

/// One card per coherent stretch of speech.
struct CaptionSegment: Identifiable, Equatable {
    let id: UUID
    let speaker: Int?
    var entries: [CaptionEntry]
}

enum CaptionGrouping {
    /// createdAt is FINALIZE time, so in continuous speech consecutive
    /// finals are one whole segment apart (pause + up-to-20s of speech +
    /// decode). Must exceed the hybrid VAD cap or every cap-split segment
    /// starts a new card.
    static let defaultGap: TimeInterval = 30
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
/// fragments of the same stretch of speech (VAD cuts at pauses and the
/// segment cap), joined for DISPLAY only. Store entries and every entry
/// id are untouched — the live data path (refinement keying, journal,
/// note anchors) never sees this.
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

/// Flows a saved session's one-sentence entries into paragraph rows for
/// the transcript view. Display only — the record's entries are untouched,
/// so seek offsets, refinement keys, and summary anchors all keep working.
/// Mainly benefits live-recorded sessions, whose archived entries are raw
/// VAD fragments (offline passes already merge speaker-aware).
enum TranscriptParagraphs {
    static let maxCharacters = 300
    /// Start-to-start bound between entries: they carry no end time, so
    /// this delta includes the previous entry's whole duration (≤20s
    /// span) — 30s therefore means a real lull, not just a long entry.
    static let maxStartGap: TimeInterval = 30

    static func group(_ entries: [SessionRecord.Entry]) -> [[SessionRecord.Entry]] {
        var paragraphs: [[SessionRecord.Entry]] = []
        for entry in entries {
            if var last = paragraphs.last, let previous = last.last,
               entry.timestamp.timeIntervalSince(previous.timestamp) <= maxStartGap,
               last.reduce(entry.sourceText.count, { $0 + $1.sourceText.count })
                   <= maxCharacters {
                last.append(entry)
                paragraphs[paragraphs.count - 1] = last
            } else {
                paragraphs.append([entry])
            }
        }
        return paragraphs
    }

    /// CJK-aware join of the paragraph's texts.
    static func joined(_ texts: [String]) -> String {
        texts.dropFirst().reduce(texts.first ?? "") {
            $0 + UtteranceMerger.joiner(between: $0, and: $1) + $1
        }
    }
}

enum CaptionRunGrouping {
    /// createdAt is FINALIZE time, so consecutive finals are separated by
    /// the next fragment's whole duration (pause + up-to-20s of speech),
    /// not the audio gap. This gap only mirrors the card-grouping bound
    /// so a run can't span a lull the card itself would have split on.
    static let defaultJoinGap: TimeInterval = CaptionGrouping.defaultGap

    /// Paragraph budget for one run. Terminal punctuation can't gate
    /// joining here: SenseVoice punctuates aggressively (a cut fragment
    /// often reads as a finished sentence), Dolphin finals carry no
    /// punctuation at all. Sentences flow into one paragraph until the
    /// joined source text hits this budget.
    static let defaultMaxCharacters = 250

    /// An entry joins the previous run when: neither it nor the previous
    /// entry is volatile, neither is `lastEntryID` (the live entry always
    /// renders alone — big-type styling and follow anchoring stay
    /// per-entry), the joined text stays within `maxCharacters`, and the
    /// createdAt gap is ≤ `joinGap`.
    static func runs(
        entries: [CaptionEntry],
        lastEntryID: UUID?,
        joinGap: TimeInterval = defaultJoinGap,
        maxCharacters: Int = defaultMaxCharacters
    ) -> [CaptionRun] {
        var runs: [CaptionRun] = []
        for entry in entries {
            if var last = runs.last,
               let previous = last.entries.last,
               previous.state != .volatile,
               entry.state != .volatile,
               previous.id != lastEntryID,
               entry.id != lastEntryID,
               last.entries.reduce(entry.sourceText.count, { $0 + $1.sourceText.count })
                   <= maxCharacters,
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
