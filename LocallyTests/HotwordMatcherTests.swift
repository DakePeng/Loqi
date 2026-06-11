import Testing
@testable import Locally

struct HotwordMatcherTests {
    let zhipeng = Hotword(
        term: "Zhipeng",
        renderings: [.english: "Zhipeng", .chinese: "志鹏"],
        note: "person name")
    let qwen = Hotword(term: "Qwen", note: "model family")
    let locally = Hotword(
        term: "Locally",
        renderings: [.chinese: "Locally"],
        note: "app name, keep untranslated")

    var matcher: HotwordMatcher {
        HotwordMatcher(hotwords: [zhipeng, qwen, locally])
    }

    // MARK: Latin fixup

    @Test func fixesLatinNearMiss() {
        let fixed = matcher.fixup("I showed Zhipemg the app", language: .english)
        #expect(fixed == "I showed Zhipeng the app")
    }

    @Test func normalizesCasingOfExactMatch() {
        let fixed = matcher.fixup("ask zhipeng about it", language: .english)
        #expect(fixed == "ask Zhipeng about it")
    }

    @Test func leavesUnrelatedTextAlone() {
        let text = "the weather is nice today"
        #expect(matcher.fixup(text, language: .english) == text)
    }

    @Test func doesNotMangleDistantWords() {
        // "model" must not become "Qwen"-anything; similarity is far below
        // the replacement threshold.
        let text = "the model works"
        #expect(matcher.fixup(text, language: .english) == text)
    }

    // MARK: CJK fixup

    @Test func fixesChineseHomophone() {
        // 智朋 is a homophone near-miss for 志鹏 (both zhipeng).
        let fixed = matcher.fixup("我把APP给智朋看了", language: .chinese)
        #expect(fixed == "我把APP给志鹏看了")
    }

    @Test func keepsCorrectChineseUntouched() {
        let text = "我把APP给志鹏看了"
        #expect(matcher.fixup(text, language: .chinese) == text)
    }

    @Test func fixesLatinRunInsideChinese() {
        let fixed = matcher.fixup("这个locally应用不错", language: .chinese)
        #expect(fixed == "这个Locally应用不错")
    }

    // MARK: Scoring / refinement triggers

    @Test func nearMissForcesRefinement() {
        #expect(matcher.shouldForceRefine("hi Zhipemg", language: .english))
        #expect(!matcher.shouldForceRefine("hello there", language: .english))
    }

    @Test func glossaryIncludesMatchedTermsOnly() {
        let lines = matcher.glossaryLines(
            direction: LanguagePair(source: .english, target: .chinese),
            sourceText: "tell Zhipeng about it")
        #expect(lines.contains { $0.contains("Zhipeng → 志鹏 (person name)") })
        #expect(!lines.contains { $0.contains("Qwen") })
    }

    // MARK: Primitives

    @Test func pinyinEquatesHomophones() {
        #expect(HotwordMatcher.pinyin("志鹏") == HotwordMatcher.pinyin("智朋"))
        #expect(HotwordMatcher.pinyin("志鹏") != HotwordMatcher.pinyin("你好"))
    }

    @Test func levenshteinBasics() {
        #expect(HotwordMatcher.levenshtein(Array("kitten"), Array("sitting")) == 3)
        #expect(HotwordMatcher.similarity("zhipeng", "zhipemg") > 0.84)
    }

    @Test func hotwordRenderingFallsBackToTerm() {
        #expect(qwen.rendering(for: .japanese) == "Qwen")
        #expect(zhipeng.rendering(for: .chinese) == "志鹏")
    }
}
