import Foundation
import os

/// Generates chunk notes during a live session without ever competing with
/// live speech: an in-flight generation is CANCELLED the moment speech
/// resumes and retried at the next silence. Deliberately separate from
/// RefinementQueue — refinement may drop jobs (drafts stand) and forces
/// through continuous speech; notes must stay contiguous and must never
/// hold the LLM while someone talks.
actor ChunkNoteQueue {
    struct Job: Sendable {
        var chunkText: String
        var anchorEntryID: UUID
        var endEntryID: UUID
        var startedAt: Date
        var fallbackHeadline: String
        var language: AppLanguage
        var retries = 0
    }

    private let llm: LLMService
    private let prompts = PromptBuilder()
    private var pending: [Job] = []
    private var speechActive = false
    private var worker: Task<Void, Never>?
    private var generation: Task<String, Error>?
    private let maxRetries = 3

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "livenotes")

    /// Delivered on the main actor, in chunk order.
    private let deliver: @MainActor @Sendable (SessionRecord.ChunkNote, UUID) -> Void

    init(
        llm: LLMService,
        deliver: @escaping @MainActor @Sendable (SessionRecord.ChunkNote, UUID) -> Void
    ) {
        self.llm = llm
        self.deliver = deliver
    }

    func enqueue(_ job: Job) {
        pending.append(job)
        ensureWorker()
    }

    func setSpeechActive(_ active: Bool) {
        speechActive = active
        if active {
            // Yield the LLM to live captions immediately.
            generation?.cancel()
        } else {
            ensureWorker()
        }
    }

    func cancelAll() {
        pending.removeAll()
        generation?.cancel()
        worker?.cancel()
        worker = nil
    }

    private func ensureWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            // Notes only run in silence; no holdoff override (unlike
            // refinement) — a chunk can always wait.
            while speechActive {
                if Task.isCancelled { worker = nil; return }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard var job = pending.first else { break }
            pending.removeFirst()

            let prompt = prompts.chunkNotePrompt(
                chunkText: job.chunkText, in: job.language)
            let task = Task { [llm] in
                try await llm.generate(
                    system: prompt.system, user: prompt.user,
                    maxTokens: 170, temperature: 0.3)
            }
            generation = task
            do {
                let raw = try await task.value
                generation = nil
                deliverNote(parsed: prompts.parseChunkNote(raw), job: job)
            } catch is CancellationError {
                generation = nil
                job.retries += 1
                if job.retries <= maxRetries {
                    pending.insert(job, at: 0)  // keep chunk order
                } else {
                    deliverNote(parsed: PromptBuilder.ParsedChunkNote(), job: job)
                }
            } catch {
                generation = nil
                logger.warning("chunk note failed: \(error)")
                // Fallback note preserves contiguous coverage.
                deliverNote(parsed: PromptBuilder.ParsedChunkNote(), job: job)
            }
        }
        worker = nil
    }

    private func deliverNote(parsed: PromptBuilder.ParsedChunkNote, job: Job) {
        let note = SessionRecord.ChunkNote(
            headline: parsed.headline ?? job.fallbackHeadline,
            startedAt: job.startedAt,
            anchorEntryID: job.anchorEntryID,
            facts: parsed.facts,
            decisions: parsed.decisions,
            actions: parsed.actions,
            terms: parsed.terms)
        let endID = job.endEntryID
        Task { @MainActor [deliver] in deliver(note, endID) }
    }
}
