import Testing

@testable import Loqi

struct SummaryDiffTests {
    @Test func latinInsertionIsExtracted() {
        let spans = SummaryDiff.insertedSpans(
            old: "We discussed the budget today",
            new: "We discussed the Qwen budget today")
        #expect(spans == ["Qwen"])
    }

    @Test func cjkInsertionIsExtracted() {
        // ICU segments CJK without spaces; tolerate tokenizer granularity by
        // checking containment rather than exact span boundaries.
        let spans = SummaryDiff.insertedSpans(
            old: "我们讨论了预算",
            new: "我们和罗伯特讨论了预算")
        #expect(spans.joined().contains("罗伯特"))
        #expect(!spans.joined().contains("预算"))
    }

    @Test func adjacentInsertionsMergeIntoOneSpan() {
        let spans = SummaryDiff.insertedSpans(
            old: "Action items follow",
            new: "Action items from Robert Smith follow")
        #expect(spans == ["from Robert Smith"])
    }

    @Test func deletionOnlyYieldsNothing() {
        let spans = SummaryDiff.insertedSpans(
            old: "We discussed the budget today",
            new: "We discussed the budget")
        #expect(spans.isEmpty)
    }

    @Test func identicalTextYieldsNothing() {
        #expect(SummaryDiff.insertedSpans(old: "same text", new: "same text").isEmpty)
    }

    @Test func casingFixIsSignal() {
        // The LCS is case-sensitive on purpose: "qwen" → "Qwen" is exactly
        // the kind of correction worth mining.
        let spans = SummaryDiff.insertedSpans(
            old: "the qwen model", new: "the Qwen model")
        #expect(spans == ["Qwen"])
    }

    @Test func maxSpansCapsTheResult() {
        let spans = SummaryDiff.insertedSpans(
            old: "a b c d e",
            new: "a X b Y c Z d W e",
            maxSpans: 3)
        #expect(spans.count == 3)
    }

    @Test func emptyOldMarksEverythingInserted() {
        let spans = SummaryDiff.insertedSpans(old: "", new: "Robert joined")
        #expect(spans == ["Robert joined"])
    }
}
