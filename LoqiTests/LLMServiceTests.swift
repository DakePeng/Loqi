import Foundation
import Testing

@testable import Loqi

/// Memory-admission decision for model loads. The full/tight band exists so
/// running SenseVoice (in-process ONNX) alongside the 2B model degrades to a
/// smaller MLX cache instead of refusing to load.
struct LLMServiceTests {
    private let headroom = ModelCatalog.qwen35_2b.requiredHeadroom
    private static let fullCache = 256 * 1024 * 1024
    private static let tightCache = 64 * 1024 * 1024
    /// Band width: exactly the footprint the tight cache gives back.
    private static let band = UInt64(fullCache - tightCache)

    @Test func comfortableMemoryAdmitsWithFullCache() {
        #expect(LLMService.admittedCacheLimit(
            free: headroom + 1, requiredHeadroom: headroom) == Self.fullCache)
    }

    @Test func tightMemoryShrinksCacheInsteadOfFailing() {
        // Weights fit, full cache does not — both edges of the band.
        #expect(LLMService.admittedCacheLimit(
            free: headroom, requiredHeadroom: headroom) == Self.tightCache)
        #expect(LLMService.admittedCacheLimit(
            free: headroom - Self.band + 1, requiredHeadroom: headroom) == Self.tightCache)
    }

    @Test func insufficientMemoryRefusesLoad() {
        #expect(LLMService.admittedCacheLimit(
            free: headroom - Self.band, requiredHeadroom: headroom) == nil)
        #expect(LLMService.admittedCacheLimit(
            free: 0, requiredHeadroom: headroom) == nil)
    }
}

/// `<think>` leakage from hybrid models is stripped, never asserted on —
/// one leaked token must not crash a recording.
struct StripThinkingTests {
    @Test func stripsClosedSpan() {
        #expect(LLMService.stripThinking("<think>reasoning</think>答案在这里")
            == "答案在这里")
    }

    @Test func stripsUnterminatedTrailingSpan() {
        #expect(LLMService.stripThinking("Answer first. <think>then it trailed off")
            == "Answer first.")
    }

    @Test func leavesCleanTextAlone() {
        #expect(LLMService.stripThinking("纪要：发布定于7月10日")
            == "纪要：发布定于7月10日")
    }
}

struct DiagnosticTokenEstimateTests {
    @Test func usesOnePointFiveContentCharsPerToken() {
        #expect(LLMService.estimatedDiagnosticTokens(in: "发布定于七月十日") == 8 / 1.5)
    }

    @Test func ignoresPunctuationAndWhitespace() {
        let plain = LLMService.estimatedDiagnosticTokens(in: "发布定于七月十日")
        let punctuated = LLMService.estimatedDiagnosticTokens(in: "发布，定于七月十日。\n")
        #expect(punctuated == plain)
    }
}
