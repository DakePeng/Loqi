import Foundation
import Testing

@testable import Loqi

struct SessionHeatStatsTests {
    @Test func accumulatesPerComponent() {
        var stats = SessionHeatStats()
        stats.add(llm: 1.5)
        stats.add(llm: 0.5)
        stats.add(asr: 4.0)
        #expect(stats.llmActiveSeconds == 2.0)
        #expect(stats.asrActiveSeconds == 4.0)
    }

    @Test func dominantPicksLargerComponent() {
        #expect(SessionHeatStats.dominant(llmSeconds: 5, asrSeconds: 40) == "ASR")
        #expect(SessionHeatStats.dominant(llmSeconds: 30, asrSeconds: 10) == "LLM")
    }

    @Test func dominantIsDashWhenIdle() {
        #expect(SessionHeatStats.dominant(llmSeconds: 0, asrSeconds: 0) == "—")
    }

    @Test func dominantNeedsAClearMargin() {
        // Within 20% is "≈" — neither clearly drives heat.
        #expect(SessionHeatStats.dominant(llmSeconds: 10, asrSeconds: 11) == "≈")
    }
}
