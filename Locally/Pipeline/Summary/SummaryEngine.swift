import Foundation

/// Map-reduce summarization sized for a small on-device model: chunk the
/// transcript at natural boundaries, extract tagged notes per chunk (the
/// narrow task small models do well), then write the final summary from
/// the notes alone — the model never has to synthesize a long raw
/// transcript, and nothing gets silently truncated.
struct SummaryEngine {
    let llm: LLMService
    private let prompts = PromptBuilder()

    /// Character budget per chunk (≈ tokens for CJK); keeps per-chunk
    /// prefill in the seconds range.
    static let chunkBudget = 1100
    /// A pause this long always starts a new chunk.
    static let chunkGap: TimeInterval = 25

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

    /// Map + reduce. `progress` reports (completedChunks, totalChunks)
    /// during the map phase.
    func summarize(
        _ record: SessionRecord,
        in language: AppLanguage,
        progress: @MainActor @Sendable (Int, Int) -> Void
    ) async throws -> (summary: String, notes: [SessionRecord.ChunkNote]) {
        try await llm.load()
        let chunks = Self.chunkEntries(record.entries)
        var notes: [SessionRecord.ChunkNote] = []

        for (index, chunk) in chunks.enumerated() {
            await progress(index, chunks.count)
            let text = chunk.map { entry in
                let speaker = record.speakerLabel(entry.speaker).map { "[\($0)] " } ?? ""
                return speaker + entry.sourceText
            }.joined(separator: "\n")

            let prompt = prompts.chunkNotePrompt(chunkText: text, in: language)
            let parsed: PromptBuilder.ParsedChunkNote
            do {
                let raw = try await llm.generate(
                    system: prompt.system, user: prompt.user,
                    maxTokens: 170, temperature: 0.3)
                parsed = prompts.parseChunkNote(raw)
            } catch {
                parsed = PromptBuilder.ParsedChunkNote()
            }

            notes.append(SessionRecord.ChunkNote(
                // A chunk whose extraction failed still gets an outline
                // entry: fall back to its opening words.
                headline: parsed.headline
                    ?? String(chunk.first?.sourceText.prefix(24) ?? "…"),
                startedAt: chunk.first?.timestamp ?? record.startedAt,
                anchorEntryID: chunk.first?.id,
                facts: parsed.facts,
                decisions: parsed.decisions,
                actions: parsed.actions,
                terms: parsed.terms))
        }
        await progress(chunks.count, chunks.count)

        let notesText = notes.enumerated().map { index, note in
            var lines = ["[\(index + 1)] \(note.headline)"]
            lines.append(contentsOf: note.facts.map { "fact: \($0)" })
            lines.append(contentsOf: note.decisions.map { "decision: \($0)" })
            lines.append(contentsOf: note.actions.map { "action: \($0)" })
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")

        let reducePrompt = prompts.reduceSummaryPrompt(notes: notesText, in: language)
        let raw = try await llm.generate(
            system: reducePrompt.system, user: reducePrompt.user,
            maxTokens: 320, temperature: 0.3)
        let summary = prompts.cleanSummary(raw)
        guard !summary.isEmpty, !PromptBuilder.hasDegenerateRepetition(summary) else {
            throw SummaryError.generationFailed
        }
        return (summary, notes)
    }
}

enum SummaryError: LocalizedError {
    case generationFailed

    var errorDescription: String? {
        String(localized: "Summary failed — try again.")
    }
}
