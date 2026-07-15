import Foundation

/// Builds the live LLM prompts. During recording the LLM *cleans the
/// source sentence* (Apple's Translation framework does all translating);
/// post-session it powers notes, summaries, and the hotword restore.
///
/// Pure logic — unit-testable without MLX or a device.
struct PromptBuilder: Sendable {
    /// Rough prompt budget; context is trimmed oldest-first to stay under.
    var maxPromptCharacters = 2200

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
    /// untagged single-line output is taken whole). Uses the sentence-safe
    /// cleaner: transcripts legitimately contain markup ("use the <title>
    /// tag") and the fidelity gate would accept its deletion, so only KNOWN
    /// model wrapper tags are stripped here — unlike `cleanResponse`.
    func parseRestoredSentence(_ raw: String) -> String? {
        for line in cleanSentenceResponse(raw).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = tagged(trimmed, "S") {
                return value
            }
        }
        // Untagged fallback. Small models sometimes prepend a preamble line
        // ("以下は…翻訳です：", "Here is the corrected sentence:") that the
        // fidelity gate accepts on long sentences — drop leading
        // colon-terminated lines. Output still spanning multiple lines
        // after that isn't the "exactly one line" the prompts demand, and
        // guessing risks a false record: reject so the caller keeps the
        // ASR original.
        var lines = cleanSentenceResponse(raw).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        while lines.count > 1, let first = lines.first,
              first.hasSuffix(":") || first.hasSuffix("：") {
            lines.removeFirst()
        }
        guard lines.count == 1 else { return nil }
        return lines[0]
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

    // MARK: Live sentence refinement (monolingual)

    /// The ONE context-window knob for sentence cleanup — the live queue,
    /// the offline polisher, and the prompt trimming all read this.
    static let refineContextLimit = 3
    /// Output ≈ input sentence; 160 gives long CJK sentences headroom
    /// (the fidelity gate rejects truncation anyway).
    static let refineMaxTokens = 160

    /// One sentence through the full cleanup contract — prompt, generate,
    /// parse, fidelity gate — shared by the live RefinementQueue and the
    /// offline polisher so the two paths can't drift.
    enum SentenceRefinement: Sendable, Equatable {
        /// Accepted AND different from the input.
        case cleaned(String)
        /// The model says the sentence has no errors.
        case unchanged
        /// Parse or fidelity-gate failure; raw output for the caller's log.
        case rejected(raw: String)
    }

    func refineSentence(
        _ sentence: String,
        language: AppLanguage,
        context: [String],
        glossary: [String],
        generate: @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String
    ) async throws -> SentenceRefinement {
        let raw = try await generate(
            sentenceRefineSystemPrompt(language: language),
            sentenceRefineUserPrompt(
                sentence: sentence, language: language,
                context: context, glossary: glossary),
            Self.refineMaxTokens)
        guard let cleaned = parseRefinedSentence(raw),
              isAcceptableSentenceRefinement(cleaned, original: sentence)
        else { return .rejected(raw: raw) }
        return cleaned == sentence ? .unchanged : .cleaned(cleaned)
    }

    /// Live transcript cleanup: the LLM fixes recognition errors in the
    /// source sentence; Apple's Translation framework re-translates the
    /// result. Monolingual by design — a task even the 230M tier can do,
    /// unlike translation refinement or structured output.
    func sentenceRefineSystemPrompt(language: AppLanguage) -> String {
        """
        You correct speech-recognition errors in a live \(language.promptName) \
        transcript. Fix only clear recognition mistakes in the sentence: misheard \
        words, homophone errors, garbled fragments, and missing or wrong \
        punctuation. Use the earlier lines and the vocabulary list to resolve \
        names and terms. Never translate, never rephrase wording that is already \
        correct, never add or remove information. If the sentence has no errors, \
        output it unchanged. Output ONLY the corrected \(language.promptName) \
        sentence, nothing else — no labels, no quotes, no explanation.
        """
    }

