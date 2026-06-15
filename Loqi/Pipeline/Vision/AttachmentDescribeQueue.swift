import Foundation
import os

/// Generates VLM descriptions for attached photos without competing with
/// live speech — the ChunkNoteQueue yielding contract: an in-flight
/// generation is cancelled the moment speech resumes, and backgrounded
/// sessions hold jobs (Metal work in the background risks termination).
/// Unlike chunk notes there is no contiguity requirement: when the retry
/// budget runs out the job is dropped and the photo keeps its OCR text.
actor AttachmentDescribeQueue {
    struct Job: Sendable {
        var attachmentID: UUID
        var sessionID: UUID
        var fileURL: URL
        var language: AppLanguage
        var retries = 0
    }

    private let llm: LLMService
    private let prompts = PromptBuilder()
    private var pending: [Job] = []
    private var speechActive = false
    private var paused = false
    private var worker: Task<Void, Never>?
    private var generation: Task<String, Error>?
    private let maxRetries = 3

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "describe")

    /// (description, attachmentID, sessionID), on the main actor.
    private let deliver: @MainActor @Sendable (String, UUID, UUID) -> Void

    init(
        llm: LLMService,
        deliver: @escaping @MainActor @Sendable (String, UUID, UUID) -> Void
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
            generation?.cancel()
        } else {
            ensureWorker()
        }
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value {
            generation?.cancel()
        } else {
            for index in pending.indices { pending[index].retries = 0 }
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
            while speechActive || paused {
                if Task.isCancelled { worker = nil; return }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard var job = pending.first else { break }
            pending.removeFirst()

            let prompt = prompts.imageDescriptionPrompt(in: job.language)
            let task = Task { [llm, job] in
                try await llm.describeImage(
                    at: job.fileURL, system: prompt.system, user: prompt.user)
            }
            generation = task
            do {
                let raw = try await task.value
                generation = nil
                let text = prompts.cleanResponse(raw)
                guard !text.isEmpty, !PromptBuilder.hasDegenerateRepetition(text)
                else { continue }
                let delivered = job
                Task { @MainActor [deliver] in
                    deliver(text, delivered.attachmentID, delivered.sessionID)
                }
            } catch is CancellationError {
                generation = nil
                job.retries += 1
                if job.retries <= maxRetries {
                    pending.insert(job, at: 0)
                }
            } catch {
                generation = nil
                // Dropped — OCR text stands; nothing to retry into.
                logger.warning("attachment description failed: \(error)")
            }
        }
        worker = nil
    }
}
