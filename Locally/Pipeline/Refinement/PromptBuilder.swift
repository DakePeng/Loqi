import Foundation

/// Builds the refinement prompt. The LLM *edits* the tier-1 draft rather
/// than translating from scratch: outputs are shorter and more stable, and
/// "draft is already good" is a cheap no-op.
///
/// Pure logic — unit-testable without MLX or a device.
struct PromptBuilder: Sendable {
    /// Rolling history turns included for context (register, honorifics,
    /// pronouns, topic continuity).
    var historyLimit = 6
    /// Rough prompt budget; history is trimmed oldest-first to stay under.
    var maxPromptCharacters = 2200

    struct HistoryTurn: Sendable {
        var sourceLanguage: AppLanguage
        var sourceText: String
        var translation: String
    }

    func systemPrompt(direction: LanguagePair, cleanSource: Bool = false) -> String {
        if cleanSource {
            return """
            You are an expert \(direction.source.promptName)-to-\(direction.target.promptName) interpreter \
            working from speech-recognition transcripts. Given a transcript sentence and a draft translation:
            1. Lightly clean the transcript: fix obvious recognition errors and punctuation. \
            Keep the speaker's wording and meaning; when unsure, keep it unchanged.
            2. Improve the draft translation using the conversation context and glossary; \
            fix register, honorifics, pronouns, and terminology.
            Output exactly two lines and nothing else:
            S: <cleaned \(direction.source.promptName) sentence>
            T: <improved \(direction.target.promptName) translation>
            """
        }
        return """
        You are an expert \(direction.source.promptName)-to-\(direction.target.promptName) interpreter. \
        Improve the draft translation of the given sentence. Preserve the meaning; \
        fix register, honorifics, pronouns, and terminology using the conversation \
        context. Output ONLY the improved \(direction.target.promptName) translation, \
        nothing else. If the draft is already good, output it unchanged.
        """
    }

    /// Transcribe-only sessions still get LLM cleanup of the transcript,
    /// just with no translation to produce.
    func polishSystemPrompt(language: AppLanguage) -> String {
        """
        You clean up speech-recognition transcripts in \(language.promptName). \
        Fix obvious recognition errors and punctuation. Keep the speaker's \
        wording and meaning; when unsure, keep it unchanged. \
        Output exactly one line and nothing else:
        S: <cleaned sentence>
        """
    }

