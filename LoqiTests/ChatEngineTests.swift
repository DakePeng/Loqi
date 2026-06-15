import Foundation
import Testing
@testable import Loqi

struct ChatEngineTests {
    private func makeRecord(withNotes: Bool = true) -> SessionRecord {
        var record = SessionRecord(
            mode: .captions,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_600),
            entries: [
                .init(
                    sourceText: "我们决定六月发布产品",
                    translation: "We decided to ship the product in June",
                    speaker: 0,
                    direction: LanguagePair(source: .chinese, target: .english),
                    timestamp: Date(timeIntervalSince1970: 1_000_010)),
                .init(
                    sourceText: "Marketing needs the budget approved first",
                    translation: nil,
                    speaker: 1,
                    direction: LanguagePair(source: .english, target: .english),
                    timestamp: Date(timeIntervalSince1970: 1_000_120)),
                .init(
                    sourceText: "李雷 will draft the launch plan",
                    translation: nil,
                    speaker: 0,
                    direction: LanguagePair(source: .english, target: .english),
                    timestamp: Date(timeIntervalSince1970: 1_000_240)),
            ],
            speakerNames: [0: "王经理"])
        if withNotes {
            record.chunkNotes = [
                .init(
                    headline: "Launch date decided",
                    startedAt: Date(timeIntervalSince1970: 1_000_010),
                    facts: ["Product ships in June"],
                    decisions: ["June launch confirmed"],
                    actions: [],
                    terms: []),
                .init(
                    headline: "Budget discussion",
                    startedAt: Date(timeIntervalSince1970: 1_000_120),
                    facts: [],
                    decisions: [],
                    actions: ["李雷 drafts the launch plan"],
                    terms: ["李雷"]),
            ]
        }
        return record
    }

    // MARK: queryTokens

    @Test func latinTokensAreLowercasedWords() {
        let tokens = ChatEngine.queryTokens("What did Marketing decide?")
        #expect(tokens.contains("what"))
        #expect(tokens.contains("marketing"))
        #expect(tokens.contains("decide"))
        #expect(!tokens.contains("?"))
    }

    @Test func cjkTokensAreTwoGrams() {
        let tokens = ChatEngine.queryTokens("发布产品")
        #expect(tokens.contains("发布"))
        #expect(tokens.contains("布产"))
        #expect(tokens.contains("产品"))
    }

    @Test func mixedScriptsTokenizeBothWays() {
        let tokens = ChatEngine.queryTokens("李雷的launch计划")
        #expect(tokens.contains("李雷"))
        #expect(tokens.contains("launch"))
        #expect(tokens.contains("计划"))
    }

    // MARK: relevantLines

    @Test func relevantLinesAreChronologicalAndSpeakerLabelled() {
        let record = makeRecord()
        let lines = ChatEngine.relevantLines(
            in: record, question: "launch plan budget", budget: 2000)
        #expect(lines.count == 2)
        #expect(lines[0].contains("Marketing needs the budget"))
        #expect(lines[1].hasPrefix("[王经理] "))
        #expect(lines[1].contains("launch plan"))
    }

    @Test func cjkQuestionSelectsCJKLines() {
        let record = makeRecord()
        let lines = ChatEngine.relevantLines(
            in: record, question: "什么时候发布产品？", budget: 2000)
        #expect(lines.contains { $0.contains("我们决定六月发布产品") })
    }

    @Test func relevantLinesRespectBudget() {
        let record = makeRecord()
        let lines = ChatEngine.relevantLines(
            in: record, question: "launch plan budget", budget: 50)
        let total = lines.reduce(0) { $0 + $1.count }
        #expect(total <= 50)
    }

    // MARK: context

    @Test func contextIncludesEveryHeadline() {
        let context = ChatEngine.context(
            for: makeRecord(), question: "anything at all")
        #expect(context.contains("Launch date decided"))
        #expect(context.contains("Budget discussion"))
        #expect(context.hasPrefix("Outline:"))
    }

    @Test func contextBulletsComeOnlyFromMatchingNotes() {
        let context = ChatEngine.context(
            for: makeRecord(), question: "launch schedule")
        // "launch" matches the decision and action bullets; the June fact
        // contains neither token.
        #expect(context.contains("action: 李雷 drafts the launch plan"))
        #expect(context.contains("decision: June launch confirmed"))
        #expect(!context.contains("fact: Product ships in June"))
    }

    @Test func contextWithoutNotesFallsBackToTranscript() {
        let record = makeRecord(withNotes: false)
        // No token matches any line → plain transcript tail.
        let context = ChatEngine.context(for: record, question: "嗯嗯嗯")
        #expect(context.contains("我们决定六月发布产品"))
        // A matching question → only the matching lines.
        let matched = ChatEngine.context(for: record, question: "budget")
        #expect(matched.contains("Marketing needs the budget"))
        #expect(!matched.contains("李雷 will draft"))
    }

    @Test func contextRespectsBudget() {
        var record = makeRecord()
        record.chunkNotes = (0..<200).map { index in
            .init(
                headline: "Headline number \(index) about launch planning",
                startedAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)),
                facts: ["launch fact \(index) with some padding text"],
                decisions: [], actions: [], terms: [])
        }
        let context = ChatEngine.context(
            for: record, question: "launch", budget: 1000)
        // Joins/labels add a little slack on top of the counted content.
        #expect(context.count < 1400)
    }

    // MARK: answerLanguage

    @Test func answerLanguageFollowsTheQuestion() {
        #expect(ChatEngine.answerLanguage(
            for: "会议决定了什么时候发布产品？", fallback: .english) == .chinese)
        #expect(ChatEngine.answerLanguage(
            for: "What was decided about the launch?", fallback: .chinese) == .english)
        #expect(ChatEngine.answerLanguage(
            for: "発売日はいつに決まりましたか？", fallback: .english) == .japanese)
    }

    @Test func answerLanguageFallsBackWhenUndetectable() {
        #expect(ChatEngine.answerLanguage(for: "??", fallback: .korean) == .korean)
    }

    // MARK: pairedHistory

    @Test func pairedHistoryPairsAdjacentTurnsAndWindows() {
        var messages: [SessionRecord.ChatMessage] = []
        for index in 0..<6 {
            messages.append(.init(role: "user", text: "q\(index)", date: .now))
            messages.append(.init(role: "assistant", text: "a\(index)", date: .now))
        }
        // Trailing unanswered question is ignored.
        messages.append(.init(role: "user", text: "pending", date: .now))

        let pairs = ChatEngine.pairedHistory(messages, window: 4)
        #expect(pairs.count == 4)
        #expect(pairs.first?.question == "q2")
        #expect(pairs.last?.answer == "a5")
        #expect(!pairs.contains { $0.question == "pending" })
    }
}
