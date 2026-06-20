import Foundation
import Testing
@testable import Loqi

struct SummaryEngineTests {
    private func entry(
        _ text: String, at seconds: TimeInterval, speaker: Int? = nil
    ) -> SessionRecord.Entry {
        SessionRecord.Entry(
            sourceText: text,
            translation: nil,
            speaker: speaker,
            direction: LanguagePair(source: .chinese, target: .english),
            timestamp: Date(timeIntervalSince1970: 1_000_000 + seconds))
    }

    // MARK: Chunking

    @Test func chunksSplitOnBudget() {
        let long = String(repeating: "字", count: 400)
        let entries = (0..<6).map { entry(long, at: Double($0) * 5) }
        let chunks = SummaryEngine.chunkEntries(entries, budget: 1100)
        // 400 chars each, budget 1100 → 2 entries per chunk... third would
        // exceed (1200 > 1100), so chunks of 2.
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count == 2 })
    }

    @Test func chunksSplitOnLongPause() {
        let entries = [
            entry("第一句", at: 0),
            entry("第二句", at: 5),
            entry("第三句", at: 60),   // 55s gap → new chunk
        ]
        let chunks = SummaryEngine.chunkEntries(entries)
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 2)
        #expect(chunks[1].count == 1)
    }

    @Test func speakerChangePrefersBreakWhenChunkMostlyFull() {
        let long = String(repeating: "字", count: 700)   // > 60% of 1100
        let entries = [
            entry(long, at: 0, speaker: 0),
            entry("另一个人说话", at: 5, speaker: 1),
        ]
        let chunks = SummaryEngine.chunkEntries(entries)
        #expect(chunks.count == 2)
    }

    @Test func speakerChangeKeepsTogetherWhenChunkSmall() {
        let entries = [
            entry("短句", at: 0, speaker: 0),
            entry("回答", at: 3, speaker: 1),
        ]
        let chunks = SummaryEngine.chunkEntries(entries)
        #expect(chunks.count == 1)
    }

    // MARK: Refinement output parsing (translation only — source rewriting
    // was removed; an "S:" line from an old prompt shape is ignored)

    @Test func taggedTranslationParses() {
        let parsed = PromptBuilder().parseRefinement(
            "S: 我觉得要不就英法都考一下\nT: I think we should test both English and French.")
        #expect(parsed == "I think we should test both English and French.")
    }

    @Test func untaggedOutputIsTheTranslation() {
        let parsed = PromptBuilder().parseRefinement("こんにちは、お元気ですか。")
        #expect(parsed == "こんにちは、お元気ですか。")
    }

    // MARK: Hotword-restore parsing + fidelity gate

    @Test func restoredSentenceParsesTaggedAndUntagged() {
        #expect(PromptBuilder().parseRestoredSentence("S: 我们和志鹏开会")
            == "我们和志鹏开会")
        #expect(PromptBuilder().parseRestoredSentence("我们和志鹏开会")
            == "我们和志鹏开会")
    }

    @Test func acceptsTermSwap() {
        let original = "我觉要不就英法问一下考两个来现"
        let restored = "我觉得要不就英法都问一下，考两个来"
        #expect(PromptBuilder().isAcceptableHotwordRestore(restored, original: original))
    }

    @Test func rejectsMeaningDivergentRewrite() {
        let original = "我觉要不就英法问一下考两个来现"
        let restored = "今天天气很好我们去公园散步吧"
        #expect(!PromptBuilder().isAcceptableHotwordRestore(restored, original: original))
    }

    @Test func rejectsLengthExplosion() {
        let original = "短句"
        let restored = String(repeating: "解释一下这个短句的意思", count: 5)
        #expect(!PromptBuilder().isAcceptableHotwordRestore(restored, original: original))
    }

    // MARK: Summary records

    @Test func chunkRecordPromptSeparatesContextFromTarget() {
        let prompt = PromptBuilder().chunkRecordPrompt(
            chunkID: "c003",
            timeRange: "04:00-06:00",
            contextOnly: "m000\tEarlier overlap",
            target: "m031\t小模型直接做开放式总结时容易产生幻觉",
            vocabulary: ["Loqi (product name)"],
            in: .chinese)

        #expect(prompt.system.contains("context_only"))
        #expect(prompt.system.contains("target"))
        #expect(prompt.system.contains("forbidden") || prompt.system.contains("禁止"))
        #expect(prompt.system.contains("TSV"))
        #expect(prompt.user.contains("chunk_id: c003"))
        #expect(prompt.user.contains("context_only:"))
        #expect(prompt.user.contains("target:"))
        #expect(prompt.user.contains("Known terms: Loqi (product name)"))
    }

    @Test func reducePromptRequiresSynthesisInsteadOfConcatenation() {
        let prompt = PromptBuilder().reduceSummaryPrompt(
            notes: "[1] 桌布讨论\nfact: 传家宝桌子不必铺布\nphoto: 桌面照片显示木纹完整",
            style: .meeting,
            in: .chinese,
            sizing: SummaryPromptSizing(maxTokens: 420, overviewCap: 2, sectionCaps: [3, 3, 3]))

        #expect(prompt.system.contains("Synthesize"))
        #expect(prompt.system.contains("Do not concatenate"))
        #expect(prompt.system.contains("photo"))
        #expect(prompt.user.contains("Notes:\n[1] 桌布讨论"))
    }

    @Test func structuredReduceOutputRendersMarkdown() {
        let builder = PromptBuilder()
        let sizing = SummaryPromptSizing(maxTokens: 420, overviewCap: 2, sectionCaps: [3, 3, 3])
        let parsed = builder.parseStructuredSummary(
            """
            O: 讨论围绕桌子是否需要铺桌布，以及转椅是否适合久坐。
            T: 传家宝桌子可以不铺布，重点是保留原本状态。
            D: 决定暂时不铺桌布。
            A: 未明确: 继续确认转椅是否舒服
            """,
            style: .meeting,
            sizing: sizing)

        #expect(parsed.overview == ["讨论围绕桌子是否需要铺桌布，以及转椅是否适合久坐。"])
        #expect(parsed.items("T") == ["传家宝桌子可以不铺布，重点是保留原本状态。"])
        #expect(parsed.items("D") == ["决定暂时不铺桌布。"])
        #expect(parsed.items("A") == ["未明确: 继续确认转椅是否舒服"])

        let markdown = builder.renderSummaryMarkdown(parsed, in: .chinese)
        #expect(markdown.contains("## 主题"))
        #expect(markdown.contains("- 传家宝桌子可以不铺布"))
        #expect(markdown.contains("## 决定"))
        #expect(markdown.contains("## 待办事项"))
    }

    @Test func reduceInputLabelsPhotoFactsWithoutRawCaptionDump() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let transcript = SessionRecord.ChunkNote(
            headline: "桌布讨论",
            startedAt: t0,
            facts: ["传家宝桌子不必铺布"],
            decisions: ["暂时不铺桌布"])
        let photo = SessionRecord.Attachment(
            fileName: "desk.jpg",
            timestamp: t0.addingTimeInterval(12),
            vlmDescription: "照片显示木质桌面，桌上没有桌布。")
        let input = SummaryEngine.reduceInput(
            notes: AttachmentNotes.merged([transcript], attachments: [photo]),
            style: .meeting)

        #expect(input.contains("fact: 传家宝桌子不必铺布"))
        #expect(input.contains("decision: 暂时不铺桌布"))
        #expect(input.contains("photo: 照片显示木质桌面，桌上没有桌布。"))
        #expect(!input.contains("📷"))
    }

    @Test func reduceInputKeepsSpecificLabelForDuplicateDecision() {
        let note = SessionRecord.ChunkNote(
            headline: "预算讨论",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            facts: ["预算定为 42 万"],
            decisions: ["预算定为 42 万"])

        let input = SummaryEngine.reduceInput(notes: [note], style: .meeting)

        #expect(input.contains("decision: 预算定为 42 万"))
        #expect(!input.contains("fact: 预算定为 42 万"))
    }

    @Test func reducedSummaryFallsBackWhenStructuredOutputRepeats() {
        let builder = PromptBuilder()
        let sizing = SummaryPromptSizing(maxTokens: 420, overviewCap: 6, sectionCaps: [6, 6, 6])
        let raw = (Array(repeating: "O: 好好", count: 6)
            + Array(repeating: "T: 好好", count: 6))
            .joined(separator: "\n")
        let parsed = builder.parseStructuredSummary(raw, style: .meeting, sizing: sizing)
        let note = SessionRecord.ChunkNote(
            headline: "桌布讨论",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            facts: ["传家宝桌子不必铺布"])

        let summary = SummaryEngine.renderReducedSummary(
            raw: raw,
            parsed: parsed,
            notes: [note],
            style: .meeting,
            length: .standard,
            in: .chinese,
            stitchDetails: false)

        #expect(!parsed.isEmpty)
        #expect(PromptBuilder.hasDegenerateRepetition(parsed.joinedValues))
        #expect(summary.contains("传家宝桌子不必铺布"))
    }

    @Test func parsesSummaryRecordTSVAndRejectsInvalidLines() {
        let raw = """
        T	c003	04:00-06:00	摘要去重	讨论本地摘要中的幻觉和重复
        P	c003	m031,m032	小模型开放式总结容易产生幻觉
        D	c003	m033	最终阶段不再使用模型合并
        A	c003	m034	王经理	设计字符串拼接流程	周五
        Q	c003	m035	如何减少 overlap 重复
        R	c003	m036	最终合并会引入新幻觉
        P	c999	m031	错误 chunk 被丢弃
        P	c003	m999	错误 source 被丢弃
        A	c003	m034	字段不够
        """

        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c003",
            validSourceIDs: ["m031", "m032", "m033", "m034", "m035", "m036"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000))

        #expect(records.map(\.kind) == [
            .topic, .point, .decision, .action, .question, .risk,
        ])
        #expect(records[0].topicTitle == "摘要去重")
        #expect(records[0].timeRange == "04:00-06:00")
        #expect(records[1].sourceIDs == ["m031", "m032"])
        #expect(records[3].owner == "王经理")
        #expect(records[3].deadline == "周五")
    }

    @Test func deterministicRendererDedupesAndLabelsPhotoOnlyRecords() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(SummaryEngine.dedupKey("讨论六月发布计划") == "讨论六月发布计划")
        let records: [SessionRecord.SummaryRecord] = [
            .init(
                kind: .topic,
                source: .transcript,
                sourceIDs: ["m001"],
                sourceIndex: 0,
                timestamp: t0,
                text: "讨论六月发布计划",
                topicTitle: "发布计划",
                timeRange: "00:00-02:00"),
            .init(
                kind: .point,
                source: .transcript,
                sourceIDs: ["m002"],
                sourceIndex: 1,
                timestamp: t0.addingTimeInterval(5),
                text: "预算是 42 万"),
            .init(
                kind: .point,
                source: .transcript,
                sourceIDs: ["m003"],
                sourceIndex: 2,
                timestamp: t0.addingTimeInterval(10),
                text: "预算是42万"),
            .init(
                kind: .point,
                source: .photo,
                sourceIDs: ["p001"],
                sourceIndex: 3,
                timestamp: t0.addingTimeInterval(20),
                text: "白板写着六月发布",
                sourceLabel: "Photo 10:24"),
        ]

        let summary = SummaryRecordReducer.render(
            records: records,
            style: .meeting,
            length: .standard,
            in: .chinese,
            stitchDetails: false)

        #expect(summary.contains("讨论六月发布计划"))
        #expect(summary.contains("预算是 42 万"))
        #expect(!summary.contains("预算是42万"))
        #expect(summary.contains("[Photo 10:24] 白板写着六月发布"))
    }

    @Test func rendererDoesNotRepeatSameContentAcrossSections() {
        let text = "测试录音中手机语言识别"
        let records: [SessionRecord.SummaryRecord] = [
            .init(
                kind: .topic,
                source: .transcript,
                sourceIDs: ["m001"],
                sourceIndex: 0,
                timestamp: Date(timeIntervalSince1970: 1_000_000),
                text: text,
                topicTitle: text,
                timeRange: "00:00-00:05"),
            .init(
                kind: .point,
                source: .transcript,
                sourceIDs: ["m001"],
                sourceIndex: 1,
                timestamp: Date(timeIntervalSince1970: 1_000_001),
                text: text),
        ]

        let summary = SummaryRecordReducer.render(
            records: records,
            style: .memo,
            length: .detailed,
            in: .chinese)

        #expect(summary.components(separatedBy: text).count - 1 == 1)
    }

    @Test func legacyChunkNotesConvertToRecords() {
        let note = SessionRecord.ChunkNote(
            headline: "预算讨论",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            facts: ["预算是 42 万"],
            decisions: ["六月发布"],
            actions: ["王经理确认供应商"],
            terms: ["Loqi"])

        let records = SummaryRecordReducer.records(from: [note])

        #expect(records.map(\.kind) == [
            .topic, .point, .decision, .action, .term,
        ])
        #expect(records.first?.text == "预算讨论")
        #expect(records[1].text == "预算是 42 万")
    }

    @Test func crossKindDedupKeepsMoreSpecificClassification() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let records: [SessionRecord.SummaryRecord] = [
            .init(
                kind: .topic, source: .transcript, sourceIDs: ["m001"],
                sourceIndex: 0, timestamp: t0, text: "发布计划讨论",
                topicTitle: "发布计划"),
            .init(
                kind: .point, source: .transcript, sourceIDs: ["m002"],
                sourceIndex: 1, timestamp: t0.addingTimeInterval(5),
                text: "六月发布"),
            .init(
                kind: .decision, source: .transcript, sourceIDs: ["m003"],
                sourceIndex: 2, timestamp: t0.addingTimeInterval(10),
                text: "六月发布"),
        ]

        let summary = SummaryRecordReducer.render(
            records: records, style: .meeting, length: .standard,
            in: .chinese, stitchDetails: false)

        // Point and decision share text → one bullet, classified as the
        // decision (more specific), so it renders once as a section bullet
        // instead of appearing in both the Topics and Decisions sections.
        #expect(summary.components(separatedBy: "六月发布").count - 1 == 1)
        #expect(summary.contains("- 六月发布"))
    }

    @Test func renderKeepsSameTaskActionsForDifferentOwners() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let records: [SessionRecord.SummaryRecord] = [
            .init(
                kind: .action,
                source: .transcript,
                sourceIDs: ["m001"],
                sourceIndex: 0,
                timestamp: t0,
                text: "review the launch notes",
                owner: "Alice",
                task: "review the launch notes",
                deadline: "Friday"),
            .init(
                kind: .action,
                source: .transcript,
                sourceIDs: ["m002"],
                sourceIndex: 1,
                timestamp: t0.addingTimeInterval(1),
                text: "review the launch notes",
                owner: "Bob",
                task: "review the launch notes",
                deadline: "Monday"),
        ]

        let summary = SummaryRecordReducer.render(
            records: records,
            style: .meeting,
            length: .standard,
            in: .english)

        #expect(summary.contains("Alice: review the launch notes (Friday)"))
        #expect(summary.contains("Bob: review the launch notes (Monday)"))
    }
}
