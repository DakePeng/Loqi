import Foundation
import Testing
@testable import Loqi

struct SummaryLengthTests {
    @Test func detailedLengthScalesWithTranscriptButHitsHardCap() {
        let short = SummaryEngine.summaryPromptSizing(
            style: .meeting,
            length: .detailed,
            transcriptCharacterCount: 800,
            noteCount: 2)
        let long = SummaryEngine.summaryPromptSizing(
            style: .meeting,
            length: .detailed,
            transcriptCharacterCount: 20_000,
            noteCount: 30)

        #expect(long.maxTokens > short.maxTokens)
        #expect(long.maxTokens == SummaryEngine.summaryMaxTokensHardCap)
        #expect(long.overviewCap <= SummaryEngine.summaryOverviewHardCap)
        #expect(long.sectionCaps.allSatisfy { $0 <= SummaryEngine.summarySectionHardCap })
    }

    @Test func standardLongTranscriptIsFullerThanConciseLongTranscript() {
        let concise = SummaryEngine.summaryPromptSizing(
            style: .meeting,
            length: .concise,
            transcriptCharacterCount: 8_000,
            noteCount: 12)
        let standard = SummaryEngine.summaryPromptSizing(
            style: .meeting,
            length: .standard,
            transcriptCharacterCount: 8_000,
            noteCount: 12)

        #expect(standard.maxTokens > concise.maxTokens)
        #expect(standard.overviewCap >= concise.overviewCap)
        #expect(zip(standard.sectionCaps, concise.sectionCaps).allSatisfy { $0 >= $1 })
    }

    /// Mirror of SummaryStyle.effective: stored raw wins, legacy summary
    /// without one shows standard, else the default (falling back on junk).
    @Test func effectiveLengthResolution() {
        #expect(SummaryLength.effective(
            storedRaw: "detailed", hasSummary: true, defaultRaw: "concise") == .detailed)
        #expect(SummaryLength.effective(
            storedRaw: nil, hasSummary: true, defaultRaw: "concise") == .standard)
        #expect(SummaryLength.effective(
            storedRaw: "??", hasSummary: true, defaultRaw: "concise") == .standard)
        #expect(SummaryLength.effective(
            storedRaw: nil, hasSummary: false, defaultRaw: "concise") == .concise)
        #expect(SummaryLength.effective(
            storedRaw: nil, hasSummary: false, defaultRaw: "junk") == .standard)
    }

}
