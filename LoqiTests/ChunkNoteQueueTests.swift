import Foundation
import Testing
@testable import Loqi

/// Pause semantics for background continuation. Runs in the simulator:
/// the LLM is never loaded, so an unpaused drain hits modelNotLoaded
/// before touching MLX — exactly the fallback-note path.
struct ChunkNoteQueueTests {
    @MainActor final class NoteSink {
        var notes: [SessionRecord.ChunkNote] = []
    }

    private func makeJob() -> ChunkNoteQueue.Job {
        .init(
            chunkText: "hello world",
            anchorEntryID: UUID(),
            endEntryID: UUID(),
            startedAt: .now,
            fallbackHeadline: "hello",
            language: .english)
    }

    @Test func pausedQueueHoldsJobsAndUnpauseDrains() async throws {
        let sink = await NoteSink()
        let queue = ChunkNoteQueue(llm: LLMService()) { note, _ in
            sink.notes.append(note)
        }

        await queue.setPaused(true)
        await queue.enqueue(makeJob())
        // Held: nothing may be delivered while paused (drain polls 250ms).
        try await Task.sleep(for: .milliseconds(700))
        #expect(await sink.notes.isEmpty)

        await queue.setPaused(false)
        var polls = 0
        while await sink.notes.isEmpty, polls < 40 {
            try await Task.sleep(for: .milliseconds(100))
            polls += 1
        }
        // Unpaused with no model loaded → the fallback note preserves
        // contiguous coverage.
        #expect(await sink.notes.count == 1)
        #expect(await sink.notes.first?.headline == "hello")
    }
}
