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
        let value = cleanTaggedValue(String(rest.dropFirst()))
        return value.isEmpty ? nil : value
    }

    /// Tag values are rendered directly into summaries/translations after
    /// parsing. Small hybrid models can leak XML-ish wrappers (`<summary>`,
    /// `</answer>`) despite the prompt contract; remove those from the value
    /// before it reaches any renderer.
    private func cleanTaggedValue(_ raw: String) -> String {
        Self.stripModelTags(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        while let start = text.range(
            of: "<think>", options: [.caseInsensitive]
        ) {
            if let end = text.range(
                of: "</think>",
                options: [.caseInsensitive],
                range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        // A literal special token means generation ran past its stop token;
        // everything from the first one on is junk.
        if let junk = text.range(of: "<|") {
            text = String(text[..<junk.lowerBound])
        }
        text = Self.stripModelTags(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove XML-ish tags that sometimes leak from small models. This keeps
    /// the enclosed words (`<summary>ship it</summary>` -> `ship it`) but
    /// drops standalone wrappers/control tags so the summary renderer never
    /// sees them as literal text.
    static func stripModelTags(_ text: String) -> String {
        let pattern = #"</?[A-Za-z][A-Za-z0-9_-]{0,31}(?:\s+[^<>]*)?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "")
    }

    // MARK: Session-level prompts

    /// Map-only summary extraction: the model emits compact TSV records
    /// grounded only in `target`. `context_only` can help pronouns/topic
    /// continuity, but the parser and prompt both treat it as non-source.
    func chunkRecordPrompt(
        chunkID: String,
        timeRange: String,
        contextOnly: String,
        target: String,
        vocabulary: [String] = [],
        in language: AppLanguage
    ) -> (system: String, user: String) {
        let system = """
        You are a local conversation information extractor. Write in \
        \(language.promptName). Convert only the target text into short TSV \
        records for a final summary. Do not write a complete summary. \
        Plain text only. Output ONLY TSV lines. The context_only block is \
        for understanding only; extracting records from context_only is \
        forbidden. If target continues the same topic as context_only, reuse \
        a consistent topic_title and record only information not already in \
        context_only. Use only facts explicitly present in target; never infer, \
        add, or expand. Do not add anything that is not in the target. Copy \
        names, numbers, dates, and amounts exactly. If target appears to be \
        a mis-hearing of one of the known terms, use the known-term spelling. \
        Every non-topic record must cite source_ids from target. If owner or \
        deadline is unclear, write "未明确". Keep each content field short. \
        Maximum records: 1 T, 3 P, 3 D, 3 A, 2 Q, 2 R, 3 E, 3 J. Skip empty \
        categories.

        Output formats:
        T	chunk_id	time_range	topic_title	one_line_summary
        P	chunk_id	source_ids	key_point
        D	chunk_id	source_ids	decision
        A	chunk_id	source_ids	owner	task	deadline
        Q	chunk_id	source_ids	question
        R	chunk_id	source_ids	risk
        E	chunk_id	source_ids	term
        J	chunk_id	source_ids	reflection
        """
        var blocks = [
            "chunk_id: \(chunkID)",
            "time_range: \(timeRange)",
        ]
        if !vocabulary.isEmpty {
            blocks.append("Known terms: " + vocabulary.joined(separator: "; "))
        }
        blocks.append("context_only:\n\(contextOnly)")
        blocks.append("target:\n\(target)")
        return (system, blocks.joined(separator: "\n\n"))
    }

    struct ParsedChunkNote {
        var headline: String?
        var facts: [String] = []
        var decisions: [String] = []
        var actions: [String] = []
        var terms: [String] = []
        var summaryRecords: [SessionRecord.SummaryRecord] = []

        /// A fully empty parse means the generation failed or answered
        /// off-format — the resulting note is a fallback stub.
        var isEmpty: Bool {
            headline == nil && facts.isEmpty && decisions.isEmpty
                && actions.isEmpty && terms.isEmpty && summaryRecords.isEmpty
        }
    }

    func parseSummaryRecords(
        _ raw: String,
        chunkID: String,
        validSourceIDs: [String],
        source: SessionRecord.SummaryRecord.Source,
        timestamp: Date,
        sourceLabel: String? = nil
    ) -> [SessionRecord.SummaryRecord] {
        let valid = Set(validSourceIDs)
        let order = Dictionary(uniqueKeysWithValues: validSourceIDs.enumerated().map {
            ($0.element, $0.offset)
        })
        var counts: [String: Int] = [:]
        let caps = ["T": 1, "P": 3, "D": 3, "A": 3, "Q": 2, "R": 2, "E": 3, "J": 3]
        var records: [SessionRecord.SummaryRecord] = []

        func cleanField(_ text: String) -> String {
            Self.stripModelTags(text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func sourceIDs(from field: String) -> [String]? {
            let ids = field.split(separator: ",")
                .map { cleanField(String($0)) }
                .filter { !$0.isEmpty }
            guard !ids.isEmpty else { return nil }
            if !valid.isEmpty, ids.contains(where: { !valid.contains($0) }) {
                return nil
            }
            return ids
        }

        func sourceIndex(_ ids: [String]) -> Int {
            ids.compactMap { order[$0] }.min() ?? 0
        }

        for rawLine in cleanResponse(raw).split(separator: "\n") {
            let line = Self.stripLineDecorations(String(rawLine))
            let parts = line.split(
                separator: "\t", omittingEmptySubsequences: false
            ).map { cleanField(String($0)) }
            guard let tag = parts.first, let cap = caps[tag],
                  (counts[tag] ?? 0) < cap else { continue }

            func append(_ record: SessionRecord.SummaryRecord) {
                guard !record.text.isEmpty else { return }
                records.append(record)
                counts[tag, default: 0] += 1
            }

            switch tag {
            case "T":
                guard parts.count == 5, parts[1] == chunkID else { continue }
                append(.init(
                    kind: .topic,
                    source: source,
                    sourceIDs: validSourceIDs,
                    sourceIndex: 0,
                    timestamp: timestamp,
                    text: parts[4],
                    topicTitle: parts[3],
                    timeRange: parts[2],
                    sourceLabel: sourceLabel))
            case "P", "D", "Q", "R", "E", "J":
                guard parts.count == 4, parts[1] == chunkID,
                      let ids = sourceIDs(from: parts[2]) else { continue }
                let kind: SessionRecord.SummaryRecord.Kind = switch tag {
                case "P": .point
                case "D": .decision
                case "Q": .question
                case "R": .risk
                case "E": .term
                default: .reflection
                }
                append(.init(
                    kind: kind,
                    source: source,
                    sourceIDs: ids,
                    sourceIndex: sourceIndex(ids),
                    timestamp: timestamp,
                    text: parts[3],
                    sourceLabel: sourceLabel))
            case "A":
                guard parts.count == 6, parts[1] == chunkID,
                      let ids = sourceIDs(from: parts[2]) else { continue }
                append(.init(
                    kind: .action,
                    source: source,
                    sourceIDs: ids,
                    sourceIndex: sourceIndex(ids),
                    timestamp: timestamp,
                    text: parts[4],
                    owner: parts[3],
                    task: parts[4],
                    deadline: parts[5],
                    sourceLabel: sourceLabel))
            default:
                continue
            }
        }
        return records
    }

    func parsedChunkNote(
        records: [SessionRecord.SummaryRecord]
    ) -> ParsedChunkNote {
        var note = ParsedChunkNote()
        note.summaryRecords = records
        note.headline = records.first(where: { $0.kind == .topic })?.topicTitle
            ?? records.first(where: { $0.kind == .topic })?.text
        note.facts = records.filter {
            $0.kind == .point || $0.kind == .question || $0.kind == .risk
                || $0.kind == .reflection
        }.map(\.text)
        note.decisions = records.filter { $0.kind == .decision }.map(\.text)
        note.actions = records.filter { $0.kind == .action }.map {
            let owner = $0.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let deadline = $0.deadline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var parts: [String] = []
            if !owner.isEmpty { parts.append(owner) }
            parts.append($0.text)
            if !deadline.isEmpty { parts.append(deadline) }
            return parts.joined(separator: " ")
        }
        note.terms = records.filter { $0.kind == .term }.map(\.text)
        return note
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
    func imageDescriptionPrompt(
        in language: AppLanguage, context: String = ""
    ) -> (system: String, user: String) {
        let system = """
        You caption a photo attached to someone's meeting or lecture notes. \
        Write in \(language.promptName). Reply with ONE concise sentence \
        (at most 30 words) stating what the photo shows; if it is mostly \
        text (slide, whiteboard, document), state its key point instead. \
        No lists, no markdown, no headings, no preamble, and no commentary \
        about relevance — output only the sentence.
        """
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = trimmed.isEmpty
            ? "Describe the attached image in one sentence."
            : "Context, for disambiguation only — do not mention it: \(trimmed)\n"
                + "Describe the attached image in one sentence."
        return (system, user)
    }

    /// Description text fit for inline notes: `cleanResponse` plus markdown
    /// and list scaffolding flattened to one plain line. Small VLMs ignore
    /// "no markdown" and emit "1. **Heading**: …" — strip it so neither the
    /// viewer nor the (deterministic) summary shows raw markup.
    func plainDescription(_ raw: String) -> String {
        cleanResponse(raw)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                String(line)
                    // leading list/heading markers: "1.", "2)", "-", "•", "#"
                    .replacingOccurrences(
                        of: #"^\s*(?:[-*•#]+\s*|\d+[.)]\s*)"#,
                        with: "", options: .regularExpression)
                    // inline emphasis/code markers
                    .replacingOccurrences(
                        of: #"[*_`]{1,3}"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
        transcript: String,
        sourceLanguage: AppLanguage? = nil,
        targetLanguage: AppLanguage? = nil,
        limit: Int = 8
    ) -> (system: String, user: String) {
        let sourceClause = sourceLanguage.map {
            "The display term must be in \($0.promptName), the spoken/source language. "
        } ?? ""
        let renderingClause: String
        if let targetLanguage, targetLanguage != sourceLanguage {
            renderingClause = "When the transcript also shows a \(targetLanguage.promptName) "
                + "translation after an arrow, include that translated rendering in "
                + "the middle field; otherwise leave the middle field blank. "
        } else {
            renderingClause = "Leave the middle field blank. "
        }
        let system = """
        Find terms in the transcript that a speech recognizer likely got \
        wrong or will get wrong: person names, company/product names, and \
        domain jargon with unusual spelling or pronunciation. Only include \
        source-language terms, not their translations. \(sourceClause)\
        Include a term only if a recognizer could plausibly confuse or garble it. Skip \
        everyday words, famous names, brands and places every recognizer \
        already knows, numbers, and anything longer than a few words. \
        \(renderingClause)\
        Fewer is better — if nothing qualifies, output nothing. \
        Output at most \(limit) lines, each exactly: \
        source term | target rendering or blank | short note (e.g. person name). \
        Output nothing else.
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
        _ raw: String, limit: Int = 8, targetLanguage: AppLanguage? = nil
    ) -> [HotwordSuggestion] {
        // Small models repeat themselves; dedupe or SwiftUI gets duplicate
        // ForEach identities downstream.
        var seen = Set<String>()
        let parsed: [HotwordSuggestion] = cleanResponse(raw)
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(
                    separator: "|", maxSplits: 2,
                    omittingEmptySubsequences: false)
                guard let first = parts.first else { return nil }
                let term = first.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•*1234567890. "))
                guard !term.isEmpty, term.count <= 40,
                      // Numbers and long phrases aren't vocabulary, however
                      // confidently the model lists them.
                      term.rangeOfCharacter(from: .letters) != nil,
                      term.split(separator: " ").count <= 4,
                      // CJK has no spaces, so the word cap can't bound it —
                      // a whole spoken phrase would slip through. Names/terms
                      // are short; cap the CJK character count so sentence
                      // fragments ("找到特别离谱的路边摊") are rejected.
                      term.filter(\.isCJK).count <= 6,
                      seen.insert(term.lowercased()).inserted else { return nil }
                let rendering = parts.count > 2
                    ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                let notePart = parts.count > 2 ? parts[2] : (parts.dropFirst().first ?? "")
                let note = notePart.trimmingCharacters(in: .whitespaces)
                var renderings: [AppLanguage: String] = [:]
                if let targetLanguage,
                   !rendering.isEmpty,
                   rendering.caseInsensitiveCompare(term) != .orderedSame {
                    renderings[targetLanguage] = rendering
                }
                return HotwordSuggestion(
                    term: term, renderings: renderings, note: note)
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
