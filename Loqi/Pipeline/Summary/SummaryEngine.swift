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
/// Detailed summaries don't stop at that single reduce — its caps keep any
/// one generation short no matter the transcript. The notes are segmented,
/// each segment gets its own small section generation, and the sections are
/// stitched after the core summary, so the document scales with the
/// recording while every individual call stays inside the model's range.
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
    /// Detailed summaries stitch per-segment sections after the core
    /// summary; below this many notes the single reduce covers everything.
    static let detailStitchMinNotes = 4
    /// Consecutive notes per stitched section.
    static let detailSegmentSize = 3
    /// Bullets per stitched section, parsed and fallback alike.
    static let detailSectionPointCap = 6

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

        for (index, chunk) in chunks.enumerated() {
            await progress(index, chunks.count)
            let text = chunk.map { entry in
                let speaker = speakerLabel(entry.speaker).map { "[\($0)] " } ?? ""
                return speaker + entry.sourceText
            }.joined(separator: "\n")

            // Vocabulary scoring runs against the chunk's own source
            // language (pinyin matching for CJK), not the note language.
            let vocabulary = matcher?.noteGlossaryLines(
                language: chunk.first?.direction.source ?? language,
                text: text) ?? []
            let prompt = prompts.chunkNotePrompt(
                chunkText: text, vocabulary: vocabulary, in: language)
            var parsed = PromptBuilder.ParsedChunkNote()
            // One retry: a single failed or off-format generation would
            // otherwise degrade this chunk to a headline-only stub.
            for _ in 0..<2 {
                do {
                    let raw = try await llm.generate(
                        system: prompt.system, user: prompt.user,
                        maxTokens: Self.chunkNoteMaxTokens, temperature: 0.3)
                    parsed = prompts.parseChunkNote(raw)
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
                isFallback: parsed.isEmpty ? true : nil))
        }
        await progress(chunks.count, chunks.count)
        return notes
    }

    /// Reduce input: one block per note. `term:` lines ride along only when
    /// the style's spec asks for them (lecture). Headline-only stubs (failed
    /// extractions) are kept out — a bare "[n] <opening words>" line invites
    /// the reduce model to invent content for that span — unless every note
    /// is a stub, where headlines beat an empty input.
    static func reduceInput(
        notes: [SessionRecord.ChunkNote], style: SummaryStyle
    ) -> String {
        let contentful = notes.filter(\.hasContent)
        let included = contentful.isEmpty ? notes : contentful
        // Cross-note dedup: topics span chunk boundaries, so small models
        // restate the same fact in adjacent chunks and the reduce then
        // double-counts it. Drop a bullet whose normalized form repeats — or
        // near-repeats, at a high threshold — one already emitted by an
        // earlier note. First occurrence wins, so chronology and headlines
        // are untouched.
        var seen = Set<String>()
        var recent: [String] = []
        func isDuplicate(_ text: String) -> Bool {
            let key = Self.dedupKey(text)
            guard !key.isEmpty else { return false }
            if seen.contains(key) { return true }
            // Light paraphrase: compare only against the most recent keys so
            // distinct facts are never merged and the cost stays linear.
            for prior in recent.suffix(24)
            where HotwordMatcher.similarity(prior, key) >= 0.9 {
                return true
            }
            seen.insert(key)
            recent.append(key)
            return false
        }
        func keep(_ items: [String], _ label: String) -> [String] {
            items.compactMap { isDuplicate($0) ? nil : "\(label): \($0)" }
        }
        return included.enumerated().map { index, note in
            var lines = ["[\(index + 1)] \(note.headline)"]
            lines.append(contentsOf: keep(note.facts, "fact"))
            lines.append(contentsOf: keep(note.decisions, "decision"))
            lines.append(contentsOf: keep(note.actions, "action"))
            if style.spec.includeTermsInNotes {
                lines.append(contentsOf: keep(note.terms, "term"))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Normalized form for cross-note duplicate detection: lowercased,
    /// letters and digits only, so "Ship June 10." and "ship june 10"
    /// collapse to one bullet.
    static func dedupKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    struct DetailSection: Equatable, Sendable {
        var headline: String
        var points: [String]
    }

    static func shouldStitchDetailSections(
        length: SummaryLength, noteCount: Int
    ) -> Bool {
        length == .detailed && noteCount >= detailStitchMinNotes
    }

    /// Split notes into consecutive segments of about `detailSegmentSize`,
    /// balanced so no trailing one-note runt section appears.
    static func segmentNotes(
        _ notes: [SessionRecord.ChunkNote], size: Int = detailSegmentSize
    ) -> [[SessionRecord.ChunkNote]] {
        guard !notes.isEmpty else { return [] }
        let segmentCount = (notes.count + size - 1) / size
        var segments: [[SessionRecord.ChunkNote]] = []
        var start = 0
        for remaining in stride(from: segmentCount, to: 0, by: -1) {
            let take = (notes.count - start + remaining - 1) / remaining
            segments.append(Array(notes[start..<(start + take)]))
            start += take
        }
        return segments
    }

    /// Deterministic stand-in when a segment generation fails or answers
    /// off-format: the section is assembled from the notes themselves, so
    /// a detailed summary never silently loses a stretch of the recording.
    static func fallbackSection(
        for segment: [SessionRecord.ChunkNote]
    ) -> DetailSection? {
        let points = segment.flatMap { $0.facts + $0.decisions + $0.actions }
        guard let headline = segment.first?.headline, !points.isEmpty
        else { return nil }
        return DetailSection(
            headline: headline,
            points: Array(points.prefix(detailSectionPointCap)))
    }

    /// Stitched markdown: numbered "## " sections so the chronological
    /// detail reads apart from the style's category sections above it.
    static func appendDetailSections(
        _ sections: [DetailSection], to base: String
    ) -> String {
        guard !sections.isEmpty else { return base }
        let blocks = sections.enumerated().map { index, section in
            "## \(index + 1). \(section.headline)\n"
                + section.points.map { "- \($0)" }.joined(separator: "\n")
        }
        return base + "\n\n" + blocks.joined(separator: "\n\n")
    }

    /// One generation per segment; errors and off-format answers fall back
    /// to the segment's own note lines, and a segment with no content at
    /// all is skipped. `progress` reports (completedSegments, totalSegments).
    func detailSections(
        for segments: [[SessionRecord.ChunkNote]],
        style: SummaryStyle,
        in language: AppLanguage,
        progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async -> [DetailSection] {
        var sections: [DetailSection] = []
        for (index, segment) in segments.enumerated() {
            await progress?(index, segments.count)
            let prompt = prompts.segmentSectionPrompt(
                notes: Self.reduceInput(notes: segment, style: style),
                in: language)
            // One retry on an off-format (pointless) parse before the note
            // fallback, mirroring the map and reduce phases.
            var parsed = PromptBuilder.ParsedSegmentSection()
            for _ in 0..<2 {
                if Task.isCancelled { break }
                if let raw = try? await llm.generate(
                    system: prompt.system, user: prompt.user,
                    maxTokens: 280, temperature: 0.3) {
                    parsed = prompts.parseSegmentSection(raw)
                }
                if !parsed.points.isEmpty { break }
            }
            if parsed.points.isEmpty {
                if let fallback = Self.fallbackSection(for: segment) {
                    sections.append(fallback)
                }
            } else {
                sections.append(DetailSection(
                    headline: parsed.headline ?? segment.first?.headline ?? "…",
                    points: parsed.points))
            }
        }
        await progress?(segments.count, segments.count)
        return sections
    }

    /// Summaries are for the reader: the device language wins, with the
    /// session's target language as fallback.
    static func summaryLanguage(for record: SessionRecord) -> AppLanguage {
        AppLanguage.devicePreferred
            ?? record.entries.last?.direction.target ?? .english
    }

    /// Reduce phase: the final summary, written from notes alone. With
    /// `stitchDetails`, a detailed length on enough notes appends the
    /// per-segment sections; the mid-session "Summary so far" peek turns
    /// it off to stay a single fast generation. `progress` reports
    /// stitched-section counts (the core reduce stays a spinner).
    func reduce(
        notes: [SessionRecord.ChunkNote],
        style: SummaryStyle = .meeting,
        length: SummaryLength = .standard,
        transcriptCharacterCount: Int? = nil,
        in language: AppLanguage,
        stitchDetails: Bool = true,
        progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async throws -> String {
        let sizing = Self.summaryPromptSizing(
            style: style,
            length: length,
            transcriptCharacterCount: transcriptCharacterCount
                ?? notes.reduce(0) { $0 + $1.headline.count
                    + $1.facts.reduce(0) { $0 + $1.count }
                    + $1.decisions.reduce(0) { $0 + $1.count }
                    + $1.actions.reduce(0) { $0 + $1.count }
                },
            noteCount: notes.count)
        let reducePrompt = prompts.reduceSummaryPrompt(
            notes: Self.reduceInput(notes: notes, style: style),
            style: style, in: language, sizing: sizing)
        // One retry when the model ignores the tag format: small models
        // frequently produce the structured shape on a second attempt, and
        // the parsed form renders far more reliably than the plain-text
        // fallback below. Generation errors still propagate on the first try.
        var raw = ""
        var parsed = PromptBuilder.ParsedStructuredSummary(style: style)
        for attempt in 0..<2 {
            raw = try await llm.generate(
                system: reducePrompt.system, user: reducePrompt.user,
                maxTokens: sizing.maxTokens, temperature: 0.3)
            parsed = prompts.parseStructuredSummary(raw, style: style, sizing: sizing)
            if !parsed.isEmpty { break }
            if attempt == 0 { try Task.checkCancellation() }
        }
        let base: String
        if parsed.isEmpty {
            // Model ignored the tags — keep the cleaned plain text, which
            // the renderer's legacy paragraph/bullet path handles.
            let summary = prompts.cleanSummary(raw)
            guard !summary.isEmpty, !PromptBuilder.hasDegenerateRepetition(summary) else {
                throw SummaryError.generationFailed
            }
            base = summary
        } else {
            // Validate the content, not the synthesized "## "/"- " scaffolding.
            guard !PromptBuilder.hasDegenerateRepetition(parsed.joinedValues) else {
                throw SummaryError.generationFailed
            }
            base = prompts.renderSummaryMarkdown(parsed, in: language)
        }
        guard stitchDetails,
              Self.shouldStitchDetailSections(length: length, noteCount: notes.count)
        else { return base }
        let sections = await detailSections(
            for: Self.segmentNotes(notes), style: style, in: language,
            progress: progress)
        return Self.appendDetailSections(sections, to: base)
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
        try await llm.load(policy: .requireDownloaded)
        let (uncovered, cached) = Self.uncoveredEntries(of: record)
        // Estimate whether stitching will follow the map phase so the
        // progress denominator is stable from the start and never regresses.
        let mapChunks = Self.chunkEntries(uncovered).count
        let estimatedNoteCount = cached.count + mapChunks
        let stitchSegments = Self.shouldStitchDetailSections(
            length: length, noteCount: estimatedNoteCount)
            ? (estimatedNoteCount + Self.detailSegmentSize - 1) / Self.detailSegmentSize
            : 0
        let totalSteps = mapChunks + stitchSegments
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

enum SummaryError: LocalizedError {
    case generationFailed

    var errorDescription: String? {
        String(localized: "Summary failed — try again.")
    }
}
