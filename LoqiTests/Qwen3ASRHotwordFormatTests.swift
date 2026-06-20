import Testing

@testable import Loqi

#if os(iOS)
@Suite struct Qwen3ASRHotwordFormatTests {
    @Test func joinsWithCommas() {
        #expect(Qwen3ASRDecoder.hotwordString(from: ["北京", "上海"]) == "北京,上海")
    }

    @Test func dropsEmptyTermsSoNoDoubleComma() {
        #expect(Qwen3ASRDecoder.hotwordString(from: ["foo", "", "bar"]) == "foo,bar")
    }

    @Test func emptyInputIsEmptyString() {
        #expect(Qwen3ASRDecoder.hotwordString(from: []) == "")
    }
}
#endif