    func sentenceRefineUserPrompt(
        sentence: String,
        language: AppLanguage,
        context: [String],
        glossary: [String] = []
    ) -> String {
        // Glossary outranks context: it never gets trimmed.
        let glossaryBlock = glossary.isEmpty
            ? ""
            : "Vocabulary — the sentence may contain mis-transcriptions of these "
                + "terms; use these exact spellings:\n"
                + glossary.joined(separator: "\n") + "\n\n"
        var contextLines = context.suffix(Self.refineContextLimit).map { "- \($0)" }
        let request = "Sentence (\(language.promptName)): \(sentence)"
        func assembled() -> String {
            let contextBlock = contextLines.isEmpty
                ? ""
                : "Earlier lines, for context only:\n"
                    + contextLines.joined(separator: "\n") + "\n\n"
            return glossaryBlock + contextBlock + request
        }
        while assembled().count > maxPromptCharacters, !contextLines.isEmpty {
            contextLines.removeFirst()
        }
        return assembled()
    }

    /// Parse the cleaned sentence — same tolerance as the hotword restore
    /// ("S:" tagged or whole output), plus stripping the user-prompt label
    /// the model sometimes echoes ("Sentence (English): …"); on long
    /// inputs the echoed label would otherwise pass the fidelity gate and
    /// pollute the saved transcript.
    func parseRefinedSentence(_ raw: String) -> String? {
        guard let value = parseRestoredSentence(raw) else { return nil }
        let stripped = Self.strippedPromptLabelEcho(value)
        return stripped.isEmpty ? nil : stripped
    }

    static func strippedPromptLabelEcho(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"^Sentence \([A-Za-z]+\)\s*[:：]\s*"#) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "")
    }

    /// Fidelity gate: the hotword-restore checks (length ratio, similarity,
    /// repetition) plus the broken-decode check the old translation gate
    /// had. A rewrite is a false record — worse than a misheard true one.
    func isAcceptableSentenceRefinement(_ cleaned: String, original: String) -> Bool {
        guard cleaned.unicodeScalars.allSatisfy({ $0 != "\u{FFFD}" }) else { return false }
        return isAcceptableHotwordRestore(cleaned, original: original)
    }

    /// Defensive cleanup: strip any thinking block the chat template let
    /// through, surrounding quotes, and label prefixes the model might add.
    func cleanResponse(_ raw: String) -> String {
        cleaned(raw, strippingTags: Self.stripModelTags)
    }

    /// Sentence-safe variant for source-transcript output: strips only
    /// KNOWN model wrapper tags, because spoken content can legitimately
    /// contain markup ("use the <title> tag") that `stripModelTags`'s
    /// any-tag regex would silently delete.
    func cleanSentenceResponse(_ raw: String) -> String {
        cleaned(raw, strippingTags: Self.stripKnownWrapperTags)
    }

    private func cleaned(
        _ raw: String, strippingTags: (String) -> String
    ) -> String {
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
        text = strippingTags(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The wrapper tags small models actually leak around sentence output.
    private static let knownWrapperTags = #"</?(?:think|thinking|answer|response|summary|output|result)>"#

    static func stripKnownWrapperTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: knownWrapperTags, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "")
    }

