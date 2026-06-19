import Testing
@testable import Loqi

struct HotwordMatcherTests {
    let zhipeng = Hotword(
        term: "Zhipeng",
        renderings: [.english: "Zhipeng", .chinese: "志鹏"],
        note: "person name")
    let qwen = Hotword(term: "Qwen", note: "model family")
    let loqi = Hotword(
        term: "Loqi",
        renderings: [.chinese: "Loqi"],
        note: "app name, keep untranslated")

    var matcher: HotwordMatcher {
        HotwordMatcher(hotwords: [zhipeng, qwen, loqi])
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
        let fixed = matcher.fixup("这个loqi应用不错", language: .chinese)
        #expect(fixed == "这个Loqi应用不错")
    }

    @Test func fixesCJKNonHomophoneNearMiss() {
        // 治平 (zhiping) is a near-miss — not an exact homophone — for 志鹏
        // (zhipeng). Fuzzy pinyin catches it; strict homophone matching did not.
        let fixed = matcher.fixup("我把APP给治平看了", language: .chinese)
        #expect(fixed == "我把APP给志鹏看了")
    }

    @Test func fixesLatinMidThresholdNearMiss() {
        // "Anthrpc" → "Anthropic" is ~0.78 similar: above the new 0.75 bar,
        // below the old 0.84 one.
        let m = HotwordMatcher(hotwords: [Hotword(term: "Anthropic", note: "company")])
        let fixed = m.fixup("we use Anthrpc daily", language: .english)
        #expect(fixed == "we use Anthropic daily")
    }

    @Test func keepsDistinctCJKWordSharingPinyinPrefix() {
        // 支持 (zhichi) shares the "zhi" pinyin prefix with 志鹏 (zhipeng) but
        // is a common, distinct word (~0.43 similar) — well under the 0.75
        // replace bar. Guards against the fuzzy CJK matcher over-replacing.
        let text = "我很支持这个想法"
        #expect(matcher.fixup(text, language: .chinese) == text)
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

    // MARK: Aliases

    let robert = Hotword(
        term: "Robert Smith",
        renderings: [.chinese: "罗伯特"],
        note: "person name",
        aliases: ["Bobby", "Roberto", "小罗"])

    var aliasMatcher: HotwordMatcher { HotwordMatcher(hotwords: [robert]) }

    @Test func aliasRestoresItsOwnSpellingNotTheTerm() {
        // The key alias guarantee: fixup must not rewrite what was said.
        let cased = aliasMatcher.fixup("i told bobby yesterday", language: .english)
        #expect(cased == "i told Bobby yesterday")
        let nearMiss = aliasMatcher.fixup("call Robertto today", language: .english)
        #expect(nearMiss == "call Roberto today")
    }

    @Test func cjkAliasHomophoneRestoresAlias() {
        // 小萝 is a homophone near-miss for the alias 小罗 (both xiaoluo);
        // it comes back as the alias, not as 罗伯特.
        let fixed = aliasMatcher.fixup("把文件发给小萝", language: .chinese)
        #expect(fixed == "把文件发给小罗")
    }

    @Test func aliasForcesRefinement() {
        #expect(aliasMatcher.shouldForceRefine("call Robertto", language: .english))
    }

    @Test func glossaryLineCarriesAliases() {
        let lines = aliasMatcher.glossaryLines(
            direction: LanguagePair(source: .english, target: .chinese),
            sourceText: "Bobby said hi")
        #expect(lines.contains {
            $0.contains("Robert Smith (aka Bobby, Roberto, 小罗) → 罗伯特 (person name)")
        })
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
