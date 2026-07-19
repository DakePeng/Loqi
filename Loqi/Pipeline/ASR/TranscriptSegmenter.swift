import Foundation

/// Pure state machine between ASR events and downstream consumers.
/// Tracks the in-flight utterance, decides what tier-1 should translate
/// (debounced volatile text) and what tier-2 should refine (finalized
/// sentences worth the LLM's time).
///
/// Kept free of UI and framework types so it's unit-testable in the simulator.
struct TranscriptSegmenter: Sendable {
    struct Output: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// Update the active caption's source text and (debounced)
            /// request a draft translation.
            case volatileUpdate
            /// Freeze the caption; request a final draft translation.
            case finalized(refine: Bool)
            /// The final event carried no usable text; discard the entry.
            case discard
        }
        var kind: Kind
        var text: String
        var language: AppLanguage
        var languageWasDetected: Bool
        /// Per-word audio time ranges from the engine (Apple only), passed
        /// through on a finalized utterance so the pipeline can split it at a
        /// speaker change. nil for volatile/discard and timing-less engines.
        var timedRuns: [TimedRun]? = nil
    }

    /// Below these lengths, LLM sentence cleanup is skipped — greetings,
    /// numbers, and fragments rarely carry a mishearing worth fixing.
    var minLatinWords = 5
    var minCJKCharacters = 8

    func process(_ event: TranscriptionEvent, fallbackLanguage: AppLanguage) -> Output? {
        switch event {
        case .volatile(let text, let detectedLanguage):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSpeechContent else { return nil }
            return Output(
                kind: .volatileUpdate,
                text: trimmed,
                language: detectedLanguage ?? fallbackLanguage,
                languageWasDetected: detectedLanguage != nil)

        case .finalized(let text, let runs, let detectedLanguage):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop empty AND punctuation-only finals ("." / "。") — the ASR
            // emits those for silence/noise and they render as lone dots.
            guard trimmed.hasSpeechContent else {
                return Output(
                    kind: .discard,
                    text: "",
                    language: detectedLanguage ?? fallbackLanguage,
                    languageWasDetected: detectedLanguage != nil)
            }
            let language = detectedLanguage ?? fallbackLanguage
            let refine = isWorthRefining(trimmed, language: language)
            return Output(
                kind: .finalized(refine: refine),
                text: trimmed,
                language: language,
                languageWasDetected: detectedLanguage != nil,
                timedRuns: runs)

        case .ended, .speechActivity:
            return nil
        }
    }

    func isWorthRefining(_ text: String, language: AppLanguage) -> Bool {
        if language.usesCJKScript {
            return text.count >= minCJKCharacters
        }
        let words = text.split { $0.isWhitespace }.count
        return words >= minLatinWords
    }
}

extension StringProtocol {
    /// At least one letter or number in any script (CJK included) — used to
    /// drop ASR segments that are only punctuation or whitespace.
    var hasSpeechContent: Bool {
        contains { $0.isLetter || $0.isNumber }
    }
}

/// Reassembles VAD-fragmented ASR utterances into sentence-shaped ones:
/// silero closes segments at pauses ≥0.5s and force-splits at the 10-12s
/// caps, so raw utterances end mid-sentence. Pure; hosted here rather
/// than its own file so the xcodegen pbxproj needn't change — split out
/// on the next project regen.
enum UtteranceMerger {
    /// Structurally identical to OfflineTranscriber.Utterance.
    typealias Utterance = (text: String, start: TimeInterval, end: TimeInterval)

    /// Characters that close a sentence, CJK + Latin.
    private static let terminal: Set<Character> = ["。", "．", ".", "!", "！", "?", "？", "…"]
    /// Closers that may trail the terminal mark ("said." → «said.» etc.).
    private static let trailing: Set<Character> = [
        "」", "』", "”", "’", "\"", "'", "）", ")", "】", "》", "]", "»",
    ]

    /// True when `text` ends with terminal punctuation, tolerating
    /// trailing closing quotes/brackets and whitespace.
    static func endsSentence(_ text: String) -> Bool {
        for character in text.reversed() {
            if character.isWhitespace || trailing.contains(character) { continue }
            return terminal.contains(character)
        }
        return false
    }

