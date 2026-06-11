import Foundation
import Testing
@testable import Locally

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

    // MARK: Chunk-note parsing

    @Test func parsesTaggedChunkNote() {
        let raw = """
        H: 讨论项目归属
        F: 项目可以算公司项目
        D: 决定先内部试用
        A: 王经理 下周发合同
        T: Locally
        """
        let note = PromptBuilder().parseChunkNote(raw)
        #expect(note.headline == "讨论项目归属")
        #expect(note.facts == ["项目可以算公司项目"])
        #expect(note.decisions == ["决定先内部试用"])
        #expect(note.actions == ["王经理 下周发合同"])
        #expect(note.terms == ["Locally"])
    }

    @Test func chunkNoteToleratesFullwidthColonsAndNoise() {
        let raw = """
        Here are the notes:
        H：标题在这里
        F：一个事实
        """
        let note = PromptBuilder().parseChunkNote(raw)
        #expect(note.headline == "标题在这里")
        #expect(note.facts == ["一个事实"])
    }

    // MARK: Refinement dual-output parsing

    @Test func parsesDualRefinementOutput() {
        let parsed = PromptBuilder().parseRefinement(
            "S: 我觉得要不就英法都考一下\nT: I think we should test both English and French.")
        #expect(parsed.cleanedSource == "我觉得要不就英法都考一下")
        #expect(parsed.translation == "I think we should test both English and French.")
    }

    @Test func untaggedOutputIsTranslationOnly() {
        let parsed = PromptBuilder().parseRefinement("こんにちは、お元気ですか。")
        #expect(parsed.cleanedSource == nil)
        #expect(parsed.translation == "こんにちは、お元気ですか。")
    }

    @Test func missingTranslationLineSurvives() {
        let parsed = PromptBuilder().parseRefinement("S: 只有清理后的原文")
        #expect(parsed.cleanedSource == "只有清理后的原文")
        #expect(parsed.translation == nil)
    }

    // MARK: Source-cleanup fidelity gate

    @Test func acceptsLightCleanup() {
        let original = "我觉要不就英法问一下考两个来现"
        let cleaned = "我觉得要不就英法都问一下，考两个来"
        #expect(PromptBuilder().isAcceptableSourceCleanup(cleaned, original: original))
    }

    @Test func rejectsMeaningDivergentRewrite() {
        let original = "我觉要不就英法问一下考两个来现"
        let cleaned = "今天天气很好我们去公园散步吧"
        #expect(!PromptBuilder().isAcceptableSourceCleanup(cleaned, original: original))
    }

    @Test func rejectsLengthExplosion() {
        let original = "短句"
        let cleaned = String(repeating: "解释一下这个短句的意思", count: 5)
        #expect(!PromptBuilder().isAcceptableSourceCleanup(cleaned, original: original))
    }
}
