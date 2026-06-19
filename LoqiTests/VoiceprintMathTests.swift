import Testing
@testable import Loqi

struct VoiceprintMathTests {
    /// Speaker-picker mapping: 0/1 = off, -1 = Auto (generous ceiling,
    /// count discovered by clustering), 2+ = hard cap.
    @Test func clusterCapForPickerValues() {
        #expect(VoiceprintService.clusterCap(forPickerValue: 0) == nil)
        #expect(VoiceprintService.clusterCap(forPickerValue: 1) == nil)
        #expect(VoiceprintService.clusterCap(forPickerValue: -1) == 8)
        #expect(VoiceprintService.clusterCap(forPickerValue: 2) == 2)
        #expect(VoiceprintService.clusterCap(forPickerValue: 6) == 6)
    }

    @Test func cosineSimilarityBasics() {
        #expect(VoiceprintMath.cosineSimilarity([1, 0, 0], [1, 0, 0]) == 1.0)
        #expect(abs(VoiceprintMath.cosineSimilarity([1, 0], [0, 1])) < 0.0001)
        #expect(VoiceprintMath.cosineSimilarity([1, 0], [-1, 0]) == -1.0)
        #expect(VoiceprintMath.cosineSimilarity([], []) == 0)
        #expect(VoiceprintMath.cosineSimilarity([1, 2], [1, 2, 3]) == 0)
    }

    @Test func centroidIsRunningMean() {
        let updated = VoiceprintMath.updatedCentroid([1, 1], count: 1, adding: [3, 3])
        #expect(updated == [2, 2])
        let third = VoiceprintMath.updatedCentroid(updated, count: 2, adding: [5, 5])
        #expect(third == [3, 3])
    }

    @Test func degenerateRepetitionIsDetected() {
        // The exact failure observed on-device.
        let loop = Array(repeating: "this", count: 30).joined(separator: ", ")
        #expect(PromptBuilder.hasDegenerateRepetition(loop))
        // CJK loop, no spaces, arbitrary offset.
        #expect(PromptBuilder.hasDegenerateRepetition("嗯好的好的好的好的好的好的好的"))
        // Normal sentences must pass.
        #expect(!PromptBuilder.hasDegenerateRepetition(
            "I think it would be better to ask for two exams in English and French."))
        #expect(!PromptBuilder.hasDegenerateRepetition(
            "我觉得这个项目可以算是公司项目，也可以是个人项目。"))
    }

    @Test func acceptableRejectsRepetitionLoops() {
        let loop = Array(repeating: "this", count: 30).joined(separator: ", ")
        #expect(!PromptBuilder().isAcceptable(loop, draft: String(repeating: "长", count: 60)))
    }

    @Test func summaryCleanupStripsMarkdown() {
        let cleaned = PromptBuilder().cleanSummary(
            "**Summary**\nA chat about apps.\n• Point one\n## End")
        #expect(!cleaned.contains("**"))
        #expect(!cleaned.contains("##"))
        #expect(cleaned.contains("• Point one"))
    }
}