    /// CJK for JOINING purposes: Han/kana plus CJK punctuation and
    /// fullwidth forms ("。」！" etc.), so sentences joined across a
    /// terminal mark don't grow an ASCII space inside zh/ja text.
    /// (`Character.isCJK` itself stays letters-only — HotwordMatcher
    /// depends on that.)
    private static func isCJKBoundary(_ character: Character) -> Bool {
        if character.isCJK { return true }
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x3000...0x303F).contains(scalar.value)   // CJK punctuation
            || (0xFF00...0xFFEF).contains(scalar.value)   // fullwidth forms
    }

    /// "" when both boundary characters are CJK (no space inside zh/ja
    /// text), else " " (Latin and Korean use real spaces).
    static func joiner(between left: String, and right: String) -> String {
        guard let last = left.last, let first = right.first,
              isCJKBoundary(last), isCJKBoundary(first) else { return " " }
        return ""
    }

    /// Append the next fragment onto the current one while the current
    /// lacks terminal punctuation AND the inter-fragment gap ≤ `maxGap`
    /// (negative gaps — overlapping retry-halves ranges — count) AND the
    /// merged span stays ≤ `maxDuration` AND the merged text stays ≤
    /// `maxCharacters` (the backstop for punctuation-less CTC backends
    /// and the LFM2.5 refine token budget). Merged start = the first
    /// fragment's, end = the last's.
    ///
    /// `maxGap` is deliberately below the VAD's minimum
    /// `minSilenceDuration` (0.5s, MicSensitivity). A segment only closes
    /// on silence OR the forced max-speech cap: silence-closed segments —
    /// which is EVERY speaker turn change (the first speaker stops, the
    /// VAD waits out its silence, the next speaker starts) — are therefore
    /// ≥0.5s apart and never merge, while a forced mid-speech cap-split
    /// leaves the same speaker continuing at a ~0s gap and still heals.
    /// This keeps a fast back-and-forth from being fused into one speaker
    /// before diarization attributes the merged span to a single slot.
    static func merge(
        _ utterances: [Utterance],
        maxGap: TimeInterval = 0.4,
        maxDuration: TimeInterval = 20,
        maxCharacters: Int = 200
    ) -> [Utterance] {
        mergeAttributed(
            utterances,
            slots: [Int?](repeating: nil, count: utterances.count),
            maxGap: maxGap, maxDuration: maxDuration, maxCharacters: maxCharacters
        ).utterances
    }

    /// Speaker-aware merge for the offline paths, run AFTER each raw
    /// utterance has been attributed to a diarization slot. Knowing the
    /// speakers removes the turn-change worry behind `merge`'s tight
    /// `maxGap`: same-slot neighbors heal across real pause-length gaps
    /// (`sameSpeakerGap`) and join even across terminal punctuation, so a
    /// speaker's consecutive sentences flow into paragraph-shaped entries
    /// up to the duration/character caps. Different slots never merge;
    /// unattributed (nil) neighbors keep the conservative rules. Returns
    /// merged utterances with their slots, index-aligned.
    static func mergeAttributed(
        _ utterances: [Utterance],
        slots: [Int?],
        sameSpeakerGap: TimeInterval = 1.2,
        maxGap: TimeInterval = 0.4,
        maxDuration: TimeInterval = 20,
        maxCharacters: Int = 200
    ) -> (utterances: [Utterance], slots: [Int?]) {
        var merged: [Utterance] = []
        var mergedSlots: [Int?] = []
        for (utterance, slot) in zip(utterances, slots) {
            guard let current = merged.last else {
                merged.append(utterance)
                mergedSlots.append(slot)
                continue
            }
            let currentSlot = mergedSlots[mergedSlots.count - 1]
            let joined = current.text
                + joiner(between: current.text, and: utterance.text)
                + utterance.text
            let gap = utterance.start - current.end
            let withinCaps = utterance.end - current.start <= maxDuration
                && joined.count <= maxCharacters
            let joins = currentSlot == slot && withinCaps
                && (currentSlot != nil
                    ? gap <= sameSpeakerGap
                    : !endsSentence(current.text) && gap <= maxGap)
            if joins {
                merged[merged.count - 1] = (joined, current.start, utterance.end)
            } else {
                merged.append(utterance)
                mergedSlots.append(slot)
            }
        }
        return (merged, mergedSlots)
    }
}
