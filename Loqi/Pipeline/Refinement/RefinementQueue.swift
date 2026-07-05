import Foundation
import os

/// Serial queue feeding finalized sentences to the LLM for transcript
/// cleanup, strictly one generation at a time. The caption stream never
/// waits on this: the raw sentence (and its Apple draft translation) is
/// already on screen; the cleaned sentence upgrades both when it lands.
actor RefinementQueue {
    struct Job: Sendable {
        var entryID: UUID
        var source: String
        var language: AppLanguage
        var context: [String] = []
        var glossary: [String] = []
    }

    /// What a finished job delivers: nil means "keep the raw source and
    /// the draft translation on screen".
    struct Outcome: Sendable {
        var cleanedSource: String?
    }

    /// Jobs beyond this depth drop oldest-first; their drafts stand.
    private let maxDepth = 2
    /// How long a job may wait for a silence gap before running anyway
    /// (so continuous lecture speech can't starve refinement forever).
    private let maxHoldoff: Duration = .seconds(4)

    private let llm: LLMService
    private let prompts = PromptBuilder()
    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "refine")
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
                switch try await prompts.refineSentence(
                    job.source, language: job.language,
                    context: job.context, glossary: job.glossary,
                    generate: { try await llm.generate(
                        system: $0, user: $1, maxTokens: $2) }) {
                case .cleaned(let cleaned):
                    outcome.cleanedSource = cleaned
                case .unchanged:
                    break   // the model found no errors — draft stands
                case .rejected(let raw):
                    // Raw sentence stays; log the output so a model whose
                    // cleanups keep getting discarded (repetition, rewrite,
                    // garbled decode) is distinguishable from one that
                    // never generated at all. .private: it derives from the
                    // user's speech — visible while debugging in Xcode,
                    // redacted in sysdiagnoses and Console.app.
                    logger.warning(
                        "refinement rejected, raw sentence kept: \(raw, privacy: .private)")
                }
            } catch {
                logger.warning(
                    "refinement generate failed, raw sentence kept: \(error.localizedDescription, privacy: .private)")
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
