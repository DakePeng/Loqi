import Foundation

/// Map-reduce summarization sized for a small on-device model: chunk the
/// transcript at natural boundaries, extract tagged notes per chunk (the
/// narrow task small models do well), then write the final summary from
/// the notes alone — the model never has to synthesize a long raw
/// transcript, and nothing gets silently truncated.
///
/// Sessions with live-mapped notes resume instead of restarting: only the
/// entries past `liveNotesEndEntryID` get mapped, then a single reduce runs
/// over cached + new notes.
///
/// Final summaries use one grounded reduce generation. The deterministic
/// renderer is kept as a fallback only, not the normal user-facing summary.
struct SummaryEngine {
    let llm: LLMService
    /// Hotword matcher for note-glossary injection into the map phase;
    /// nil (reduce-only callers) maps without vocabulary context.
    var matcher: HotwordMatcher?
    private let prompts = PromptBuilder()

    /// Character budget per chunk (≈ tokens for CJK); keeps per-chunk
    /// prefill in the seconds range.
    static let chunkBudget = 1100
    /// Map-phase generation budget — shared by the live note queue so the
    /// two paths can't drift apart.
    static let chunkNoteMaxTokens = 300
    /// A pause this long always starts a new chunk.
    static let chunkGap: TimeInterval = 25
    /// Device-safe upper bounds for reduce generation. Transcript length
    /// can raise the target budget, but never past these caps.
    static let summaryMaxTokensHardCap = 900
    static let summaryOverviewHardCap = 6
    static let summarySectionHardCap = 8
    static let reduceInputCharacterBudget = 6_000

    enum TranscriptSizeTier: Equatable, Sendable {
        case short
        case medium
        case long
    }

    static func transcriptSizeTier(
        transcriptCharacterCount: Int,
        noteCount: Int
    ) -> TranscriptSizeTier {
        if transcriptCharacterCount > 6_000 || noteCount > 10 {
            return .long
        }
        if transcriptCharacterCount >= 1_500 || noteCount >= 4 {
            return .medium
        }
        return .short
    }

    static func summaryPromptSizing(
        style: SummaryStyle,
        length: SummaryLength,
        transcriptCharacterCount: Int,
        noteCount: Int
    ) -> SummaryPromptSizing {
        let tier = transcriptSizeTier(
            transcriptCharacterCount: transcriptCharacterCount,
            noteCount: noteCount)
        let adjustments: (tokens: Int, overviewExtra: Int, sectionExtra: Int) =
            switch (length, tier) {
            case (.concise, .short): (320, 0, 0)
            case (.concise, .medium): (380, 0, 1)
            case (.concise, .long): (460, 1, 1)
            case (.standard, .short): (460, 1, 1)
            case (.standard, .medium): (620, 1, 2)
            case (.standard, .long): (760, 2, 3)
            case (.detailed, .short): (560, 1, 2)
            case (.detailed, .medium): (780, 2, 3)
            case (.detailed, .long): (1_000, 3, 5)
            }
        let spec = style.spec
        return SummaryPromptSizing(
            maxTokens: min(adjustments.tokens, summaryMaxTokensHardCap),
            overviewCap: min(
                spec.overviewCap + adjustments.overviewExtra,
                summaryOverviewHardCap),
            sectionCaps: spec.sections.map {
                min($0.cap + adjustments.sectionExtra, summarySectionHardCap)
            })
    }

