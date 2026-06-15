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

    @Test func parsesStructuredSummaryTags() {
        let parsed = builder.parseStructuredSummary("""
        O: 团队确认了发布日期。
        O：预算仍待批准。
        T: **发布计划**
        D: 定于7月10日发布
        A: 王经理周五前提交预算
        chatter the model added
        """)
        #expect(parsed.overview == ["团队确认了发布日期。", "预算仍待批准。"])
        #expect(parsed.items("T") == ["发布计划"])   // fullwidth colon + ** stripped
        #expect(parsed.items("D") == ["定于7月10日发布"])
        #expect(parsed.items("A") == ["王经理周五前提交预算"])
        #expect(!parsed.isEmpty)
    }

    @Test func structuredSummaryCapsAndUntaggedFallback() {
        let overflowing = (1...6).map { "T: topic number \($0)" }.joined(separator: "\n")
        #expect(builder.parseStructuredSummary(overflowing).items("T").count == 4)

        let untagged = builder.parseStructuredSummary(
            "A plain paragraph with no tags at all.\n• and a bullet")
        #expect(untagged.isEmpty)
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

    @Test func chunkNoteToleratesDecoratedTags() {
        // Bullets, numbering, markdown headers/bold, a lowercased tag letter,
        // and a space before the colon all still parse as their tag.
        let note = PromptBuilder().parseChunkNote("""
        ## H: 发布计划
        - F: 事实一
        1. F: 事实二
        **D:** 决定一
        a: 王经理跟进
        T ： Loqi
        """)
        #expect(note.headline == "发布计划")
        #expect(note.facts == ["事实一", "事实二"])
        #expect(note.decisions == ["决定一"])
        #expect(note.actions == ["王经理跟进"])
        #expect(note.terms == ["Loqi"])
    }

    @Test func taggedParsingRejectsProseStartingWithTagLetter() {
        // The colon must follow the tag letter (spaces allowed) — prose that
        // merely begins with a tag letter is not a tag.
        let note = PromptBuilder().parseChunkNote("""
        H: 真标题
        However we should ship: soon
        Domain experts disagreed
        """)
        #expect(note.headline == "真标题")
        #expect(note.facts.isEmpty)
        #expect(note.decisions.isEmpty)
    }

    @Test func structuredSummaryToleratesDecoratedTags() {
        let parsed = builder.parseStructuredSummary("""
        ## O: 团队确认了发布日期
        - D: 定于7月10日发布
        1. A: 王经理周五前提交预算
        """)
        #expect(parsed.overview == ["团队确认了发布日期"])
        #expect(parsed.items("D") == ["定于7月10日发布"])
        #expect(parsed.items("A") == ["王经理周五前提交预算"])
    }

    @Test func rendersSummaryMarkdownSkippingEmptySections() {
        var parsed = PromptBuilder.ParsedStructuredSummary()
        parsed.overview = ["First sentence.", "Second sentence."]
        parsed.sections[0] = ["发布计划"]          // T (meeting spec order)
        parsed.sections[2] = ["王经理提交预算"]    // A
        let markdown = builder.renderSummaryMarkdown(parsed, in: .chinese)
        #expect(markdown.hasPrefix("First sentence. Second sentence."))
        #expect(markdown.contains("## 主题\n- 发布计划"))
        #expect(markdown.contains("## 待办事项\n- 王经理提交预算"))
        #expect(!markdown.contains("## 决定"))   // empty section hidden

        let english = builder.renderSummaryMarkdown(parsed, in: .english)
        #expect(english.contains("## Topics"))
        #expect(english.contains("## Action Items"))
    }

    @Test func parsesLectureTagsIntoLectureSections() {
        let parsed = builder.parseStructuredSummary("""
        O: The talk covered transformer architectures.
        C: Attention scales quadratically with sequence length
        T: KV cache — stored keys/values reused across steps
        Q: How does this apply to streaming audio?
        D: a stray meeting-style line
        """, style: .lecture)
        #expect(parsed.overview == ["The talk covered transformer architectures."])
        #expect(parsed.items("C") == ["Attention scales quadratically with sequence length"])
        #expect(parsed.items("T") == ["KV cache — stored keys/values reused across steps"])
        #expect(parsed.items("Q") == ["How does this apply to streaming audio?"])
        // "D" is not a lecture tag: the line is dropped, not misfiled.
        #expect(parsed.items("D").isEmpty)
        #expect(!parsed.joinedValues.contains("stray meeting-style line"))
    }

    @Test func rendersJournalMarkdownWithJournalHeadings() {
        var parsed = PromptBuilder.ParsedStructuredSummary(style: .journal)
        parsed.overview = ["早上去了海边。", "下午写了提案。"]
        parsed.sections[0] = ["日出时的海面"]      // H
        parsed.sections[1] = ["对进度感到安心"]    // F
        let markdown = builder.renderSummaryMarkdown(parsed, in: .chinese)
        #expect(markdown.hasPrefix("早上去了海边。 下午写了提案。"))
        #expect(markdown.contains("## 亮点\n- 日出时的海面"))
        #expect(markdown.contains("## 感受与思考\n- 对进度感到安心"))
        #expect(!markdown.contains("## 打算"))   // empty Intentions hidden
    }

    @Test func brainstormIdeaCapIsSix() {
        let overflowing = (1...8).map { "I: idea \($0)" }.joined(separator: "\n")
        let parsed = builder.parseStructuredSummary(overflowing, style: .brainstorm)
        #expect(parsed.items("I").count == 6)
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
