import Testing
@testable import Loqi

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

    @Test func plainDescriptionFlattensMarkdownAndLists() {
        let raw = """
        1. **核心内容**: 桌面上有一台笔记本电脑。
        2. **关键细节**: 屏幕显示 NVIDIA A100。
        """
        let plain = builder.plainDescription(raw)
        #expect(!plain.contains("**"))
        #expect(!plain.contains("1."))
        #expect(!plain.contains("\n"))
        #expect(plain.contains("核心内容: 桌面上有一台笔记本电脑。"))
        #expect(plain.contains("屏幕显示 NVIDIA A100。"))
    }

    @Test func cleanResponseTruncatesAtSpecialToken() {
        let raw = "你好。<|endoftext|>- ifuntingake enumpdos garbage"
        #expect(builder.cleanResponse(raw) == "你好。")
    }

    @Test func cleanResponseStripsLeakedModelTags() {
        let raw = "<summary>\nO: Ship the app\n</summary>"
        #expect(builder.cleanResponse(raw) == "O: Ship the app")
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

    // MARK: Live sentence refinement (monolingual)

    @Test func sentenceRefineSystemPromptDemandsSentenceOnly() {
        let prompt = builder.sentenceRefineSystemPrompt(language: .chinese)
        #expect(prompt.contains("Chinese"))
        #expect(prompt.contains("Output ONLY"))
        #expect(prompt.contains("Never translate"))
    }

    @Test func sentenceRefineUserPromptCarriesSentenceContextAndGlossary() {
        let prompt = builder.sentenceRefineUserPrompt(
            sentence: "我们和志朋开会",
            language: .chinese,
            context: ["先说说项目进度", "志鹏负责测试"],
            glossary: ["志鹏 (person name)"])
        #expect(prompt.contains("我们和志朋开会"))
        #expect(prompt.contains("- 志鹏负责测试"))
        #expect(prompt.contains("Earlier lines"))
        #expect(prompt.contains("Vocabulary"))
        #expect(prompt.contains("志鹏 (person name)"))

        let bare = builder.sentenceRefineUserPrompt(
            sentence: "你好", language: .chinese, context: [])
        #expect(!bare.contains("Earlier lines"))
        #expect(!bare.contains("Vocabulary"))
    }

    @Test func sentenceRefineContextCapsAtLimit() {
        let context = (0..<10).map { "句子\($0)" }
        let prompt = builder.sentenceRefineUserPrompt(
            sentence: "你好", language: .chinese, context: context)
        // refineContextLimit = 3: only the newest three ride along.
        #expect(!prompt.contains("句子6"))
        #expect(prompt.contains("句子7"))
        #expect(prompt.contains("句子9"))
    }

    @Test func sentenceRefineContextTrimsToBudgetGlossarySurvives() {
        let bigLine = String(repeating: "很长的句子", count: 200)
        let prompt = builder.sentenceRefineUserPrompt(
            sentence: "tell Zhipeng",
            language: .english,
            context: Array(repeating: bigLine, count: 3),
            glossary: ["Zhipeng (person name)"])
        #expect(prompt.count <= builder.maxPromptCharacters)
        #expect(prompt.contains("tell Zhipeng"))
        #expect(prompt.contains("Zhipeng (person name)"))
    }

    @Test func acceptableSentenceRefinementAcceptsSmallFixes() {
        #expect(builder.isAcceptableSentenceRefinement(
            "我们和志鹏开会", original: "我们和志朋开会"))
        // Unchanged output is acceptable too (means "no errors found").
        #expect(builder.isAcceptableSentenceRefinement(
            "我们明天开会", original: "我们明天开会"))
    }

    @Test func acceptableSentenceRefinementRejectsRewritesEmptyAndRunaway() {
        #expect(!builder.isAcceptableSentenceRefinement("", original: "我们明天开会"))
        // A different sentence is a false record, not a fix.
        #expect(!builder.isAcceptableSentenceRefinement(
            "今天天气很好啊", original: "我们明天开会"))
        // Length blowout (explanation glued on).
        #expect(!builder.isAcceptableSentenceRefinement(
            "我们明天开会" + String(repeating: "，这是因为", count: 10),
            original: "我们明天开会"))
        // Degenerate repetition loop.
        #expect(!builder.isAcceptableSentenceRefinement(
            String(repeating: "好的", count: 8), original: "好的好的，明白了你的意思"))
    }

    @Test func acceptableSentenceRefinementRejectsReplacementCharacters() {
        #expect(!builder.isAcceptableSentenceRefinement(
            "我们和志\u{FFFD}开会", original: "我们和志朋开会"))
    }

    @Test func parseRefinedSentenceToleratesTagAndUntagged() {
        #expect(builder.parseRefinedSentence("S: 我们和志鹏开会") == "我们和志鹏开会")
        #expect(builder.parseRefinedSentence("我们和志鹏开会") == "我们和志鹏开会")
        #expect(builder.parseRefinedSentence("") == nil)
    }

    // MARK: Decoration-tolerant tag parsing (format robustness)

    @Test func stripLineDecorationsRemovesKnownMarkersOnly() {
        #expect(PromptBuilder.stripLineDecorations("- F: x") == "F: x")
        #expect(PromptBuilder.stripLineDecorations("1. F: x") == "F: x")
        #expect(PromptBuilder.stripLineDecorations("**F:** x") == "F: x")
        #expect(PromptBuilder.stripLineDecorations("## Heading") == "Heading")
        // A year-like number is not list numbering; the line survives whole.
        #expect(PromptBuilder.stripLineDecorations("2024 budget") == "2024 budget")
    }

    @Test func summaryEditMiningPromptCarriesSpansAndFormat() {
        let prompt = builder.summaryEditMiningPrompt(
            insertedSpans: ["Robert Smith", "the Qwen\nrollout"])
        #expect(prompt.user.contains("- Robert Smith"))
        // Newlines inside a span flatten so each span stays one bullet.
        #expect(prompt.user.contains("- the Qwen rollout"))
        // Output contract shared with parseHotwordSuggestions.
        #expect(prompt.system.contains("term | short note"))
    }

    @Test func hotwordSuggestionPromptAsksForSourceTermAndRendering() {
        let prompt = builder.hotwordSuggestionPrompt(
            transcript: "咸菜 → pickles",
            sourceLanguage: .chinese,
            targetLanguage: .english)
        #expect(prompt.system.contains("source-language terms"))
        #expect(prompt.system.contains("Chinese"))
        #expect(prompt.system.contains("English"))
        #expect(prompt.system.contains("source term | target rendering or blank | short note"))
    }

    @Test func qaPromptNamesLanguageAndCarriesQuestion() {
        let prompt = builder.qaPrompt(
            question: "会议决定了什么？",
            context: "Outline:\n- 9:00 决定六月发布",
            history: [],
            in: .chinese)
        #expect(prompt.system.contains("Chinese"))
        #expect(prompt.user.contains("Notes and excerpts:"))
        #expect(prompt.user.contains("- 9:00 决定六月发布"))
        #expect(prompt.user.hasSuffix("Question: 会议决定了什么？"))
        #expect(!prompt.user.contains("Earlier Q&A:"))
    }

    @Test func qaPromptTrimsHistoryOldestFirstUnderBudget() {
        let filler = String(repeating: "x", count: 800)
        let history = (1...6).map { (question: "q\($0) \(filler)", answer: "a\($0)") }
        let prompt = builder.qaPrompt(
            question: "final question",
            context: "small context",
            history: history,
            in: .english)
        #expect(prompt.user.count <= builder.qaMaxPromptCharacters)
        // The newest exchange survives; the oldest goes first.
        #expect(prompt.user.contains("q6"))
        #expect(!prompt.user.contains("q1 "))
        // The question itself is never trimmed.
        #expect(prompt.user.hasSuffix("Question: final question"))
    }

    @Test func qaPromptNeverTrimsContext() {
        let context = String(repeating: "c", count: 5000)
        let prompt = builder.qaPrompt(
            question: "q", context: context, history: [], in: .english)
        #expect(prompt.user.contains(context))
    }

    @Test func scenarioDetectionPromptListsAllStylesAndContext() {
        let prompt = builder.scenarioDetectionPrompt(context: "review of Q3 numbers")
        for style in SummaryStyle.allCases {
            #expect(prompt.system.contains(style.rawValue))
        }
        #expect(prompt.system.contains("exactly one word"))
        #expect(prompt.user.contains("review of Q3 numbers"))
    }

    @Test func parseScenarioMatchesTolerantly() {
        #expect(builder.parseScenario("meeting") == .meeting)
        // Case, punctuation, and surrounding words don't matter.
        #expect(builder.parseScenario("Lecture.") == .lecture)
        #expect(builder.parseScenario("This is a brainstorm session") == .brainstorm)
        #expect(builder.parseScenario("\"journal\"") == .journal)
    }

    @Test func parseScenarioRejectsOffFormatAnswers() {
        #expect(builder.parseScenario("") == nil)
        #expect(builder.parseScenario("interview") == nil)
        #expect(builder.parseScenario("I cannot classify this") == nil)
    }

    @Test func titlePromptNamesLanguageAndCarriesContext() {
        let prompt = builder.titlePrompt(context: "Q3 预算评审", in: .chinese)
        #expect(prompt.system.contains("Chinese"))
        #expect(prompt.user.contains("Q3 预算评审"))
    }

    @Test func parseTitleStripsDecorationAndKeepsFirstLine() {
        #expect(builder.parseTitle("Q3 Budget Review") == "Q3 Budget Review")
        #expect(builder.parseTitle("\"Q3 Budget Review\"") == "Q3 Budget Review")
        #expect(builder.parseTitle("# Q3 Budget Review.") == "Q3 Budget Review")
        #expect(builder.parseTitle("「第三季度预算评审」") == "第三季度预算评审")
        #expect(builder.parseTitle("Title line\nSecond line") == "Title line")
    }

    @Test func parseTitleRejectsEmptyAndDegenerateOutput() {
        #expect(builder.parseTitle("") == nil)
        #expect(builder.parseTitle("\"\"") == nil)
        #expect(builder.parseTitle(String(repeating: "好 ", count: 30)) == nil)
    }

    @Test func parseTitleCapsRunawayLength() {
        let long = "Quarterly budget review meeting with the platform team "
            + "covering hiring plans and roadmap priorities for next year"
        let parsed = builder.parseTitle(long)
        #expect(parsed?.count == 60)
    }
}