    /// Split entries into chunks: hard-break on long pauses, soft-prefer
    /// speaker changes once a chunk is mostly full, hard-break on budget.
    static func chunkEntries(
        _ entries: [SessionRecord.Entry],
        budget: Int = chunkBudget,
        gap: TimeInterval = chunkGap
    ) -> [[SessionRecord.Entry]] {
        var chunks: [[SessionRecord.Entry]] = []
        var current: [SessionRecord.Entry] = []
        var currentSize = 0

        for entry in entries {
            let size = entry.sourceText.count
            let pause = current.last.map {
                entry.timestamp.timeIntervalSince($0.timestamp)
            } ?? 0
            let speakerChanged = current.last.map { $0.speaker != entry.speaker } ?? false

            let shouldBreak = !current.isEmpty
                && (pause >= gap
                    || currentSize + size > budget
                    || (speakerChanged && currentSize > budget * 6 / 10))
            if shouldBreak {
                chunks.append(current)
                current = []
                currentSize = 0
            }
            current.append(entry)
            currentSize += size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Entries not yet covered by live notes. An end-id that no longer
    /// resolves (edited/old record) means coverage is unknowable — remap
    /// everything rather than risk a gap. A cached fallback stub (its live
    /// generation failed) gets a second chance: coverage is rolled back to
    /// its chunk and everything from there is remapped.
    static func uncoveredEntries(
        of record: SessionRecord
    ) -> (entries: [SessionRecord.Entry], cachedNotes: [SessionRecord.ChunkNote]) {
        guard let endID = record.liveNotesEndEntryID,
              let cached = record.chunkNotes, !cached.isEmpty,
              let endIndex = record.entries.firstIndex(where: { $0.id == endID })
        else { return (record.entries, []) }
        if let stub = cached.firstIndex(where: { $0.isFallback == true }) {
            // Live notes always carry a real anchor (ChunkNoteQueue.Job's
            // anchorEntryID is non-optional), so the only way this guard fails
            // is a record whose anchored entry was since edited/removed — and
            // then coverage is genuinely unknowable, so the safe degrade is to
            // discard the cached notes and remap everything.
            guard let anchorID = cached[stub].anchorEntryID,
                  let anchorIndex = record.entries.firstIndex(where: { $0.id == anchorID })
            else { return (record.entries, []) }
            return (Array(record.entries[anchorIndex...]), Array(cached[..<stub]))
        }
        return (Array(record.entries[(endIndex + 1)...]), cached)
    }

    /// LLM hotword-restore budget for `hygienePass` — keeps a long
    /// session's pre-summarize cleanup in the seconds range, not minutes.
    static let hygieneRestoreCap = 20

    /// Pre-summarize transcript hygiene, keyed entirely on the hotword
    /// matcher (general LLM transcript polishing was removed — the
    /// transcript is the record of what was said):
    /// 1. Deterministic `fixup` over every entry (instant).
    /// 2. Vocabulary-targeted LLM restore for entries where a hotword
    ///    near-miss plausibly hides but `fixup` couldn't repair it —
    ///    strictly scoped to term replacement, fidelity-gated, capped at
    ///    `hygieneRestoreCap`.
    /// Cached live notes covering a changed entry are dropped — they
    /// summarized the old wording — so summarize remaps those chunks.
    /// Best-effort: restore failures keep the original text.
    func hygienePass(
        _ record: SessionRecord
    ) async -> (record: SessionRecord, changed: Bool) {
        guard let matcher, !matcher.isEmpty else { return (record, false) }
        var updated = record
        var changedIDs = Set<UUID>()

        for index in updated.entries.indices {
            let entry = updated.entries[index]
            let fixed = matcher.fixup(
                entry.sourceText, language: entry.direction.source)
            if fixed != entry.sourceText {
                updated.entries[index].sourceText = fixed
                changedIDs.insert(entry.id)
            }
        }

        var restored = 0
        for index in updated.entries.indices {
            guard restored < Self.hygieneRestoreCap else { break }
            let entry = updated.entries[index]
            // rawSourceText set means an earlier pass already restored it.
            guard entry.rawSourceText == nil,
                  matcher.shouldForceRefine(
                    entry.sourceText, language: entry.direction.source)
            else { continue }
            let vocabulary = matcher.noteGlossaryLines(
                language: entry.direction.source, text: entry.sourceText)
            guard !vocabulary.isEmpty else { continue }
            restored += 1
            guard let raw = try? await llm.generate(
                    system: prompts.hotwordRestoreSystemPrompt(
                        vocabulary: vocabulary,
                        language: entry.direction.source),
                    user: "Sentence: \(entry.sourceText)",
                    maxTokens: 120),
                  let fixed = prompts.parseRestoredSentence(raw),
                  prompts.isAcceptableHotwordRestore(
                    fixed, original: entry.sourceText),
                  fixed != entry.sourceText
            else { continue }
            updated.entries[index].rawSourceText = entry.sourceText
            updated.entries[index].sourceText = fixed
            changedIDs.insert(entry.id)
        }

        if !changedIDs.isEmpty, let endID = updated.liveNotesEndEntryID {
            let coveredChanged: Bool
            if let endIndex = updated.entries.firstIndex(where: { $0.id == endID }) {
                coveredChanged = updated.entries[...endIndex]
                    .contains { changedIDs.contains($0.id) }
            } else {
                coveredChanged = true
            }
            if coveredChanged {
                updated.chunkNotes = nil
                updated.liveNotesEndEntryID = nil
            }
        }
        return (updated, !changedIDs.isEmpty)
    }

    /// Map phase over one batch of entries. `progress` reports
    /// (completedChunks, totalChunks).
    func makeNotes(
        for entries: [SessionRecord.Entry],
        speakerLabel: (Int?) -> String?,
        fallbackDate: Date,
        in language: AppLanguage,
        progress: @MainActor @Sendable (Int, Int) -> Void
    ) async throws -> [SessionRecord.ChunkNote] {
        let chunks = Self.chunkEntries(entries)
        var notes: [SessionRecord.ChunkNote] = []
        // Last extracted topic title, fed to the next chunk so an ongoing
        // topic isn't re-extracted as a fresh one each chunk.
        var previousTopic = ""

        for (index, chunk) in chunks.enumerated() {
            await progress(index, chunks.count)
            let sourceIDs = chunk.indices.map { String(format: "m%03d", $0 + 1) }
            let text = zip(sourceIDs, chunk).map { id, entry in
                let speaker = speakerLabel(entry.speaker).map { "[\($0)] " } ?? ""
                return "\(id)\t\(speaker)\(entry.sourceText)"
            }.joined(separator: "\n")
            let chunkID = String(format: "c%03d", index + 1)

            // Vocabulary scoring runs against the chunk's own source
            // language (pinyin matching for CJK), not the note language.
            let vocabulary = matcher?.noteGlossaryLines(
                language: chunk.first?.direction.source ?? language,
                text: text) ?? []
            let prompt = prompts.chunkRecordPrompt(
                chunkID: chunkID,
                timeRange: Self.timeRange(for: chunk),
                contextOnly: previousTopic,
                target: text,
                vocabulary: vocabulary,
                in: language)
            var parsed = PromptBuilder.ParsedChunkNote()
            // One retry: a single failed or off-format generation would
            // otherwise degrade this chunk to a headline-only stub.
            for _ in 0..<2 {
                do {
                    let raw = try await llm.generate(
                        system: prompt.system, user: prompt.user,
                        maxTokens: Self.chunkNoteMaxTokens, temperature: 0.1)
                    let records = prompts.parseSummaryRecords(
                        raw,
                        chunkID: chunkID,
                        validSourceIDs: sourceIDs,
                        source: .transcript,
                        timestamp: chunk.first?.timestamp ?? fallbackDate)
                    parsed = prompts.parsedChunkNote(records: records)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    parsed = PromptBuilder.ParsedChunkNote()
                }
                if !parsed.isEmpty { break }
            }

            notes.append(SessionRecord.ChunkNote(
                // A chunk whose extraction failed still gets an outline
                // entry: fall back to its opening words.
                headline: parsed.headline
                    ?? String(chunk.first?.sourceText.prefix(24) ?? "…"),
                startedAt: chunk.first?.timestamp ?? fallbackDate,
                anchorEntryID: chunk.first?.id,
                facts: parsed.facts,
                decisions: parsed.decisions,
                actions: parsed.actions,
                terms: parsed.terms,
                summaryRecords: parsed.summaryRecords.isEmpty ? nil : parsed.summaryRecords,
                isFallback: parsed.isEmpty ? true : nil))
            // Carry the last real topic forward; a failed chunk keeps the
            // prior one rather than seeding context with fallback text.
            if let headline = parsed.headline { previousTopic = headline }
        }
        await progress(chunks.count, chunks.count)
        return notes
    }

    /// Normalized form for cross-note duplicate detection: lowercased,
    /// letters and digits only, so "Ship June 10." and "ship june 10"
    /// collapse to one bullet.
    static func dedupKey(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars
        where isDedupScalar(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func isDedupScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return CharacterSet.alphanumerics.contains(scalar)
            || (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
    }

    static func timeRange(for entries: [SessionRecord.Entry]) -> String {
        guard let first = entries.first else { return "未明确" }
        let start = first.audioOffset ?? first.timestamp.timeIntervalSince1970
        let end = entries.last?.audioOffset
            ?? entries.last?.timestamp.timeIntervalSince1970
            ?? start
        if first.audioOffset != nil || entries.last?.audioOffset != nil {
            return "\(clockTime(start))-\(clockTime(max(start, end)))"
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: first.timestamp))-\(formatter.string(from: entries.last?.timestamp ?? first.timestamp))"
    }

    private static func clockTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Summaries are for the reader: the device language wins, with the
    /// session's target language as fallback.
    static func summaryLanguage(for record: SessionRecord) -> AppLanguage {
        AppLanguage.devicePreferred
            ?? record.entries.last?.direction.target ?? .english
    }

    /// Reduce input: one labeled line per extracted record. Photos are
    /// labeled as photo context so the final reduce can fold them into the
    /// surrounding topic instead of copying captions as standalone summary.
    static func reduceInput(
        notes: [SessionRecord.ChunkNote],
        style: SummaryStyle,
        maxCharacters: Int? = nil
    ) -> String {
        let records = SummaryRecordReducer.deduped(
            SummaryRecordReducer.records(from: notes))
        var seen = Set<String>()
        var recent: [(label: String, key: String)] = []
        var lines: [String] = []
        var characterCount = 0

        func actionText(_ record: SessionRecord.SummaryRecord) -> String {
            let owner = record.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let deadline = record.deadline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var text = record.task?.isEmpty == false ? record.task! : record.text
            if !owner.isEmpty, owner != "未明确" {
                text = "\(owner): \(text)"
            }
            if !deadline.isEmpty, deadline != "未明确" {
                text += " (\(deadline))"
            }
            return text
        }

        func labelAndText(_ record: SessionRecord.SummaryRecord) -> (String, String)? {
            switch record.kind {
            case .topic:
                return ("topic", record.text.isEmpty ? record.topicTitle ?? "" : record.text)
            case .point:
                return (record.source == .photo ? "photo" : "fact", record.text)
            case .decision:
                return ("decision", record.text)
            case .action:
                return ("action", actionText(record))
            case .question:
                return ("question", record.text)
            case .risk:
                return ("risk", record.text)
            case .term:
                guard style.spec.includeTermsInNotes else { return nil }
                return ("term", record.text)
            case .reflection:
                return ("reflection", record.text)
            }
        }

        func keep(_ label: String, _ text: String) -> Bool {
            let key = dedupKey(text)
            guard !key.isEmpty else { return false }
            let labeledKey = "\(label):\(key)"
            if seen.contains(labeledKey) { return false }
            for prior in recent.suffix(24)
            where prior.label == label
                && HotwordMatcher.similarity(prior.key, key) >= 0.9 {
                return false
            }
            seen.insert(labeledKey)
            recent.append((label, key))
            return true
        }

        func append(_ line: String) {
            guard let maxCharacters else {
                lines.append(line)
                return
            }
            guard maxCharacters > 0 else { return }
            let extra = line.count + (lines.isEmpty ? 0 : 1)
            if characterCount + extra <= maxCharacters {
                lines.append(line)
                characterCount += extra
            } else if lines.isEmpty {
                lines.append(String(line.prefix(maxCharacters)))
                characterCount = maxCharacters
            }
        }

        for record in records {
            guard let (label, text) = labelAndText(record),
                  keep(label, text) else { continue }
            append("\(label): \(text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Reduce phase: the final summary, written from notes alone. The
    /// deterministic renderer keeps live peeks local and backs up bad output.
    func reduce(
        notes: [SessionRecord.ChunkNote],
        style: SummaryStyle = .meeting,
        length: SummaryLength = .standard,
        maxInputCharacters: Int? = nil,
        transcriptCharacterCount: Int? = nil,
        in language: AppLanguage,
        stitchDetails: Bool = true,
        progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async throws -> String {
        let sizing = Self.summaryPromptSizing(
            style: style,
            length: length,
            transcriptCharacterCount: transcriptCharacterCount
                ?? notes.reduce(0) { total, note in
                    total + note.headline.count
                        + note.facts.reduce(0) { $0 + $1.count }
                        + note.decisions.reduce(0) { $0 + $1.count }
                        + note.actions.reduce(0) { $0 + $1.count }
                },
            noteCount: notes.count)
        let input = Self.reduceInput(
            notes: notes, style: style, maxCharacters: maxInputCharacters)
        guard !input.isEmpty else { throw SummaryError.generationFailed }
        if !stitchDetails {
            let summary = SummaryRecordReducer.render(
                records: SummaryRecordReducer.records(from: notes),
                style: style,
                length: length,
                in: language,
                stitchDetails: false)
            guard !summary.isEmpty else { throw SummaryError.generationFailed }
            await progress?(1, 1)
            return summary
        }
        let prompt = prompts.reduceSummaryPrompt(
            notes: input,
            style: style,
            in: language,
            sizing: sizing)
        let output = try await Self.generateStructuredReduce(style: style) {
            try await llm.generate(
                system: prompt.system,
                user: prompt.user,
                maxTokens: sizing.maxTokens,
                temperature: 0.3)
        } parse: { raw in
            prompts.parseStructuredSummary(raw, style: style, sizing: sizing)
        }

        let summary = Self.renderReducedSummary(
            raw: output.raw,
            parsed: output.parsed,
            notes: notes,
            style: style,
            length: length,
            in: language,
            stitchDetails: stitchDetails)
        guard !summary.isEmpty else { throw SummaryError.generationFailed }
        await progress?(1, 1)
        return summary
    }

    static func generateStructuredReduce(
        style: SummaryStyle,
        _ generate: () async throws -> String,
        parse: (String) -> PromptBuilder.ParsedStructuredSummary
    ) async throws -> (raw: String, parsed: PromptBuilder.ParsedStructuredSummary) {
        do {
            let raw = try await generate()
            return (raw, parse(raw))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ("", PromptBuilder.ParsedStructuredSummary(style: style))
        }
    }

    static func renderReducedSummary(
        raw: String,
        parsed: PromptBuilder.ParsedStructuredSummary,
        notes: [SessionRecord.ChunkNote],
        style: SummaryStyle,
        length: SummaryLength,
        in language: AppLanguage,
        stitchDetails: Bool
    ) -> String {
        let prompts = PromptBuilder()
        func fallback() -> String {
            SummaryRecordReducer.render(
                records: SummaryRecordReducer.records(from: notes),
                style: style,
                length: length,
                in: language,
                stitchDetails: stitchDetails)
        }

        guard !parsed.isEmpty else { return fallback() }
        guard !PromptBuilder.hasDegenerateRepetition(parsed.joinedValues)
        else { return fallback() }
        let parsed = dedupedStructuredSummary(parsed)
        guard !parsed.isEmpty else { return fallback() }
        let summary = prompts.renderSummaryMarkdown(parsed, in: language)
        return summary.isEmpty ? fallback() : summary
    }

    static func dedupedStructuredSummary(
        _ parsed: PromptBuilder.ParsedStructuredSummary
    ) -> PromptBuilder.ParsedStructuredSummary {
        var copy = parsed
        var usedKeys: [String] = []

        func keep(_ text: String) -> Bool {
            let key = dedupKey(text)
            guard !key.isEmpty else { return false }
            for prior in usedKeys
            where prior == key
                || HotwordMatcher.similarity(prior, key)
                    >= SummaryRecordReducer.crossSectionDedupThreshold {
                return false
            }
            usedKeys.append(key)
            return true
        }

        copy.overview = copy.overview.filter { keep($0) }
        copy.sections = copy.sections.map { $0.filter { keep($0) } }
        return copy
    }

    /// Best-effort scenario detection for the post-stop selection step.
    /// Prefers cached chunk-note headlines (compact, already distilled);
    /// falls back to the transcript opening. nil when the model answers
    /// off-format — the caller just shows no suggestion.
    func detectStyle(for record: SessionRecord) async throws -> SummaryStyle? {
        try await llm.load(policy: .requireDownloaded)
        let context: String
        if let notes = record.chunkNotes, !notes.isEmpty {
            context = notes.prefix(8).map { note in
                ([note.headline] + note.facts.prefix(2) + note.actions.prefix(1))
                    .joined(separator: "; ")
            }.joined(separator: "\n")
        } else {
            context = String(record.entries.map(\.sourceText)
                .joined(separator: "\n").prefix(900))
        }
        let prompt = prompts.scenarioDetectionPrompt(context: context)
        let raw = try await llm.generate(
            system: prompt.system, user: prompt.user, maxTokens: 12, temperature: 0)
        return prompts.parseScenario(raw)
    }

    /// Map + reduce, resuming from live notes when the record has them.
    /// Returns the merged note list (cached + newly mapped) so the caller
    /// can persist full coverage. The map phase is style-independent; only
    /// the reduce step varies, so changing styles re-runs reduce alone.
    func summarize(
        _ record: SessionRecord,
        style: SummaryStyle = .meeting,
        length: SummaryLength = .standard,
        in language: AppLanguage,
        progress: @escaping @MainActor @Sendable (Int, Int) -> Void
    ) async throws -> (summary: String, notes: [SessionRecord.ChunkNote]) {
        let (uncovered, cached) = Self.uncoveredEntries(of: record)
        if !uncovered.isEmpty {
            try await llm.load(policy: .requireDownloaded)
        }
        let mapChunks = Self.chunkEntries(uncovered).count
        let totalSteps = mapChunks + 1
        let fresh = try await makeNotes(
            for: uncovered,
            speakerLabel: { record.speakerLabel($0) },
            fallbackDate: record.startedAt,
            in: language,
            progress: { done, _ in
                progress(done, totalSteps)
            })
        let notes = cached + fresh
        let mappedCount = fresh.count
        let summary = try await reduce(
            notes: AttachmentNotes.merged(notes, attachments: record.attachments),
            style: style,
            length: length,
            maxInputCharacters: Self.reduceInputCharacterBudget,
            transcriptCharacterCount: record.entries.reduce(0) {
                $0 + $1.sourceText.count
            },
            in: language,
            progress: { done, _ in
                progress(mappedCount + done, totalSteps)
            })
        return (summary, notes)
    }
}

enum SummaryRecordReducer {
    typealias Record = SessionRecord.SummaryRecord

    /// Cross-section suppression: a bullet this similar to one already shown
    /// elsewhere is dropped. Looser than `deduped`'s 0.9 merge because
    /// small-model paraphrases of one statement routinely land in this band.
    static let crossSectionDedupThreshold = 0.85

    static func records(
        from notes: [SessionRecord.ChunkNote],
        attachments: [SessionRecord.Attachment]? = nil
    ) -> [Record] {
        let noteRecords = notes.enumerated().flatMap { index, note in
            records(from: note, fallbackIndex: index)
        }
        let attachmentRecords = (attachments ?? []).enumerated().flatMap { index, attachment in
            AttachmentNotes.records(for: attachment, fallbackIndex: notes.count + index)
        }
        return (noteRecords + attachmentRecords)
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.sourceIndex < rhs.sourceIndex
            }
    }

    static func records(
        from note: SessionRecord.ChunkNote,
        fallbackIndex: Int = 0
    ) -> [Record] {
        if let records = note.summaryRecords, !records.isEmpty {
            return records
        }
        var records: [Record] = []
        func append(_ kind: Record.Kind, _ text: String, offset: Int) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            records.append(.init(
                kind: kind,
                source: .transcript,
                sourceIDs: ["legacy-\(fallbackIndex)-\(offset)"],
                sourceIndex: fallbackIndex * 100 + offset,
                timestamp: note.startedAt,
                text: trimmed))
        }

        append(.topic, note.headline, offset: 0)
        for (offset, fact) in note.facts.enumerated() {
            append(.point, fact, offset: 10 + offset)
        }
        for (offset, decision) in note.decisions.enumerated() {
            append(.decision, decision, offset: 30 + offset)
        }
        for (offset, action) in note.actions.enumerated() {
            append(.action, action, offset: 50 + offset)
        }
        for (offset, term) in note.terms.enumerated() {
            append(.term, term, offset: 70 + offset)
        }
        return records
    }

    static func render(
        records: [Record],
        style: SummaryStyle,
        length: SummaryLength,
        in language: AppLanguage,
        stitchDetails: Bool = true
    ) -> String {
        let records = deduped(records)
        guard !records.isEmpty else { return "" }
        let spec = style.spec
        var blocks: [String] = []
        // Kind-agnostic, paraphrase-aware: the same statement classified as a
        // Point in one chunk and a Decision in another would otherwise render
        // into two different sections. First occurrence (overview, then spec
        // order) wins. ponytail: O(n²) over the rendered set; it's tiny (≤ ~30).
        var usedKeys: [String] = []

        func displayUnused(_ record: Record) -> String? {
            let key = SummaryEngine.dedupKey(dedupText(record))
            guard !key.isEmpty else { return nil }
            for prior in usedKeys
            where prior == key
                || HotwordMatcher.similarity(prior, key) >= crossSectionDedupThreshold {
                return nil
            }
            usedKeys.append(key)
            return displayText(record, includeSource: true)
        }

        func takeUnused(_ records: [Record], limit: Int) -> [String] {
            var lines: [String] = []
            for record in records where lines.count < limit {
                if let text = displayUnused(record) {
                    lines.append(text)
                }
            }
            return lines
        }

        let overviewCap = cap(
            base: spec.overviewCap, length: length, minimum: 1)
        let overview = takeUnused(
            overviewRecords(records, style: style), limit: overviewCap)
        if !overview.isEmpty {
            blocks.append(overview.joined(separator: " "))
        }

        for section in spec.sections {
            let sectionRecords = recordsForSection(
                section.tag, style: style, records: records)
            let limit = cap(base: section.cap, length: length, minimum: 1)
            let lines = takeUnused(sectionRecords, limit: limit).map { "- \($0)" }
            if !lines.isEmpty {
                blocks.append("## \(section.heading(for: language))\n"
                    + lines.joined(separator: "\n"))
            }
        }

        if stitchDetails, length == .detailed {
            let detailRecords = records.filter {
                $0.kind != .topic && !$0.text.isEmpty
            }
            let detailLines = takeUnused(detailRecords, limit: 12).map { "- \($0)" }
            if !detailLines.isEmpty {
                blocks.append("## \(detailHeading(for: language))\n"
                    + detailLines.joined(separator: "\n"))
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func cap(
        base: Int, length: SummaryLength, minimum: Int
    ) -> Int {
        switch length {
        case .concise: max(minimum, base - 1)
        case .standard: base
        case .detailed: base + 4
        }
    }

    private static func overviewRecords(
        _ records: [Record], style: SummaryStyle
    ) -> [Record] {
        let topics = records.filter { $0.kind == .topic }
        if !topics.isEmpty { return topics }
        switch style {
        case .journal:
            let reflections = records.filter { $0.kind == .reflection }
            if !reflections.isEmpty { return reflections }
        default:
            break
        }
        return records.filter { $0.kind == .point || $0.kind == .decision }
    }

    private static func recordsForSection(
        _ tag: String, style: SummaryStyle, records: [Record]
    ) -> [Record] {
        switch (style, tag) {
        case (.meeting, "T"):
            return records.filter {
                $0.kind == .topic || $0.kind == .point
                    || $0.kind == .question || $0.kind == .risk
            }
        case (.meeting, "D"):
            return records.filter { $0.kind == .decision }
        case (.meeting, "A"):
            return records.filter { $0.kind == .action }
        case (.memo, "K"):
            return records.filter { $0.kind == .point || $0.kind == .decision }
        case (.memo, "A"):
            return records.filter { $0.kind == .action }
        case (.lecture, "C"):
            return records.filter { $0.kind == .point }
        case (.lecture, "T"):
            return records.filter { $0.kind == .term }
        case (.lecture, "Q"):
            return records.filter { $0.kind == .question }
        case (.brainstorm, "I"):
            return records.filter { $0.kind == .point }
        case (.brainstorm, "S"):
            return records.filter { $0.kind == .decision || $0.kind == .risk }
        case (.brainstorm, "A"):
            return records.filter { $0.kind == .action }
        case (.journal, "H"):
            return records.filter { $0.kind == .point }
        case (.journal, "F"):
            return records.filter { $0.kind == .reflection || $0.kind == .risk }
        case (.journal, "N"):
            return records.filter { $0.kind == .action }
        default:
            return []
        }
    }

    private static func displayText(_ record: Record, includeSource: Bool) -> String {
        let body = record.kind == .action ? actionText(record) : record.text
        guard includeSource, record.source == .photo else { return body }
        let label = record.sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(label?.isEmpty == false ? label! : "Photo")] \(body)"
    }

    private static func actionText(_ record: Record) -> String {
        let owner = record.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deadline = record.deadline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var text = record.task?.isEmpty == false ? record.task! : record.text
        if !owner.isEmpty, owner != "未明确" {
            text = "\(owner): \(text)"
        }
        if !deadline.isEmpty, deadline != "未明确" {
            text += " (\(deadline))"
        }
        return text
    }

    private static func dedupText(_ record: Record) -> String {
        record.kind == .action ? actionText(record) : record.text
    }

    /// When one statement is classified differently across chunks (a
    /// Decision in one, a Point in another), the more specific kind wins so
    /// it renders in a single section. Topics dedup in their own namespace,
    /// so their priority never competes here.
    private static func kindPriority(_ kind: Record.Kind) -> Int {
        switch kind {
        case .decision: 5
        case .action: 4
        case .risk: 3
        case .question: 2
        case .point, .reflection: 1
        case .term, .topic: 0
        }
    }

    static func deduped(_ records: [Record]) -> [Record] {
        let sorted = records.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.sourceIndex < rhs.sourceIndex
        }
        var merged: [Record] = []
        var exact: [String: Int] = [:]
        var recent: [(key: String, index: Int)] = []

        for record in sorted {
            let base = SummaryEngine.dedupKey(dedupText(record))
            guard !base.isEmpty else { continue }
            // Non-topic records dedup across kinds, so a statement tagged
            // Point in one chunk and Decision in another collapses to one
            // bullet; topics dedup only against other topics.
            let isTopic = record.kind == .topic
            let key = isTopic ? "topic:\(base)" : base
            let duplicateIndex: Int?
            if let existing = exact[key] {
                duplicateIndex = existing
            } else {
                duplicateIndex = recent.suffix(24).first {
                    $0.key.hasPrefix("topic:") == isTopic
                        && HotwordMatcher.similarity($0.key, key) >= 0.9
                }?.index
            }
            if let duplicateIndex {
                merged[duplicateIndex].sourceIDs = Array(
                    Set(merged[duplicateIndex].sourceIDs + record.sourceIDs)).sorted()
                if merged[duplicateIndex].sourceLabel == nil {
                    merged[duplicateIndex].sourceLabel = record.sourceLabel
                }
                // Keep the more specific classification and its action fields.
                if kindPriority(record.kind) > kindPriority(merged[duplicateIndex].kind) {
                    merged[duplicateIndex].kind = record.kind
                    merged[duplicateIndex].owner = record.owner
                    merged[duplicateIndex].task = record.task
                    merged[duplicateIndex].deadline = record.deadline
                }
                continue
            }
            exact[key] = merged.count
            recent.append((key, merged.count))
            merged.append(record)
        }
        return merged
    }

    private static func detailHeading(for language: AppLanguage) -> String {
        switch language {
        case .chinese: "详细记录"
        case .japanese: "詳細メモ"
        case .korean: "상세 메모"
        case .english: "Details"
        }
    }
}

enum SummaryError: LocalizedError {
    case generationFailed

    var errorDescription: String? {
        String(localized: "Summary failed — try again.")
    }
}
