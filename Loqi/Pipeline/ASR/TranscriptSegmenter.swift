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