    /// Parse the two-line refinement output. Tolerates fullwidth colons and
    /// missing tags (untagged output is treated as the translation, so the
    /// single-line prompt remains compatible).
    func parseRefinement(_ raw: String) -> (cleanedSource: String?, translation: String?) {
        var source: String?
        var translation: String?
        for line in cleanResponse(raw).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = tagged(trimmed, "S") {
                source = source ?? value
            } else if let value = tagged(trimmed, "T") {
                translation = translation ?? value
            }
        }
        if source == nil, translation == nil {
            let whole = cleanResponse(raw)
            return (nil, whole.isEmpty ? nil : whole)
        }
        return (source, translation)
    }

    private func tagged(_ line: String, _ tag: String) -> String? {
        for prefix in ["\(tag):", "\(tag)："] where line.hasPrefix(prefix) {
            let value = line.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Fidelity gate for transcript polishing: a cleaned transcript that
    /// diverges too far from what was actually said is a false record —
    /// worse than a messy true one.
    func isAcceptableSourceCleanup(_ cleaned: String, original: String) -> Bool {
        guard !cleaned.isEmpty, !Self.hasDegenerateRepetition(cleaned) else { return false }
        let ratio = Double(cleaned.count) / Double(max(original.count, 1))
        guard ratio >= 0.5, ratio <= 1.6 else { return false }
        return HotwordMatcher.similarity(
            Self.comparisonForm(cleaned), Self.comparisonForm(original)) >= 0.55
    }

    private static func comparisonForm(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    func userPrompt(
        source: String,
        draft: String,
        direction: LanguagePair,
        history: [HistoryTurn],
        glossary: [String] = []
    ) -> String {
        var historyLines = history.suffix(historyLimit).map { turn in
            "[\(turn.sourceLanguage.promptName)] \(turn.sourceText) → \(turn.translation)"
        }

        // Glossary outranks history: it never gets trimmed.
        let glossaryBlock = glossary.isEmpty
            ? ""
            : "Glossary — the sentence may contain mis-transcriptions of these "
                + "terms; restore them and use these exact renderings:\n"
                + glossary.joined(separator: "\n") + "\n\n"

        let request = """
        Sentence (\(direction.source.promptName)): \(source)
        Draft (\(direction.target.promptName)): \(draft)
        """

        // Trim oldest history until the prompt fits the budget.
        func assembled() -> String {
            let context = historyLines.isEmpty
                ? ""
                : "Conversation so far:\n" + historyLines.joined(separator: "\n") + "\n\n"
            return glossaryBlock + context + request
        }
        while assembled().count > maxPromptCharacters, !historyLines.isEmpty {
            historyLines.removeFirst()
        }
        return assembled()
    }

    /// Defensive cleanup: strip any thinking block the chat template let
    /// through, surrounding quotes, and label prefixes the model might add.
    func cleanResponse(_ raw: String) -> String {
        var text = raw
        if let start = text.range(of: "<think>"),
           let end = text.range(of: "</think>") {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // A literal special token means generation ran past its stop token;
        // everything from the first one on is junk.
        if let junk = text.range(of: "<|") {
            text = String(text[..<junk.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Session-level prompts

    /// Summarize a finished session in the reader's language.
    func summaryPrompt(transcript: String, in language: AppLanguage) -> (system: String, user: String) {
        let system = """
        You summarize meeting/conversation transcripts. Write entirely in \
        \(language.promptName). PLAIN TEXT ONLY: no markdown, no asterisks, \
        no headings. Output a 2-4 sentence summary paragraph, then up to 5 \
        lines each starting with "• " containing key facts, decisions, or \
        action items. Refer to speakers by their labels once, without \
        repeating the label in parentheses. Be concrete. No preamble.
        """
        return (system, "Transcript:\n\(transcript)")
    }

    /// Map phase of map-reduce summarization: narrow tagged extraction from
    /// one transcript chunk — the task shape small models are good at.
    func chunkNotePrompt(
        chunkText: String, in language: AppLanguage
    ) -> (system: String, user: String) {
        let system = """
        You extract notes from a meeting/conversation transcript excerpt. \
        Write in \(language.promptName). Plain text, no markdown. Output ONLY \
        tagged lines: first exactly one "H: <headline of at most 10 words>", \
        then at most 6 lines from: "F: <key fact>", "D: <decision>", \
        "A: <action item with who>", "T: <name or special term>". \
        Skip categories with nothing to report. No other text.
        """
        return (system, "Excerpt:\n\(chunkText)")
    }

    struct ParsedChunkNote {
        var headline: String?
        var facts: [String] = []
        var decisions: [String] = []
        var actions: [String] = []
        var terms: [String] = []
    }

    func parseChunkNote(_ raw: String) -> ParsedChunkNote {
        var note = ParsedChunkNote()
        for line in cleanResponse(raw).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !Self.hasDegenerateRepetition(trimmed) else { continue }
            if let value = tagged(trimmed, "H") {
                note.headline = note.headline ?? value
            } else if let value = tagged(trimmed, "F"), note.facts.count < 4 {
                note.facts.append(value)
            } else if let value = tagged(trimmed, "D"), note.decisions.count < 4 {
                note.decisions.append(value)
            } else if let value = tagged(trimmed, "A"), note.actions.count < 4 {
                note.actions.append(value)
            } else if let value = tagged(trimmed, "T"), note.terms.count < 4 {
                note.terms.append(value)
            }
        }
        return note
    }

    /// Reduce phase: the model sees only the per-chunk notes — never the
    /// raw transcript — keeping the input inside a small model's competence.
    func reduceSummaryPrompt(
        notes: String, in language: AppLanguage
    ) -> (system: String, user: String) {
        let system = """
        You combine sectioned meeting notes into one final summary. Write \
        entirely in \(language.promptName). PLAIN TEXT ONLY: no markdown, no \
        asterisks, no headings. Output a 2-4 sentence overview paragraph, \
        then up to 6 lines each starting with "• " covering the most \
        important facts, decisions, and action items (keep who does what). \
        Merge duplicates. No preamble.
        """
        return (system, "Notes:\n\(notes)")
    }

    /// Summaries render in a plain Text view; stray markdown reads as
    /// literal asterisks. Strip it even if the model ignores instructions.
    func cleanSummary(_ raw: String) -> String {
        cleanResponse(raw)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "##", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mine a transcript for names/terms worth adding as hotwords.
    /// Output format is parsed by `parseHotwordSuggestions`.
    func hotwordSuggestionPrompt(transcript: String) -> (system: String, user: String) {
        let system = """
        Find proper nouns and special terms in the transcript that a speech \
        recognizer is likely to get wrong: person names, company/product names, \
        technical jargon. Skip common words and place names everyone knows. \
        Output up to 8 lines, each exactly: term | short note (e.g. person name). \
        Output nothing else.
        """
        return (system, "Transcript:\n\(transcript)")
    }

    func parseHotwordSuggestions(_ raw: String) -> [(term: String, note: String)] {
        // Small models repeat themselves; dedupe or SwiftUI gets duplicate
        // ForEach identities downstream.
        var seen = Set<String>()
        return cleanResponse(raw)
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard let first = parts.first else { return nil }
                let term = first.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•*1234567890. "))
                guard !term.isEmpty, term.count <= 40,
                      seen.insert(term.lowercased()).inserted else { return nil }
                let note = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                return (term, note)
            }
    }

    /// Last line of defense before a refinement replaces the visible draft.
    /// Broken weights or a derailed generation produce output that is empty,
    /// wildly longer than any plausible translation, full of replacement
    /// characters, or a degenerate repetition loop — in all those cases the
    /// NMT draft must stand.
    func isAcceptable(_ refined: String, draft: String) -> Bool {
        guard !refined.isEmpty else { return false }
        guard refined.unicodeScalars.allSatisfy({ $0 != "\u{FFFD}" }) else { return false }
        guard !Self.hasDegenerateRepetition(refined) else { return false }
        let limit = max(draft.count * 3, 120)
        return refined.count <= limit
    }

    /// Detects "this, this, this…" style generation loops, in both spaced
    /// (Latin) and unspaced (CJK) text.
    static func hasDegenerateRepetition(_ text: String) -> Bool {
        // Spaced text: one token dominating a long output.
        let words = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { !$0.isEmpty }
        if words.count >= 12 {
            var counts: [Substring: Int] = [:]
            for word in words { counts[word, default: 0] += 1 }
            if let max = counts.values.max(),
               Double(max) / Double(words.count) >= 0.4 {
                return true
            }
        }

        // Unspaced text: a short chunk repeated ≥6 times consecutively
        // ("好的好的好的好的好的好的"), at any starting offset.
        let characters = Array(text)
        guard characters.count >= 12 else { return false }
        for chunkLength in 1...6 {
            var start = 0
            while start + chunkLength * 6 <= characters.count {
                let chunk = Array(characters[start..<(start + chunkLength)])
                var repeats = 1
                var next = start + chunkLength
                while next + chunkLength <= characters.count,
                      Array(characters[next..<(next + chunkLength)]) == chunk {
                    repeats += 1
                    if repeats >= 6 { return true }
                    next += chunkLength
                }
                start += 1
            }
        }
        return false
    }
}
