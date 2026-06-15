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

    // MARK: Diarization (agglomerative re-clustering)

    /// Same-voice embeddings: tight cluster around one direction.
    private func voiceA(_ jitter: Float) -> [Float] { [1, jitter, 0, 0] }
    private func voiceB(_ jitter: Float) -> [Float] { [0, jitter, 1, 0] }
    private func voiceC(_ jitter: Float) -> [Float] { [0, 0, jitter, 1] }

    @Test func oneSpeakerStaysOneClusterDespiteHighCap() {
        // Regression: with "4 speakers" selected and one person talking,
        // the greedy strategy split them into 4. The cap must not be a
        // target.
        let embeddings = [voiceA(0.0), voiceA(0.2), voiceA(0.1), voiceA(0.3), voiceA(0.15)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4)
        #expect(Set(labels) == [0])
    }

    @Test func twoDistinctVoicesFormTwoClusters() {
        let embeddings = [voiceA(0.1), voiceB(0.1), voiceA(0.2), voiceB(0.0)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4)
        #expect(labels == [0, 1, 0, 1])
    }

    @Test func capForcesMergesWhenExceeded() {
        // Three distinct voices but the user said 2 speakers: the two most
        // similar clusters merge; exactly 2 labels remain.
        let embeddings = [voiceA(0.0), voiceB(0.0), voiceC(0.0)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 2)
        #expect(Set(labels).count == 2)
    }

    @Test func labelsAreNumberedByFirstAppearance() {
        let embeddings = [voiceB(0.1), voiceA(0.1), voiceB(0.2), voiceA(0.0)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4)
        // First voice heard is Speaker 1 (slot 0), regardless of geometry.
        #expect(labels == [0, 1, 0, 1])
    }

    @Test func oneOddUtteranceCannotMintASpeaker() {
        // A single moderately-different utterance (cross-talk, a cough, an
        // odd register) is absorbed; it takes a second corroborating
        // utterance for a new speaker slot to exist.
        let odd: [Float] = [0.7, 0.6, 0.4, 0]   // ~0.5-0.6 sim to voiceA
        let embeddings = [voiceA(0.1), voiceA(0.2), odd, voiceA(0.0)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4)
        #expect(Set(labels) == [0])
    }

    @Test func secondUtteranceCorroboratesNewSpeaker() {
        let embeddings = [voiceA(0.1), voiceA(0.2), voiceB(0.1), voiceB(0.2)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4)
        #expect(labels == [0, 0, 1, 1])
    }

    /// The over-splitting band: same room-voice but noisy short-clip
    /// embeddings land ~0.2 similarity to voiceA — above the "drastically
    /// dissimilar" floor (0.15), below the merge threshold (0.30).
    private func nearVoiceA(_ jitter: Float) -> [Float] { [1, jitter, 4, 0] }

    @Test func shortPairCannotMintASpeaker() {
        // Two sub-anchor utterances agreeing is still coincidence — noisy
        // 1s embeddings were minting phantom speakers. They're absorbed
        // into the anchored cluster instead.
        let embeddings = [voiceA(0.1), voiceA(0.2), nearVoiceA(0.1), nearVoiceA(0.2)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4,
            durations: [3, 3, 1, 1])
        #expect(Set(labels) == [0])
    }

    @Test func withoutDurationsAPairStillMintsASpeaker() {
        // Same geometry, no duration evidence: the pre-existing behavior
        // (two corroborating utterances open a speaker) is preserved.
        let embeddings = [voiceA(0.1), voiceA(0.2), nearVoiceA(0.1), nearVoiceA(0.2)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4)
        #expect(labels == [0, 0, 1, 1])
    }

    @Test func oneLongUtteranceAnchorsAPair() {
        let embeddings = [voiceA(0.1), voiceA(0.2), nearVoiceA(0.1), nearVoiceA(0.2)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4,
            durations: [3, 3, 1, 3])
        #expect(labels == [0, 0, 1, 1])
    }

    @Test func threeShortUtterancesCorroborateASpeaker() {
        let embeddings = [
            voiceA(0.1), voiceA(0.2), nearVoiceA(0.1), nearVoiceA(0.2), nearVoiceA(0.0),
        ]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4,
            durations: [3, 3, 1, 1, 1])
        #expect(labels == [0, 0, 1, 1, 1])
    }

    @Test func aDistinctVoiceStandsEvenWhenShort() {
        // Drastically dissimilar (below the floor): a real second voice in
        // quick exchanges must not be folded into the first speaker.
        let embeddings = [voiceA(0.1), voiceA(0.2), voiceB(0.1), voiceB(0.2)]
        let labels = VoiceprintMath.agglomerativeLabels(
            embeddings: embeddings, maxClusters: 4,
            durations: [3, 3, 1, 1])
        #expect(labels == [0, 0, 1, 1])
    }

    // MARK: Stable slot matching

    @Test func freshSessionNumbersSlotsByFirstAppearance() {
        let slots = VoiceprintMath.matchClustersToSlots(
            clusters: [voiceA(0.1), voiceB(0.1)], slots: [])
        #expect(slots == [0, 1])
    }

    @Test func slotsSurviveClusterReordering() {
        // After eviction the clustering pass can order clusters
        // differently; centroids must keep the numbers pinned.
        let slots = VoiceprintMath.matchClustersToSlots(
            clusters: [voiceB(0.2), voiceA(0.2)],
            slots: [voiceA(0.1), voiceB(0.1)])
        #expect(slots == [1, 0])
    }

    @Test func unknownVoiceMintsANewSlot() {
        let slots = VoiceprintMath.matchClustersToSlots(
            clusters: [voiceA(0.2), voiceC(0.1)],
            slots: [voiceA(0.1), voiceB(0.1)])
        #expect(slots == [0, 2])
    }

    @Test func returningVoiceReclaimsItsRetiredSlot() {
        // Slot 0's utterances all aged out of memory, slot 1 still talks;
        // when voice A speaks again it must come back as slot 0, not mint
        // slot 2.
        let slots = VoiceprintMath.matchClustersToSlots(
            clusters: [voiceB(0.2), voiceA(0.3)],
            slots: [voiceA(0.0), voiceB(0.0)])
        #expect(slots == [1, 0])
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

    @Test func singleAndEmptyInputs() {
        #expect(VoiceprintMath.agglomerativeLabels(embeddings: [], maxClusters: 3) == [])
        #expect(VoiceprintMath.agglomerativeLabels(
            embeddings: [[1, 0]], maxClusters: 3) == [0])
    }
}