    /// Content fields must read as prose: the model copies its source-id
    /// citations into the text ("m004-007 价格：80元/斤", "（m005 提及
    /// 杨梅）"), and m-ids are meaningless to users. Strip id tokens
    /// (single, comma lists, ranges) plus a directly trailing colon, then
    /// tidy emptied parentheses and doubled spaces. Grounding is
    /// unaffected — ids are captured structurally from the source_ids
    /// field. Applied at parse time AND at the reduce/render boundaries,
    /// so notes persisted before this scrub display clean too.
    static func strippedSourceIDTokens(_ text: String) -> String {
        guard text.contains("m") else { return text }
        // Swift Regex has no lookbehind: capture the preceding non-letter
        // (if any) and re-emit it, so words like "team004" stay intact.
        let idRun = /(?:^|([^A-Za-z]))m\d{2,4}(?:\s*[-–—~,，、]\s*m?\d{1,4})*\s*[:：]?\s*/
        var cleaned = text.replacing(idRun) { match in
            match.output.1.map(String.init) ?? ""
        }
        cleaned = cleaned.replacing(/[（(]\s*[)）]/, with: "")
        return cleaned.replacing(/\s{2,}/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        context_only. Use only facts explicitly present in target; never add \
        facts, names, numbers, or events that are not in the target. When the \
        target states a reason, condition, or qualifier for a point, keep that \
        clause so the point keeps its meaning. Copy \
        names, numbers, dates, and amounts exactly. If target appears to be \
        a mis-hearing of one of the known terms, use the known-term spelling. \
        Every non-topic record must cite source_ids from target. If owner or \
        deadline is unclear, write "未明确". Keep each content field to one line. \
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

        Example output (format reference only; never copy its content or ids):
        \(Self.chunkRecordExample(in: language))
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

    /// Privacy-safe accounting of why parsed lines were accepted or
    /// rejected — counts only, never content, so it is loggable (see
    /// `debugLogsDoNotExposeTranscriptText`). An all-rejected response
    /// used to stub the chunk silently; these tallies say which rule bit.
    struct ParseDiagnostics {
        var lines = 0
        var hadTabs = false
        var accepted = 0
        var unknownTag = 0
        var overCap = 0
        var specEcho = 0
        var columnCount = 0
        var chunkIDMismatch = 0
        var invalidSourceIDs = 0
        var exampleEcho = 0
        /// Records recovered by the lenient second pass (strict parse
        /// accepted nothing; near-miss shapes were re-read).
        var salvaged = 0
        /// Tag and field count of column-rejected lines (first few, e.g.
        /// "T:4" = a topic line missing one field) — says which record
        /// kinds are malformed and how, without logging any content.
        var columnsSeen: [String] = []

        var logDescription: String {
            "lines=\(lines) tabs=\(hadTabs) accepted=\(accepted) "
                + "unknownTag=\(unknownTag) columns=\(columnCount) "
                + "idMiss=\(chunkIDMismatch) badSourceIDs=\(invalidSourceIDs) "
                + "overCap=\(overCap) specEcho=\(specEcho) "
                + "exampleEcho=\(exampleEcho) salvaged=\(salvaged) "
                + "colsSeen=\(columnsSeen)"
        }
    }

    /// One-shot example for `chunkRecordPrompt` — device logs showed the
    /// 2B model answering by copying the format-spec block verbatim
    /// (specEcho=8/8), the classic failure of a bare spec with no
    /// demonstration. The example is in the note language so the model
    /// doesn't mimic its language over the session's. A verbatim copy of
    /// these lines is kept out of the records by `exampleContent` (the
    /// model borrows the example's c000 chunk id on real records too, so
    /// the id can't be the echo gate — see `acceptsChunkID`).
    static func chunkRecordExample(in language: AppLanguage) -> String {
        let f = Self.exampleFields(in: language)
        // Six lines on purpose: a 3-line example anchored the 2B to
        // emitting exactly one T/P/A per chunk (device logs) — the
        // demonstration's cardinality is imitated along with its format.
        return """
        T\tc000\t00:00-02:00\t\(f.topic)\t\(f.summary)
        P\tc000\tm001,m002\t\(f.point)
        P\tc000\tm004\t\(f.point2)
        D\tc000\tm005\t\(f.decision)
        A\tc000\tm003\t\(f.owner)\t\(f.task)\t\(f.deadline)
        Q\tc000\tm006\t\(f.question)
        """
    }

    private static func exampleFields(
        in language: AppLanguage
    ) -> (topic: String, summary: String, point: String, point2: String,
          decision: String, question: String, owner: String, task: String, deadline: String) {
        switch language {
        case .english:
            ("Budget planning", "Agreed on next quarter's budget direction",
             "Budget set at 420k", "Venue stays on the second floor",
             "Local suppliers will be used", "Whether an external audit is needed",
             "Alex", "Prepare the budget breakdown", "Friday")
        case .chinese:
            ("预算规划", "确定了下季度预算方向",
             "预算定为 42 万", "场地定在二楼",
             "决定采用本地供应商", "是否需要外部审核",
             "王经理", "准备预算明细", "周五")
        case .japanese:
            ("予算計画", "来四半期の予算方針を決定",
             "予算は42万に決定", "会場は二階に決定",
             "地元の業者を採用する", "外部監査が必要かどうか",
             "田中さん", "予算明細を準備する", "金曜日")
        case .korean:
            ("예산 계획", "다음 분기 예산 방향 확정",
             "예산은 42만으로 확정", "장소는 2층으로 확정",
             "현지 공급업체를 사용하기로 결정", "외부 감사가 필요한지 여부",
             "김 팀장", "예산 내역 준비", "금요일")
        }
    }

    /// The distinctive long-form strings from every language's example
    /// (NOT short common fields like owners or "Friday", which appear in
    /// real meetings). A parsed line carrying one of these verbatim is
    /// the model copying the example, not extracting — dropped like a
    /// spec echo.
    private static let exampleContent: Set<String> = Set(
        AppLanguage.allCases.flatMap { language -> [String] in
            let f = exampleFields(in: language)
            return [f.summary, f.point, f.point2, f.decision, f.question, f.task]
        })

    /// Placeholder tokens from `chunkRecordPrompt`'s format spec: a line
    /// whose content fields are these words is the model echoing the spec
    /// block, not a record. Keep in sync with the spec in
    /// `chunkRecordPrompt`.
    private static let specPlaceholders: Set<String> = [
        "chunk_id", "time_range", "topic_title", "one_line_summary",
        "source_ids", "key_point", "decision", "owner", "task", "deadline",
        "question", "risk", "term", "reflection",
    ]

    /// The 2B model routinely mis-fills the chunk-id field: the literal
    /// `chunk_id` placeholder, or a borrowed id like the example's c000
    /// (device logs: idMiss=5/7 on lines carrying real records). Only one
    /// chunk exists per call, so any c-number can only mean this chunk —
    /// accept them all rather than discard good records; grounding is
    /// enforced by the source-id check, and example/spec echoes are
    /// rejected by content (`exampleContent`/`specPlaceholders`).
    private static func acceptsChunkID(_ field: String, expected: String) -> Bool {
        field == expected || field == "chunk_id"
            || field.wholeMatch(of: /c\d{1,4}/) != nil
    }

    /// P/D/Q/R/E/J tag → record kind. T and A construct their records
    /// specially and never route through this.
    private static func recordKind(for tag: String) -> SessionRecord.SummaryRecord.Kind {
        switch tag {
        case "P": .point
        case "D": .decision
        case "Q": .question
        case "R": .risk
        case "E": .term
        default: .reflection
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
        var diagnostics = ParseDiagnostics()
        return parseSummaryRecords(
            raw, chunkID: chunkID, validSourceIDs: validSourceIDs,
            source: source, timestamp: timestamp, sourceLabel: sourceLabel,
            diagnostics: &diagnostics)
    }

    func parseSummaryRecords(
        _ raw: String,
        chunkID: String,
        validSourceIDs: [String],
        source: SessionRecord.SummaryRecord.Source,
        timestamp: Date,
        sourceLabel: String? = nil,
        diagnostics: inout ParseDiagnostics
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

        // Split one record line into its fields, tolerating the separators
        // small models actually emit — real tabs, runs of 2+ spaces, or (as
        // a last resort) single spaces, where only the FINAL field can
        // contain internal spaces. Tried per line: device logs showed one
        // response mixing tabbed and space-separated lines, so a whole-
        // response choice mis-splits half of it. Trailing empty fields
        // (a trailing tab) are dropped. Returns nil when no strategy
        // yields the tag's expected count.
        func fields(of line: String, expecting expected: Int) -> [String]? {
            var candidates: [[Substring]] = []
            if line.contains("\t") {
                candidates.append(
                    line.split(separator: "\t", omittingEmptySubsequences: false))
            }
            candidates.append(line.split(separator: /\s{2,}/))
            candidates.append(line.split(separator: /\s+/, maxSplits: expected - 1))
            for candidate in candidates {
                var parts = candidate.map { cleanField(String($0)) }
                while parts.count > expected, parts.last?.isEmpty == true {
                    parts.removeLast()
                }
                if parts.count == expected { return parts }
            }
            return nil
        }

        // Shape check WITHOUT the single-space desperation splitter (which
        // can conjure any field count out of content spaces): only real
        // tabs or 2+-space runs count as deliberate separators.
        func hasStrictShape(_ line: String, expecting expected: Int) -> Bool {
            if line.contains("\t") {
                var parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                    .map { cleanField(String($0)) }
                while parts.count > expected, parts.last?.isEmpty == true {
                    parts.removeLast()
                }
                if parts.count == expected { return true }
            }
            return line.split(separator: /\s{2,}/).count == expected
        }

        let cleaned = cleanResponse(raw)
        diagnostics.hadTabs = cleaned.contains("\t")
        let expectedColumns = ["T": 5, "A": 6, "P": 4, "D": 4, "Q": 4, "R": 4, "E": 4, "J": 4]

        for rawLine in cleaned.split(separator: "\n") {
            let line = Self.stripLineDecorations(String(rawLine))
            guard !line.isEmpty else { continue }
            diagnostics.lines += 1
            let tag = String(line.prefix(while: { !$0.isWhitespace }))
            guard let cap = caps[tag], let expected = expectedColumns[tag] else {
                diagnostics.unknownTag += 1
                continue
            }
            guard (counts[tag] ?? 0) < cap else {
                diagnostics.overCap += 1
                continue
            }
            guard let parts = fields(of: line, expecting: expected) else {
                diagnostics.columnCount += 1
                if diagnostics.columnsSeen.count < 8 {
                    // Tag + tab-split count of the failed line, for the log.
                    let count = line.split(
                        separator: "\t", omittingEmptySubsequences: false).count
                    diagnostics.columnsSeen.append("\(tag):\(count)")
                }
                continue
            }
            // A verbatim spec-block echo has placeholder words where
            // content belongs; an example echo carries the example's
            // distinctive strings. The tolerant chunk-id match below
            // would otherwise let both through as records.
            if parts.dropFirst(2).contains(where: { Self.specPlaceholders.contains($0) }) {
                diagnostics.specEcho += 1
                continue
            }
            if parts.dropFirst(2).contains(where: { Self.exampleContent.contains($0) }) {
                diagnostics.exampleEcho += 1
                continue
            }

            func append(_ record: SessionRecord.SummaryRecord) {
                guard !record.text.isEmpty else { return }
                records.append(record)
                counts[tag, default: 0] += 1
                diagnostics.accepted += 1
            }

            switch tag {
            case "T":
                guard Self.acceptsChunkID(parts[1], expected: chunkID) else {
                    diagnostics.chunkIDMismatch += 1
                    continue
                }
                append(.init(
                    kind: .topic,
                    source: source,
                    sourceIDs: validSourceIDs,
                    sourceIndex: 0,
                    timestamp: timestamp,
                    text: Self.strippedSourceIDTokens(parts[4]),
                    topicTitle: Self.strippedSourceIDTokens(parts[3]),
                    timeRange: parts[2],
                    sourceLabel: sourceLabel))
            case "P", "D", "Q", "R", "E", "J":
                guard Self.acceptsChunkID(parts[1], expected: chunkID) else {
                    diagnostics.chunkIDMismatch += 1
                    continue
                }
                guard let ids = sourceIDs(from: parts[2]) else {
                    diagnostics.invalidSourceIDs += 1
                    continue
                }
                append(.init(
                    kind: Self.recordKind(for: tag),
                    source: source,
                    sourceIDs: ids,
                    sourceIndex: sourceIndex(ids),
                    timestamp: timestamp,
                    text: Self.strippedSourceIDTokens(parts[3]),
                    sourceLabel: sourceLabel))
            case "A":
                guard Self.acceptsChunkID(parts[1], expected: chunkID) else {
                    diagnostics.chunkIDMismatch += 1
                    continue
                }
                guard let ids = sourceIDs(from: parts[2]) else {
                    diagnostics.invalidSourceIDs += 1
                    continue
                }
                let task = Self.strippedSourceIDTokens(parts[4])
                append(.init(
                    kind: .action,
                    source: source,
                    sourceIDs: ids,
                    sourceIndex: sourceIndex(ids),
                    timestamp: timestamp,
                    text: task,
                    owner: Self.strippedSourceIDTokens(parts[3]),
                    task: task,
                    deadline: Self.strippedSourceIDTokens(parts[5]),
                    sourceLabel: sourceLabel))
            default:
                continue
            }
        }

        // Salvage pass: the 2B model sometimes settles into a compressed
        // schema, dropping exactly one field per record kind (device logs:
        // colsSeen=["T:4","P:3","A:4"], stable across attempts). When the
        // strict pass accepted NOTHING — the chunk would otherwise degrade
        // to a fallback stub — re-read those near-miss shapes: T without
        // its time range, P/D/Q/R/E/J without citations (empty sourceIDs
        // marks them ungrounded), A without owner/deadline. Strict output
        // wins whenever it exists, so a compliant response never pays
        // this leniency.
        if records.isEmpty, diagnostics.lines > diagnostics.accepted {
            let salvageColumns = [
                "T": 4, "A": 4, "P": 3, "D": 3, "Q": 3, "R": 3, "E": 3, "J": 3,
            ]
            for rawLine in cleaned.split(separator: "\n") {
                let line = Self.stripLineDecorations(String(rawLine))
                guard !line.isEmpty else { continue }
                let tag = String(line.prefix(while: { !$0.isWhitespace }))
                guard let cap = caps[tag], (counts[tag] ?? 0) < cap else { continue }

                func salvage(_ record: SessionRecord.SummaryRecord) {
                    guard !record.text.isEmpty else { return }
                    records.append(record)
                    counts[tag, default: 0] += 1
                    diagnostics.salvaged += 1
                }
                func echoFree(_ parts: [String]) -> Bool {
                    !parts.dropFirst(1).contains(where: {
                        Self.specPlaceholders.contains($0)
                            || Self.exampleContent.contains($0)
                    })
                }

                // Id-led shape: mid-response the model omits the chunk-id
                // column entirely and leads with its citations
                // ("P\tm004\t内容"). The valid-source-id check IS the
                // proof of interpretation — stronger than the chunk-id
                // echo — so this shape may also rescue strict-shaped
                // lines the id check rejected.
                if tag != "T" {
                    let idLedCounts = tag == "A" ? [5, 4] : [3]
                    var rescued = false
                    for count in idLedCounts {
                        guard let parts = fields(of: line, expecting: count),
                              let ids = sourceIDs(from: parts[1]),
                              echoFree(parts)
                        else { continue }
                        if tag == "A" {
                            let task = Self.strippedSourceIDTokens(parts[3])
                            salvage(.init(
                                kind: .action,
                                source: source,
                                sourceIDs: ids,
                                sourceIndex: sourceIndex(ids),
                                timestamp: timestamp,
                                text: task,
                                owner: Self.strippedSourceIDTokens(parts[2]),
                                task: task,
                                deadline: count == 5
                                    ? Self.strippedSourceIDTokens(parts[4]) : "未明确",
                                sourceLabel: sourceLabel))
                        } else {
                            salvage(.init(
                                kind: Self.recordKind(for: tag),
                                source: source,
                                sourceIDs: ids,
                                sourceIndex: sourceIndex(ids),
                                timestamp: timestamp,
                                text: Self.strippedSourceIDTokens(parts[2]),
                                sourceLabel: sourceLabel))
                        }
                        rescued = true
                        break
                    }
                    if rescued { continue }
                }

                guard let expected = salvageColumns[tag],
                      // Shape near-misses only: a line that genuinely fit
                      // the strict column count was rejected for cause
                      // (invalid citation, echo) — don't resurrect those.
                      expectedColumns[tag].map({ !hasStrictShape(line, expecting: $0) }) == true,
                      let parts = fields(of: line, expecting: expected),
                      Self.acceptsChunkID(parts[1], expected: chunkID),
                      echoFree(parts)
                else { continue }

                switch tag {
                case "T":
                    // [T, id, a, b]: a time-like means the range survived
                    // and title/summary merged; otherwise the range was
                    // the dropped field.
                    let timeLike = parts[2].contains(/\d{1,2}:\d{2}/)
                    salvage(.init(
                        kind: .topic,
                        source: source,
                        sourceIDs: validSourceIDs,
                        sourceIndex: 0,
                        timestamp: timestamp,
                        text: Self.strippedSourceIDTokens(parts[3]),
                        topicTitle: Self.strippedSourceIDTokens(
                            timeLike ? parts[3] : parts[2]),
                        timeRange: timeLike ? parts[2] : "",
                        sourceLabel: sourceLabel))
                case "A":
                    // [A, id, x, task]: x either cites ids or names the
                    // owner — the ids validation decides.
                    let ids = sourceIDs(from: parts[2])
                    let task = Self.strippedSourceIDTokens(parts[3])
                    salvage(.init(
                        kind: .action,
                        source: source,
                        sourceIDs: ids ?? [],
                        sourceIndex: ids.map(sourceIndex) ?? 0,
                        timestamp: timestamp,
                        text: task,
                        owner: ids == nil
                            ? Self.strippedSourceIDTokens(parts[2]) : "未明确",
                        task: task,
                        deadline: "未明确",
                        sourceLabel: sourceLabel))
                default:
                    salvage(.init(
                        kind: Self.recordKind(for: tag),
                        source: source,
                        sourceIDs: [],
                        sourceIndex: 0,
                        timestamp: timestamp,
                        text: Self.strippedSourceIDTokens(parts[2]),
                        sourceLabel: sourceLabel))
                }
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

    /// Reduce phase: synthesize extracted, source-grounded note records into
    /// the final human summary. The model sees notes, not the raw transcript,
    /// so it stays inside the small on-device model's useful range.
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
        let tone = switch style {
        case .meeting:
            "Meeting tone: crisp decisions, actions, risks, and open questions."
        case .memo:
            "Memo tone: direct, useful notes to self."
        case .lecture:
            "Lecture tone: clear study notes with concepts and follow-up questions."
        case .brainstorm:
            "Brainstorm tone: distinct ideas, standouts, and next steps."
        case .journal:
            "Journal tone: reflective but not flowery."
        }
        let system = "\(spec.task) Write entirely in \(language.promptName). "
            + "Synthesize the notes into a reader-friendly summary with a natural overview "
            + "and concise complete-thought bullets. Do not concatenate or copy note/photo "
            + "lines. Do not repeat the overview in section bullets. Avoid repeated lead-ins "
            + "across bullets. Lead with the most important, decision- or outcome-bearing "
            + "points; when a category has more lines than its budget, keep the most important "
            + "and drop minor details. \(tone) Plain text, no markdown. Output ONLY tagged lines: "
            + "first 1-\(overviewCap) lines \"O: <\(spec.overviewHint)>\", "
            + "then \(sectionClauses). Use only information from the notes; never invent "
            + "names, numbers, or events. Keep names, numbers, and dates exactly as written "
            + "in the notes. Photos are reference context only: fold a photo into the "
            + "relevant topic, and never turn a photo into a key point, decision, to-do, or "
            + "next step. Never invent goals, plans, or follow-ups that were not spoken — "
            + "leave a category empty rather than filling it. Skip categories with nothing "
            + "to report. Merge duplicates. No other text."
        return (system, "Notes:\n\(notes)")
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

        /// All content with no markdown scaffolding, for repetition validation.
        var joinedValues: String {
            (overview + sections.flatMap { $0 }).joined(separator: "\n")
        }

        func items(_ tag: String) -> [String] {
            guard let index = style.spec.sections.firstIndex(where: { $0.tag == tag })
            else { return [] }
            return sections[index]
        }
    }

    /// Parse the reduce model's tagged lines against the style's spec.
    /// Untagged output parses empty so the caller can use the deterministic fallback.
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

    /// Keep overview first, then remove exact or near-duplicate section items.
    func deduplicatedStructuredSummary(
        _ parsed: ParsedStructuredSummary
    ) -> ParsedStructuredSummary {
        var cleaned = ParsedStructuredSummary(style: parsed.style)
        var seen: [String] = []

        func shouldKeep(_ text: String) -> Bool {
            let key = SummaryEngine.dedupKey(text)
            guard !key.isEmpty else { return false }
            if seen.contains(key) { return false }
            for prior in seen.suffix(24)
            where HotwordMatcher.similarity(prior, key)
                >= SummaryRecordReducer.crossSectionDedupThreshold {
                return false
            }
            seen.append(key)
            return true
        }

        cleaned.overview = parsed.overview.filter(shouldKeep)
        for index in parsed.sections.indices {
            cleaned.sections[index] = parsed.sections[index].filter(shouldKeep)
        }
        return cleaned
    }

    /// Markdown synthesis from parsed tagged output: overview paragraph, then
    /// one "## Heading" section per non-empty category.
    func renderSummaryMarkdown(
        _ parsed: ParsedStructuredSummary, in language: AppLanguage
    ) -> String {
        let parsed = deduplicatedStructuredSummary(parsed)
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
