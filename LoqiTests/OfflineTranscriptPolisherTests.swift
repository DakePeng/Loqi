import Foundation
import Testing

@testable import Loqi

/// Spec for the shared offline polish pass: deterministic hotword fixup →
/// gated LFM2.5 sentence cleanup → second fixup to catch LLM drift.
/// Generation is a closure, so ordering, gating, and rawSourceText
/// bookkeeping are tested without a model.
@MainActor
struct OfflineTranscriptPolisherTests {
    let qwen = Hotword(term: "Qwen", note: "model family")
    var polisher: OfflineTranscriptPolisher {
        OfflineTranscriptPolisher(matcher: HotwordMatcher(hotwords: [qwen]))
    }

    @Test func llmCleanupGateRespectsSettings() {
        #expect(OfflineTranscriptPolisher.shouldRunLLMCleanup(
            backend: .senseVoice, llmEnabled: true, refineModelDownloaded: true))
        #expect(OfflineTranscriptPolisher.shouldRunLLMCleanup(
            backend: .dolphin, llmEnabled: true, refineModelDownloaded: true))
        #expect(OfflineTranscriptPolisher.shouldRunLLMCleanup(
            backend: .apple, llmEnabled: true, refineModelDownloaded: true))
        #expect(!OfflineTranscriptPolisher.shouldRunLLMCleanup(
            backend: .senseVoice, llmEnabled: false, refineModelDownloaded: true))
        #expect(!OfflineTranscriptPolisher.shouldRunLLMCleanup(
            backend: .senseVoice, llmEnabled: true, refineModelDownloaded: false))
    }

    @Test func fixupRunsBeforeThePromptAndAfterTheCleanup() async throws {
        var capturedUser = ""
        let output = try await polisher.polish(
            ["Quen ships MLX"], language: .english, runLLMCleanup: true,
            generate: { _, user, _ in
                capturedUser = user
                // The model drifts back to the mishearing; pass 2 re-fixes.
                return "Quen ships MLX models"
            })
        // Pass 1 ran before the prompt was built.
        #expect(capturedUser.contains("Qwen ships MLX"))
        #expect(!capturedUser.contains("Quen"))
        // Accepted cleanup, then pass 2 corrected the drift.
        #expect(output.texts == ["Qwen ships MLX models"])
        // rawSourceText feed: the pre-cleanup (post-fixup-1) sentence.
        #expect(output.originals == [0: "Qwen ships MLX"])
    }

    @Test func rejectedCleanupKeepsTheFixedSentence() async throws {
        let output = try await polisher.polish(
            ["Quen ships MLX"], language: .english, runLLMCleanup: true,
            generate: { _, _, _ in "a totally unrelated reply about weather" })
        #expect(output.texts == ["Qwen ships MLX"])
        #expect(output.originals.isEmpty)
    }

    @Test func unchangedAcceptedCleanupRecordsNoOriginal() async throws {
        let output = try await polisher.polish(
            ["Qwen ships MLX"], language: .english, runLLMCleanup: true,
            generate: { _, _, _ in "Qwen ships MLX" })
        #expect(output.texts == ["Qwen ships MLX"])
        #expect(output.originals.isEmpty)
    }

    @Test func contextCarriesPreviousCleanedSentences() async throws {
        var prompts: [String] = []
        let output = try await polisher.polish(
            ["Alpha line one", "Beta line two", "Gamma line three"],
            language: .english, runLLMCleanup: true,
            generate: { _, user, _ in
                prompts.append(user)
                if user.contains("Sentence (English): Alpha line one") {
                    return "Alpha line one plus"
                }
                if user.contains("Beta") { return "Beta line two" }
                return "Gamma line three"
            })
        #expect(output.texts[0] == "Alpha line one plus")
        // The third prompt's context carries #0's CLEANED text.
        #expect(prompts[2].contains("Earlier lines"))
        #expect(prompts[2].contains("Alpha line one plus"))
    }

    @Test func glossaryLinesReachThePrompt() async throws {
        var capturedUser = ""
        _ = try await polisher.polish(
            ["Quen handles the decoding"], language: .english, runLLMCleanup: true,
            generate: { _, user, _ in
                capturedUser = user
                return "Qwen handles the decoding"
            })
        #expect(capturedUser.contains("Vocabulary"))
        #expect(capturedUser.contains("Qwen (model family)"))
    }

    @Test func generateFailuresAreBestEffort() async throws {
        struct Boom: Error {}
        var calls = 0
        let output = try await polisher.polish(
            ["Alpha line one", "Beta line two"],
            language: .english, runLLMCleanup: true,
            generate: { _, _, _ in
                calls += 1
                if calls == 1 { throw Boom() }
                return "Beta line two plus"
            })
        #expect(output.texts == ["Alpha line one", "Beta line two plus"])
        #expect(output.originals == [1: "Beta line two"])
    }

    @Test func modelNotDownloadedAbortsCleanupQuietly() async throws {
        var calls = 0
        let output = try await polisher.polish(
            ["Quen line one", "Beta line two", "Gamma line three"],
            language: .english, runLLMCleanup: true,
            generate: { _, _, _ in
                calls += 1
                throw LLMServiceError.modelNotDownloaded
            })
        #expect(calls == 1)
        // Fixup-1 output survives; no cleanup applied anywhere.
        #expect(output.texts == ["Qwen line one", "Beta line two", "Gamma line three"])
        #expect(output.originals.isEmpty)
    }

    @Test func cancellationRethrows() async {
        await #expect(throws: CancellationError.self) {
            _ = try await polisher.polish(
                ["Alpha line one"], language: .english, runLLMCleanup: true,
                generate: { _, _, _ in throw CancellationError() })
        }
    }

    @Test func noLLMCleanupStillRunsDeterministicFixup() async throws {
        var calls = 0
        var fractions: [Double] = []
        let output = try await polisher.polish(
            ["Quen ships MLX"], language: .english, runLLMCleanup: false,
            generate: { _, _, _ in calls += 1; return "" },
            onProgress: { fractions.append($0) })
        #expect(output.texts == ["Qwen ships MLX"])
        #expect(calls == 0)
        #expect(fractions.isEmpty)
    }

    @Test func punctuationOnlyLinesSkipGeneration() async throws {
        var calls = 0
        let output = try await polisher.polish(
            ["…", "Alpha line one"], language: .english, runLLMCleanup: true,
            generate: { _, _, _ in calls += 1; return "Alpha line one" })
        #expect(calls == 1)
        #expect(output.texts == ["…", "Alpha line one"])
    }

    @Test func progressReportsPerEntry() async throws {
        var fractions: [Double] = []
        _ = try await polisher.polish(
            ["Alpha line one", "Beta line two", "Gamma line three"],
            language: .english, runLLMCleanup: true,
            generate: { _, user, _ in
                if user.contains("Alpha") { return "Alpha line one" }
                if user.contains("Beta") { return "Beta line two" }
                return "Gamma line three"
            },
            onProgress: { fractions.append($0) })
        #expect(fractions == [0, 1.0 / 3.0, 2.0 / 3.0, 1])
    }
}
