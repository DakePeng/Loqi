import Testing
@testable import Locally

struct PromptBuilderTests {
    let builder = PromptBuilder()
    let zhToJa = LanguagePair(source: .chinese, target: .japanese)

    @Test func systemPromptNamesBothLanguages() {
        let prompt = builder.systemPrompt(direction: zhToJa)
        #expect(prompt.contains("Chinese"))
        #expect(prompt.contains("Japanese"))
        #expect(prompt.contains("Output ONLY"))
    }

    @Test func userPromptContainsSourceAndDraft() {
        let prompt = builder.userPrompt(
            source: "我们可以再谈价格",
            draft: "また価格の話ができます",
            direction: zhToJa,
            history: [])
        #expect(prompt.contains("我们可以再谈价格"))
        #expect(prompt.contains("また価格の話ができます"))
        #expect(!prompt.contains("Conversation so far"))
    }

    @Test func historyIsIncludedAndCapped() {
        let history = (0..<10).map { i in
            PromptBuilder.HistoryTurn(
                sourceLanguage: .chinese,
                sourceText: "句子\(i)",
                translation: "文\(i)")
        }
        let prompt = builder.userPrompt(
            source: "你好", draft: "こんにちは", direction: zhToJa, history: history)
        #expect(prompt.contains("Conversation so far"))
        // historyLimit = 6: oldest 4 turns are dropped.
        #expect(!prompt.contains("句子3"))
        #expect(prompt.contains("句子9"))
    }

    @Test func oversizedHistoryIsTrimmedToBudget() {
        let bigTurn = PromptBuilder.HistoryTurn(
            sourceLanguage: .english,
            sourceText: String(repeating: "long sentence ", count: 60),
            translation: String(repeating: "长句子", count: 100))
        let prompt = builder.userPrompt(
            source: "hello", draft: "你好",
            direction: LanguagePair(source: .english, target: .chinese),
            history: Array(repeating: bigTurn, count: 6))
        #expect(prompt.count <= builder.maxPromptCharacters)
        #expect(prompt.contains("hello"))
    }

    @Test func cleanResponseStripsThinkBlock() {
        let raw = "<think>reasoning here</think>\nこんにちは、お元気ですか。"
        #expect(builder.cleanResponse(raw) == "こんにちは、お元気ですか。")
    }

    @Test func cleanResponseStripsSurroundingQuotes() {
        #expect(builder.cleanResponse("\"你好\"") == "你好")
    }

    @Test func cleanResponseTruncatesAtSpecialToken() {
        let raw = "你好。<|endoftext|>- ifuntingake enumpdos garbage"
        #expect(builder.cleanResponse(raw) == "你好。")
    }

    @Test func cleanResponseKeepsInternalQuotes() {
        #expect(builder.cleanResponse("He said \"hi\" to me") == "He said \"hi\" to me")
    }

    @Test func acceptableRejectsEmptyAndRunaway() {
        #expect(!builder.isAcceptable("", draft: "你好"))
        let runaway = String(repeating: "胡言乱语 noise ", count: 50)
        #expect(!builder.isAcceptable(runaway, draft: "你好"))
        #expect(builder.isAcceptable("你好，最近怎么样？", draft: "你好"))
    }

    @Test func acceptableRejectsReplacementCharacters() {
        #expect(!builder.isAcceptable("tera\u{FFFD}CHÌB混", draft: "你好"))
    }

    @Test func glossaryAppearsAndSurvivesTrimming() {
        let bigTurn = PromptBuilder.HistoryTurn(
            sourceLanguage: .english,
            sourceText: String(repeating: "long sentence ", count: 60),
            translation: String(repeating: "长句子", count: 100))
        let prompt = builder.userPrompt(
            source: "tell Zhipeng",
            draft: "告诉志鹏",
            direction: LanguagePair(source: .english, target: .chinese),
            history: Array(repeating: bigTurn, count: 6),
            glossary: ["Zhipeng → 志鹏 (person name)"])
        #expect(prompt.contains("Zhipeng → 志鹏"))
        #expect(prompt.contains("Glossary"))
    }
}
