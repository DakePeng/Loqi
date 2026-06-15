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

    func systemPrompt(direction: LanguagePair) -> String {
        """
        You are an expert \(direction.source.promptName)-to-\(direction.target.promptName) interpreter. \
        Improve the draft translation of the given sentence. Preserve the meaning; \
        fix register, honorifics, pronouns, and terminology using the conversation \
        context. Output ONLY the improved \(direction.target.promptName) translation, \
        nothing else. If the draft is already good, output it unchanged.
        """
    }

    /// Parse the refinement output into the improved translation. Tolerates
    /// a leading "T:" tag (fullwidth colon too) from older prompt shapes;
    /// untagged output IS the translation. (The "S:" cleaned-source line is
    /// gone with the transcript-polish feature — the transcript is the
    /// record of what was said, not LLM material.)
    func parseRefinement(_ raw: String) -> String? {
        for line in cleanResponse(raw).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = tagged(trimmed, "T") {
                return value
            }
        }
        let whole = cleanResponse(raw)
        return whole.isEmpty ? nil : whole
    }

    /// Match a tagged line (`H: value`), tolerant of the decorations small
    /// models wrap them in: leading bullets/numbering/markdown headers,
    /// `**bold**` around the tag or value, a space before the colon, and a
    /// lowercased tag letter. Returns the value, or nil if the line isn't
    /// this tag. The colon must follow the tag letter with only spaces
    /// between, so prose that merely starts with the tag letter ("Here are
    /// the notes:") never false-matches.
    private func tagged(_ line: String, _ tag: String) -> String? {
        let cleaned = Self.stripLineDecorations(line)
        guard let first = cleaned.first,
              String(first).caseInsensitiveCompare(tag) == .orderedSame
        else { return nil }
        var rest = cleaned.dropFirst()
        while rest.first == " " { rest = rest.dropFirst() }   // tolerate "F :"
        guard let colon = rest.first, colon == ":" || colon == "：" else { return nil }
        let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Strip the formatting small models add around tagged lines so the tag
    /// is exposed: paired `**bold**` anywhere, and leading markdown headers,
    /// bullets, and list numbering. Conservative — only known markers are
    /// removed, and only as a prefix; a line that isn't a tag survives the
    /// attempt unchanged downstream because it simply fails the tag match.
    static func stripLineDecorations(_ line: String) -> String {
        var text = line
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        var stripping = true
        while stripping {
            stripping = false
            for marker in ["###", "##", "#", "•", "‣", "·", "–", "—", "-", "*"]
            where text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
                stripping = true
                break
            }
            if let denumbered = Self.strippedLeadingNumber(text) {
                text = denumbered
                stripping = true
            }
        }
        return text
    }

    /// Remove a leading list number ("1." / "2)") when present, else nil.
    /// A bare number followed by a space (a year, a count) is left alone.
    private static func strippedLeadingNumber(_ text: String) -> String? {
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber {
            index = text.index(after: index)
        }
        guard index > text.startIndex, index < text.endIndex,
              text[index] == "." || text[index] == ")" else { return nil }
        return String(text[text.index(after: index)...])
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Hotword restore (the only LLM touch on transcript text)

    /// Vocabulary-targeted source correction. General LLM "polishing" of
    /// transcripts was removed as unhelpful; what remains is strictly
    /// scoped: replace misrecognized occurrences of the user's terms,
    /// change nothing else.
    func hotwordRestoreSystemPrompt(
        vocabulary: [String], language: AppLanguage
    ) -> String {
        """
        A speech-recognition transcript in \(language.promptName) may contain \
        misrecognized versions of these vocabulary terms:
        \(vocabulary.joined(separator: "\n"))
        If a word or phrase in the sentence is clearly a misrecognition of one \
        of these terms, replace it with the term. Change NOTHING else — keep \
        the wording, punctuation, and meaning exactly as given. If no term is \
        misrecognized, output the sentence unchanged.
        Output exactly one line and nothing else:
        S: <sentence>
        """
    }

    /// Parse the restored sentence ("S:" tagged, fullwidth colon tolerated;
    /// untagged output is taken whole).
    func parseRestoredSentence(_ raw: String) -> String? {
        for line in cleanResponse(raw).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = tagged(trimmed, "S") {
                return value
            }
        }
        let whole = cleanResponse(raw)
        return whole.isEmpty ? nil : whole
    }

    /// Fidelity gate for the restore: a sentence that diverges beyond a
    /// term swap is a false record — worse than a misheard true one.
    func isAcceptableHotwordRestore(_ restored: String, original: String) -> Bool {
        guard !restored.isEmpty, !Self.hasDegenerateRepetition(restored) else { return false }
        let ratio = Double(restored.count) / Double(max(original.count, 1))
        guard ratio >= 0.5, ratio <= 1.6 else { return false }
        return HotwordMatcher.similarity(
            Self.comparisonForm(restored), Self.comparisonForm(original)) >= 0.55
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

    /// Map phase of map-reduce summarization: narrow tagged extraction from
    /// one transcript chunk — the task shape small models are good at.
    /// `vocabulary` carries hotwords plausibly present in the chunk
    /// (`HotwordMatcher.noteGlossaryLines`) so notes preserve the correct
    /// spellings of names and terms the recognizer tends to mangle.
    func chunkNotePrompt(
        chunkText: String, vocabulary: [String] = [], in language: AppLanguage
    ) -> (system: String, user: String) {
        let system = "You extract notes from a meeting/conversation "
            + "transcript excerpt. Write in \(language.promptName). "
            + "Plain text, no markdown. Output ONLY tagged lines: "
            + "first exactly one \"H: <headline of at most 10 words>\", "
            + "then at most 12 lines from: \"F: <key fact>\", "
            + "\"D: <decision>\", \"A: <action item with who>\", "
            + "\"T: <name or special term>\". Copy names, numbers, dates, "
            + "and amounts exactly as they appear in the excerpt. Do not "
            + "add anything that is not in the excerpt. "
            + (vocabulary.isEmpty ? "" :
                "The excerpt is a speech-recognition transcript and may "
                + "contain recognition errors; when a word looks like a "
                + "mis-hearing of one of the known terms, use the known "
                + "term. ")
            + "Skip categories with nothing to report. No other text."
        let terms = vocabulary.isEmpty
            ? "" : "Known terms: " + vocabulary.joined(separator: "; ") + "\n"
        return (system, terms + "Excerpt:\n\(chunkText)")
    }

    struct ParsedChunkNote {
        var headline: String?
        var facts: [String] = []
        var decisions: [String] = []
        var actions: [String] = []
        var terms: [String] = []

        /// A fully empty parse means the generation failed or answered
        /// off-format — the resulting note is a fallback stub.
        var isEmpty: Bool {
            headline == nil && facts.isEmpty && decisions.isEmpty
                && actions.isEmpty && terms.isEmpty
        }
    }

    func parseChunkNote(_ raw: String) -> ParsedChunkNote {
        var note = ParsedChunkNote()
        for line in cleanResponse(raw).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !Self.hasDegenerateRepetition(trimmed) else { continue }
            if let value = tagged(trimmed, "H") {
                note.headline = note.headline ?? value
            } else if let value = tagged(trimmed, "F"), note.facts.count < 8 {
                note.facts.append(value)
            } else if let value = tagged(trimmed, "D"), note.decisions.count < 8 {
                note.decisions.append(value)
            } else if let value = tagged(trimmed, "A"), note.actions.count < 8 {
                note.actions.append(value)
            } else if let value = tagged(trimmed, "T"), note.terms.count < 8 {
                note.terms.append(value)
            }
        }
        return note
    }

    /// Reduce phase: the model sees only the per-chunk notes — never the
    /// raw transcript — keeping the input inside a small model's competence.
    /// Tagged-line output (the shape small models handle reliably) assembled
    /// from the style's spec; `renderSummaryMarkdown` synthesizes the stored
    /// markdown from it. The grounding sentences exist because the reduce
    /// has no transcript to check against: anything it invents is
    /// unfalsifiable downstream. The exact meeting bytes are pinned by test.
    func reduceSummaryPrompt(
        notes: String,
        style: SummaryStyle = .meeting,
        in language: AppLanguage,
        sizing: SummaryPromptSizing? = nil
    ) -> (system: String, user: String) {
        let spec = style.spec
        let overviewCap = sizing?.overviewCap ?? spec.overviewCap
        let sectionClauses = spec.sections.enumerated()
            .map { index, section in
                let cap = sizing?.sectionCaps[safe: index] ?? section.cap
                return "up to \(cap) lines \"\(section.tag): <\(section.hint)>\""
            }
            .joined(separator: ", ")
        let system = "\(spec.task) Write entirely in \(language.promptName). "
            + "Plain text, no markdown. Output ONLY tagged lines: "
            + "first 1-\(overviewCap) lines \"O: <\(spec.overviewHint)>\", "
            + "then \(sectionClauses). Use only information from the notes; "
            + "never invent names, numbers, or events. Keep names, numbers, "
            + "and dates exactly as written in the notes. "
            + "Skip categories with nothing to report. "
            + "Merge duplicates. No other text."
        return (system, "Notes:\n\(notes)")
    }

    /// One stitched section of a detailed summary, written from the notes
    /// of a few consecutive chunks. Detailed summaries are assembled from
    /// these per-segment generations after the global reduce — each call
    /// stays small while the assembled document scales with the recording.
    func segmentSectionPrompt(
        notes: String, in language: AppLanguage
    ) -> (system: String, user: String) {
        let system = """
        You write one section of a detailed summary of a recording, \
        covering one part of it. Write entirely in \(language.promptName). \
        Plain text, no markdown. Output ONLY tagged lines: first exactly \
        one "H: <section heading of at most 8 words>", then 2-6 lines \
        "P: <specific point; keep names, numbers, and reasons>". \
        Use only information from the notes; never invent names, numbers, \
        or events. Merge duplicates. No other text.
        """
        return (system, "Notes:\n\(notes)")
    }

    struct ParsedSegmentSection {
        var headline: String?
        var points: [String] = []
    }

    /// Parse a segment section's tagged lines. Duplicate points are dropped
    /// (small models repeat themselves); an off-format response parses to
    /// empty points so the caller can fall back to the raw note lines.
    func parseSegmentSection(_ raw: String) -> ParsedSegmentSection {
        var section = ParsedSegmentSection()
        var seen = Set<String>()
        for line in cleanResponse(raw).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !Self.hasDegenerateRepetition(trimmed) else { continue }
            if let value = tagged(trimmed, "H") {
                section.headline = section.headline ?? value
            } else if let value = tagged(trimmed, "P"),
                      section.points.count < SummaryEngine.detailSectionPointCap,
                      seen.insert(value).inserted {
                section.points.append(value)
            }
        }
        return section
    }

    struct ParsedStructuredSummary {
        let style: SummaryStyle
        var overview: [String] = []
        /// One bucket per spec section, parallel to `style.spec.sections`.
        var sections: [[String]]

        init(style: SummaryStyle = .meeting) {
            self.style = style
            sections = Array(repeating: [], count: style.spec.sections.count)
        }

        var isEmpty: Bool {
            overview.isEmpty && sections.allSatisfy(\.isEmpty)
        }

        /// All content with no markdown scaffolding — what repetition
        /// validation should look at.
        var joinedValues: String {
            (overview + sections.flatMap { $0 }).joined(separator: "\n")
        }

        /// Items of the section with this tag.
        func items(_ tag: String) -> [String] {
            guard let index = style.spec.sections.firstIndex(where: { $0.tag == tag })
            else { return [] }
            return sections[index]
        }
    }

    /// Parse the reduce model's tagged lines against the style's spec.
    /// Lines that don't parse (or degenerate into repetition) are dropped;
    /// an entirely untagged response returns `.isEmpty` so the caller can
    /// fall back to plain text.
    func parseStructuredSummary(
        _ raw: String,
        style: SummaryStyle = .meeting,
        sizing: SummaryPromptSizing? = nil
    ) -> ParsedStructuredSummary {
        let spec = style.spec
        let overviewCap = sizing?.overviewCap ?? spec.overviewCap
        var summary = ParsedStructuredSummary(style: style)
        for line in cleanResponse(raw).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "##", with: "")
            guard !Self.hasDegenerateRepetition(trimmed) else { continue }
            if let value = tagged(trimmed, "O"), summary.overview.count < overviewCap {
                summary.overview.append(value)
                continue
            }
            for (index, section) in spec.sections.enumerated() {
                let cap = sizing?.sectionCaps[safe: index] ?? section.cap
                if let value = tagged(trimmed, section.tag),
                   summary.sections[index].count < cap {
                    summary.sections[index].append(value)
                    break
                }
            }
        }
        return summary
    }

    /// Deterministic markdown synthesis: overview paragraph, then one
    /// "## Heading" + "- " bullet section per non-empty category. Headings
    /// come from the style's spec in the summary's own language; the
    /// renderer treats any "## " line as a heading and never keys on them.
    func renderSummaryMarkdown(
        _ parsed: ParsedStructuredSummary, in language: AppLanguage
    ) -> String {
        var blocks: [String] = []
        if !parsed.overview.isEmpty {
            blocks.append(parsed.overview.joined(separator: " "))
        }
        for (section, items) in zip(parsed.style.spec.sections, parsed.sections)
        where !items.isEmpty {
            let bullets = items.map { "- \($0)" }.joined(separator: "\n")
            blocks.append("## \(section.heading(for: language))\n\(bullets)")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Summaries render in a plain Text view; stray markdown reads as
    /// literal asterisks. Strip it even if the model ignores instructions.
    func cleanSummary(_ raw: String) -> String {
        cleanResponse(raw)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "##", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Classify what kind of recording a session was, so the post-stop
    /// scenario step can pre-suggest a summary style. A one-word answer
    /// keeps a small model on rails.
    func scenarioDetectionPrompt(context: String) -> (system: String, user: String) {
        let system = """
        Classify what kind of recording these notes come from. Answer with \
        exactly one word from: meeting, memo, lecture, brainstorm, journal. \
        meeting = several people discussing or deciding; memo = one person \
        dictating notes or to-dos; lecture = one person teaching or \
        presenting; brainstorm = collecting ideas; journal = personal \
        diary-style reflection. Output the single word only.
        """
        return (system, "Notes:\n\(context)")
    }

    /// Tolerant parse of the one-word classification: first style whose
    /// rawValue appears anywhere in the response, nil when none does.
    func parseScenario(_ raw: String) -> SummaryStyle? {
        let text = cleanResponse(raw).lowercased()
        return SummaryStyle.allCases.first { text.contains($0.rawValue) }
    }

    /// One short list-row title for a saved session, generated right after
    /// the summary while the model is hot.
    func titlePrompt(
        context: String, in language: AppLanguage
    ) -> (system: String, user: String) {
        let system = """
        Write one title for this recording: at most 8 words, in \
        \(language.promptName), specific to the content. No quotes, no \
        markdown, no trailing period. Output the title only.
        """
        return (system, "Notes:\n\(context)")
    }

    /// Title responses must be a single usable line; anything degenerate,
    /// empty, or runaway parses to nil and the caller keeps its fallback.
    func parseTitle(_ raw: String) -> String? {
        guard var title = cleanResponse(raw)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        // Strip markdown headers/bullets and stray quotes the small model
        // sometimes adds despite instructions.
        while let first = title.first, "#-*•\"“”'「」".contains(first) {
            title.removeFirst()
        }
        while let last = title.last, "\"“”'「」.。".contains(last) {
            title.removeLast()
        }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !Self.hasDegenerateRepetition(title) else { return nil }
        if title.count > 60 { title = String(title.prefix(60)) }
        return title
    }

    /// Describe an attached photo for the notes pipeline (vision tier).
    /// Text-heavy images should come back as their key text — that's what
    /// the summary and chat ground on.
    func imageDescriptionPrompt(in language: AppLanguage) -> (system: String, user: String) {
        let system = """
        You describe a photo attached to someone's meeting or lecture \
        notes. Write in \(language.promptName). If the image is mostly text \
        (slide, whiteboard, document), transcribe its key text. Otherwise \
        describe what it shows. At most 4 short lines. Plain text, no \
        markdown, no preamble.
        """
        return (system, "Describe the attached image for the notes.")
    }

    /// How many suggestions one transcript may yield: a short note offers
    /// little worth learning, an hour-long meeting more — but the inbox
    /// must never flood, so the budget tops out regardless of length.
    static func suggestionBudget(transcriptLength: Int) -> Int {
        max(3, min(8, 3 + transcriptLength / 2000))
    }

    /// Mine a transcript for names/terms worth adding as hotwords.
    /// Output format is parsed by `parseHotwordSuggestions`; pass the same
    /// `limit` to both — small models treat the count as a quota to fill,
    /// so the parser has to enforce it.
    func hotwordSuggestionPrompt(
        transcript: String, limit: Int = 8
    ) -> (system: String, user: String) {
        let system = """
        Find terms in the transcript that a speech recognizer likely got \
        wrong or will get wrong: person names, company/product names, and \
        domain jargon with unusual spelling or pronunciation. Only include \
        a term if a recognizer could plausibly confuse or garble it. Skip \
        everyday words, famous names, brands and places every recognizer \
        already knows, numbers, and anything longer than a few words. \
        Fewer is better — if nothing qualifies, output nothing. \
        Output at most \(limit) lines, each exactly: \
        term | short note (e.g. person name). Output nothing else.
        """
        return (system, "Transcript:\n\(transcript)")
    }

    /// Mine the text a user typed while correcting a summary for vocabulary
    /// worth remembering. Output format is parsed by
    /// `parseHotwordSuggestions`; an empty or off-format response parses to
    /// no suggestions, so the prompt needs no "output none" escape clause.
    func summaryEditMiningPrompt(insertedSpans: [String]) -> (system: String, user: String) {
        let system = """
        A user fixed an auto-generated meeting summary; the lines below are \
        exactly what they typed in. Pick out only terms a speech recognizer \
        should learn because it could confuse or garble them: person names, \
        company/product names, domain jargon with unusual spelling or \
        pronunciation. Skip everyday words, famous names and brands, grammar \
        fixes, and rephrasings. Fewer is better — if nothing qualifies, \
        output nothing. Output at most 5 lines, each exactly: \
        term | short note (e.g. person name). Output nothing else.
        """
        let lines = insertedSpans
            .map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\n")
        return (system, "Typed corrections:\n\(String(lines.prefix(1500)))")
    }

    func parseHotwordSuggestions(
        _ raw: String, limit: Int = 8
    ) -> [(term: String, note: String)] {
        // Small models repeat themselves; dedupe or SwiftUI gets duplicate
        // ForEach identities downstream.
        var seen = Set<String>()
        let parsed: [(term: String, note: String)] = cleanResponse(raw)
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard let first = parts.first else { return nil }
                let term = first.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•*1234567890. "))
                guard !term.isEmpty, term.count <= 40,
                      // Numbers and long phrases aren't vocabulary, however
                      // confidently the model lists them.
                      term.rangeOfCharacter(from: .letters) != nil,
                      term.split(separator: " ").count <= 4,
                      seen.insert(term.lowercased()).inserted else { return nil }
                let note = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                return (term, note)
            }
        return Array(parsed.prefix(limit))
    }

    /// Q&A over one saved session ("chat with a session"). The context —
    /// chunk-note outline, matching bullets, keyword-matched transcript
    /// lines — is assembled by ChatEngine; this only shapes the prompt.
    /// The output language is named explicitly (the house pattern): small
    /// models follow that far more reliably than "answer in the question's
    /// language".
    func qaPrompt(
        question: String,
        context: String,
        history: [(question: String, answer: String)],
        in language: AppLanguage
    ) -> (system: String, user: String) {
        let system = """
        You answer questions about a recorded conversation using ONLY the \
        provided notes and transcript excerpts. Write entirely in \
        \(language.promptName). Be concise: at most 4 short sentences, or up \
        to 4 lines starting with "- ". If the notes do not contain the \
        answer, say so briefly. Plain text, no markdown headings.
        """

        var historyBlocks = history.map { "Q: \($0.question)\nA: \($0.answer)" }
        let request = "Question: \(question)"

        func assembled() -> String {
            let earlier = historyBlocks.isEmpty
                ? ""
                : "Earlier Q&A:\n" + historyBlocks.joined(separator: "\n") + "\n\n"
            return "Notes and excerpts:\n\(context)\n\n" + earlier + request
        }
        // Trim oldest exchanges first; the context block never trims — it
        // was budgeted by ChatEngine and grounds the answer.
        while assembled().count > qaMaxPromptCharacters, !historyBlocks.isEmpty {
            historyBlocks.removeFirst()
        }
        return (system, assembled())
    }

    /// Q&A prompt budget: context (~2800) + history headroom.
    var qaMaxPromptCharacters: Int { 3600 }

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

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
