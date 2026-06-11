import Foundation

/// Serial queue feeding finalized sentences to the LLM, strictly one
/// generation at a time. The caption stream never waits on this: drafts are
/// already on screen, refinement upgrades them when it lands.
actor RefinementQueue {
    struct Job: Sendable {
        var entryID: UUID
        var source: String
        var draft: String
        var direction: LanguagePair
        var history: [PromptBuilder.HistoryTurn]
        var glossary: [String] = []
        /// Also ask the model to lightly clean the transcript text.
        var cleanSource: Bool = false
    }

    /// What a finished job delivers: either field nil means "keep what's
    /// on screen" for that half.
    struct Outcome: Sendable {
        var translation: String?
        var cleanedSource: String?
    }

    /// Jobs beyond this depth drop oldest-first; their drafts stand.
    private let maxDepth = 2
    /// How long a job may wait for a silence gap before running anyway
    /// (so continuous lecture speech can't starve refinement forever).
    private let maxHoldoff: Duration = .seconds(4)

    private let llm: LLMService
    private let prompts = PromptBuilder()
    private var pending: [Job] = []
    private var worker: Task<Void, Never>?
    private var paused = false
    private var speechActive = false

    /// Called on the main actor with each result.
    private let deliver: @MainActor @Sendable (UUID, Outcome) -> Void

    init(llm: LLMService, deliver: @escaping @MainActor @Sendable (UUID, Outcome) -> Void) {
        self.llm = llm
        self.deliver = deliver
    }

    func enqueue(_ job: Job) {
        guard !paused else { return }
        pending.append(job)
        if pending.count > maxDepth {
            let dropped = pending.removeFirst()
            Task { @MainActor [deliver] in deliver(dropped.entryID, Outcome()) }
        }
        ensureWorker()
    }

    /// GPU generation contends with the ASR model for memory bandwidth and
    /// makes live captions lag. While the user is speaking, hold the queue;
    /// drain during silence gaps.
    func setSpeechActive(_ active: Bool) {
        speechActive = active
        if !active { ensureWorker() }
    }

    /// Thermal ladder hook: pause keeps the model loaded but drains nothing
    /// new; existing queue entries fall back to their drafts.
    func setPaused(_ value: Bool) {
        paused = value
        if value {
            for job in pending {
                Task { @MainActor [deliver] in deliver(job.entryID, Outcome()) }
            }
            pending.removeAll()
        }
    }

    func cancelAll() {
        pending.removeAll()
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
        while let job = nextJob() {
            // Wait for a quiet moment so generation never competes with
            // live speech — but never longer than maxHoldoff.
            let deadline = ContinuousClock.now.advanced(by: maxHoldoff)
            while speechActive, ContinuousClock.now < deadline, !paused {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if paused {
                Task { @MainActor [deliver] in deliver(job.entryID, Outcome()) }
                continue
            }

            var outcome = Outcome()
            do {
                // Transcribe-only sessions enqueue with an empty draft:
                // polish the transcript, no translation to refine.
                let polishOnly = job.draft.isEmpty && job.cleanSource
                let raw: String
                if polishOnly {
                    raw = try await llm.generate(
                        system: prompts.polishSystemPrompt(language: job.direction.source),
                        user: "Sentence: \(job.source)",
                        maxTokens: 120)
                } else {
                    raw = try await llm.generate(
                        system: prompts.systemPrompt(
                            direction: job.direction, cleanSource: job.cleanSource),
                        user: prompts.userPrompt(
                            source: job.source,
                            draft: job.draft,
                            direction: job.direction,
                            history: job.history,
                            glossary: job.glossary),
                        maxTokens: job.cleanSource ? 220 : 120)
                }
                let parsed = prompts.parseRefinement(raw)
                if !polishOnly, let translation = parsed.translation,
                   prompts.isAcceptable(translation, draft: job.draft) {
                    outcome.translation = translation
                }
                if job.cleanSource, let cleaned = parsed.cleanedSource,
                   prompts.isAcceptableSourceCleanup(cleaned, original: job.source) {
                    outcome.cleanedSource = cleaned
                }
            } catch {
                outcome = Outcome()
            }
            let entryID = job.entryID
            let final = outcome
            await MainActor.run { [deliver] in deliver(entryID, final) }
        }
        worker = nil
    }

    private func nextJob() -> Job? {
        guard !paused, !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}
