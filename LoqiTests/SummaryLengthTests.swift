import Foundation
import Testing
@testable import Loqi

struct SummaryLengthTests {
    @Test func detailedLengthScalesWithTranscriptButHitsHardCap() {
        let short = SummaryEngine.summaryPromptSizing(
            style: .meeting,
            length: .detailed,
            transcriptCharacterCount: 800,
            noteCount: 2)
        let long = SummaryEngine.summaryPromptSizing(
            style: .meeting,
            length: .detailed,
            transcriptCharacterCount: 20_000,
            noteCount: 30)

        #expect(long.maxTokens > short.maxTokens)
        #expect(long.maxTokens == SummaryEngine.summaryMaxTokensHardCap)
        #expect(long.overviewCap <= SummaryEngine.summaryOverviewHardCap)
        #expect(long.sectionCaps.allSatisfy { $0 <= SummaryEngine.summarySectionHardCap })
    }

    @Test func standardLongTranscriptIsFullerThanConciseLongTranscript() {
        let concise = SummaryEngine.summaryPromptSizing(
            style: .meeting,
            length: .concise,
            transcriptCharacterCount: 8_000,
            noteCount: 12)
        let standard = SummaryEngine.summaryPromptSizing(
            style: .meeting,
            length: .standard,
            transcriptCharacterCount: 8_000,
            noteCount: 12)

        #expect(standard.maxTokens > concise.maxTokens)
        #expect(standard.overviewCap >= concise.overviewCap)
        #expect(zip(standard.sectionCaps, concise.sectionCaps).allSatisfy { $0 >= $1 })
    }

    // MARK: Detailed stitching

    private func note(
        _ headline: String,
        facts: [String] = [],
        decisions: [String] = [],
        actions: [String] = []
    ) -> SessionRecord.ChunkNote {
        SessionRecord.ChunkNote(
            headline: headline,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            anchorEntryID: nil,
            facts: facts,
            decisions: decisions,
            actions: actions)
    }

    @Test func stitchGateRequiresDetailedAndEnoughNotes() {
        #expect(!SummaryEngine.shouldStitchDetailSections(length: .detailed, noteCount: 1))
        #expect(SummaryEngine.shouldStitchDetailSections(length: .detailed, noteCount: 4))
        #expect(!SummaryEngine.shouldStitchDetailSections(length: .detailed, noteCount: 0))
        #expect(!SummaryEngine.shouldStitchDetailSections(length: .standard, noteCount: 30))
        #expect(!SummaryEngine.shouldStitchDetailSections(length: .concise, noteCount: 30))
    }

    @Test func segmentNotesKeepsFixedChronologicalPairs() {
        let notes = (1...7).map { note("段落\($0)") }
        let segments = SummaryEngine.segmentNotes(notes, size: 2)
        #expect(segments.map(\.count) == [2, 2, 2, 1])
        // Order is preserved across the split.
        #expect(segments.flatMap { $0 }.map(\.headline) == notes.map(\.headline))
        #expect(SummaryEngine.segmentNotes([], size: 2).isEmpty)
        #expect(SummaryEngine.segmentNotes(Array(notes.prefix(2)), size: 2).count == 1)
    }

    @Test func detailSectionAssemblesNoteLinesCapped() {
        let segment = [
            note("讨论预算", facts: ["预算一", "预算二"], decisions: ["决定一"]),
            note("讨论排期", facts: ["排期一"], actions: ["待办一", "待办二", "待办三"]),
        ]
        let section = SummaryEngine.detailSection(for: segment)
        #expect(section?.headline == "讨论预算")
        #expect(section?.points.count == SummaryEngine.detailSectionPointCap)
        #expect(section?.points.first == "预算一")
        #expect(section?.points.contains("决定一") == true)
        #expect(section?.points.contains("待办一") == true)

        #expect(SummaryEngine.detailSection(for: [note("只有标题")]) == nil)
    }

    @Test func detailedSectionsSkipFallbackStubsAndIncludeAttachments() {
        let attachment = SessionRecord.Attachment(
            fileName: "whiteboard.jpg",
            timestamp: Date(timeIntervalSince1970: 1_000_050),
            ocrText: "白板写着预算 42 万\n六月发布",
            caption: "发布白板")
        let attachmentNote = AttachmentNotes.note(for: attachment)
        var fallback = note("识别失败片段")
        fallback.isFallback = true
        let notes = [
            note("开场", facts: ["目标是六月发布"], decisions: ["采用小范围灰度"]),
            fallback,
            note("预算", facts: ["预算 42 万"], actions: ["王经理下周确认供应商"]),
        ] + [attachmentNote].compactMap { $0 }

        let sections = SummaryEngine.detailedSections(for: notes, size: 2)

        #expect(sections.map(\.headline) == ["开场", "📷 发布白板"])
        #expect(sections[0].points == [
            "目标是六月发布",
            "采用小范围灰度",
            "预算 42 万",
            "王经理下周确认供应商",
        ])
        #expect(sections[1].points.contains("发布白板"))
    }

    @Test func appendDetailSectionsRendersNumberedSections() {
        let stitched = SummaryEngine.appendDetailSections(
            [
                .init(headline: "开场与目标", points: ["目标一", "目标二"]),
                .init(headline: "预算讨论", points: ["预算一"]),
            ],
            to: "总览。\n\n## 主题\n- 主题一")
        #expect(stitched == """
        总览。

        ## 主题
        - 主题一

        ## 1. 开场与目标
        - 目标一
        - 目标二

        ## 2. 预算讨论
        - 预算一
        """)
        #expect(SummaryEngine.appendDetailSections([], to: "原文") == "原文")
    }

    @Test func parsesSegmentSectionAndDropsDuplicates() {
        let raw = """
        Here is the section:
        H：开场与目标
        P: 目标一
        P: 目标一
        P：目标二
        X: 无关行
        """
        let parsed = PromptBuilder().parseSegmentSection(raw)
        #expect(parsed.headline == "开场与目标")
        #expect(parsed.points == ["目标一", "目标二"])

        let offFormat = PromptBuilder().parseSegmentSection("没有任何标签的回答")
        #expect(offFormat.points.isEmpty)
    }

    @Test func segmentSectionPromptNamesLanguageAndTags() {
        let prompt = PromptBuilder().segmentSectionPrompt(notes: "x", in: .chinese)
        #expect(prompt.system.contains("Chinese"))
        #expect(prompt.system.contains("\"H: <section heading of at most 8 words>\""))
        #expect(prompt.system.contains("\"P: <specific point; keep names, numbers, and reasons>\""))
        #expect(prompt.user == "Notes:\nx")
    }

    @Test func reducePromptUsesAdaptiveCapsWhenProvided() {
        let sizing = SummaryEngine.summaryPromptSizing(
            style: .meeting,
            length: .standard,
            transcriptCharacterCount: 7_000,
            noteCount: 12)

        let prompt = PromptBuilder().reduceSummaryPrompt(
            notes: "x", style: .meeting, in: .english, sizing: sizing).system

        #expect(prompt.contains("first 1-\(sizing.overviewCap) lines"))
        #expect(prompt.contains("up to \(sizing.sectionCaps[0]) lines \"T: <main topic>\""))
        #expect(prompt.contains("up to \(sizing.sectionCaps[1]) lines \"D: <decision>\""))
        #expect(prompt.contains("up to \(sizing.sectionCaps[2]) lines \"A: <action item, keep who does what>\""))
    }
}
