import Testing
@testable import Loqi

struct TranscriptSegmenterTests {
    let segmenter = TranscriptSegmenter()

    @Test func volatileTextPassesThroughTrimmed() {
        let output = segmenter.process(
            .volatile("  hello there ", language: nil),
            fallbackLanguage: .english)
        #expect(output?.kind == .volatileUpdate)
        #expect(output?.text == "hello there")
    }

    @Test func emptyVolatileIsIgnored() {
        #expect(segmenter.process(
            .volatile("   ", language: nil),
            fallbackLanguage: .english) == nil)
    }

    @Test func emptyFinalDiscardsEntry() {
        let output = segmenter.process(
            .finalized("  ", runs: nil, language: nil),
            fallbackLanguage: .english)
        #expect(output?.kind == .discard)
    }

    @Test func punctuationOnlyFinalDiscardsEntry() {
        // Silence/noise yields lone-dot finals ("." / "。"); they must not
        // become entries.
        #expect(segmenter.process(
            .finalized("。", runs: nil, language: nil), fallbackLanguage: .chinese)?.kind == .discard)
        #expect(segmenter.process(
            .finalized(" . ", runs: nil, language: nil), fallbackLanguage: .english)?.kind == .discard)
        // And the volatile equivalent is ignored outright.
        #expect(segmenter.process(
            .volatile("。", language: nil), fallbackLanguage: .chinese) == nil)
    }

    @Test func shortEnglishFinalSkipsRefinement() {
        let output = segmenter.process(
            .finalized("Thank you", runs: nil, language: nil),
            fallbackLanguage: .english)
        #expect(output?.kind == .finalized(refine: false))
    }

    @Test func longEnglishFinalGetsRefinement() {
        let output = segmenter.process(
            .finalized("Could you tell me how much this would cost with shipping?", runs: nil, language: nil),
            fallbackLanguage: .english)
        #expect(output?.kind == .finalized(refine: true))
    }

    @Test func shortCJKFinalSkipsRefinement() {
        let output = segmenter.process(
            .finalized("谢谢你", runs: nil, language: nil),
            fallbackLanguage: .chinese)
        #expect(output?.kind == .finalized(refine: false))
    }

    @Test func longCJKFinalGetsRefinement() {
        let output = segmenter.process(
            .finalized("お世話になっております。価格についてご相談したいのですが。", runs: nil, language: nil),
            fallbackLanguage: .japanese)
        #expect(output?.kind == .finalized(refine: true))
    }

    @Test func detectedLanguageOverridesFallback() {
        let output = segmenter.process(
            .finalized("谢谢大家", runs: nil, language: .chinese),
            fallbackLanguage: .english)
        #expect(output?.language == .chinese)
        #expect(output?.languageWasDetected == true)
    }

    @Test func endedEventProducesNothing() {
        #expect(segmenter.process(.ended(nil), fallbackLanguage: .english) == nil)
    }
}
