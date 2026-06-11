import Testing
@testable import Locally

struct TranscriptSegmenterTests {
    let segmenter = TranscriptSegmenter()

    @Test func volatileTextPassesThroughTrimmed() {
        let output = segmenter.process(.volatile("  hello there "), language: .english)
        #expect(output?.kind == .volatileUpdate)
        #expect(output?.text == "hello there")
    }

    @Test func emptyVolatileIsIgnored() {
        #expect(segmenter.process(.volatile("   "), language: .english) == nil)
    }

    @Test func emptyFinalDiscardsEntry() {
        let output = segmenter.process(.finalized("  "), language: .english)
        #expect(output?.kind == .discard)
    }

    @Test func shortEnglishFinalSkipsRefinement() {
        let output = segmenter.process(.finalized("Thank you"), language: .english)
        #expect(output?.kind == .finalized(refine: false))
    }

    @Test func longEnglishFinalGetsRefinement() {
        let output = segmenter.process(
            .finalized("Could you tell me how much this would cost with shipping?"),
            language: .english)
        #expect(output?.kind == .finalized(refine: true))
    }

    @Test func shortCJKFinalSkipsRefinement() {
        let output = segmenter.process(.finalized("谢谢你"), language: .chinese)
        #expect(output?.kind == .finalized(refine: false))
    }

    @Test func longCJKFinalGetsRefinement() {
        let output = segmenter.process(
            .finalized("お世話になっております。価格についてご相談したいのですが。"),
            language: .japanese)
        #expect(output?.kind == .finalized(refine: true))
    }

    @Test func endedEventProducesNothing() {
        #expect(segmenter.process(.ended(nil), language: .english) == nil)
    }
}
