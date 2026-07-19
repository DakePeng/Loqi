import Foundation
import MLX
import Testing

@testable import Loqi

/// Memory-admission decision for model loads. The full/tight band exists so
/// running SenseVoice (in-process ONNX) alongside the 2B model degrades to a
/// smaller MLX cache instead of refusing to load.
struct LLMServiceTests {
    private let headroom = ModelCatalog.qwen35_2b.requiredHeadroom
    private static let fullCache = 256 * 1024 * 1024
    private static let tightCache = 64 * 1024 * 1024
    /// Band width: exactly the footprint the tight cache gives back.
    private static let band = UInt64(fullCache - tightCache)

    @Test func comfortableMemoryAdmitsWithFullCache() {
        #expect(LLMService.admittedCacheLimit(
            free: headroom + 1, requiredHeadroom: headroom) == Self.fullCache)
    }

    @Test func tightMemoryShrinksCacheInsteadOfFailing() {
        // Weights fit, full cache does not — both edges of the band.
        #expect(LLMService.admittedCacheLimit(
            free: headroom, requiredHeadroom: headroom) == Self.tightCache)
        #expect(LLMService.admittedCacheLimit(
            free: headroom - Self.band + 1, requiredHeadroom: headroom) == Self.tightCache)
    }

    @Test func insufficientMemoryRefusesLoad() {
        #expect(LLMService.admittedCacheLimit(
            free: headroom - Self.band, requiredHeadroom: headroom) == nil)
        #expect(LLMService.admittedCacheLimit(
            free: 0, requiredHeadroom: headroom) == nil)
    }

    @Test func backgroundUnloadStillMarksModelUnloaded() async {
        // A backgrounded unload skips the Metal-touching cache clear but
        // must still drop the model state so a foreground load starts fresh.
        let llm = LLMService()

        await llm.setBackgrounded(true)
        await llm.unload()

        let state = await llm.loadState
        if case .unloaded = state {
            // Expected.
        } else {
            Issue.record("background unload should still mark the model unloaded")
        }
    }

    @Test func backgroundHuggingFaceSnapshotCountsAsDownloaded() throws {
        let model = ModelCatalog.qwen35_0_8b
        let snapshot = URL.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshot) }

        let weight = snapshot.appending(path: "weights.safetensors")
        try Data(count: 10).write(to: weight)
        try HuggingFaceBackgroundDownloader().writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(
                path: "weights.safetensors",
                size: 10)],
            to: snapshot)
        if model.supportsVision {
            try Data("{}".utf8).write(to: snapshot.appending(path: "preprocessor_config.json"))
        }

        #expect(LLMService.backgroundHFSnapshotLooksComplete(model: model, at: snapshot))
    }

    @Test func backgroundHuggingFaceSnapshotMissingVisionConfigIsNotDownloaded() throws {
        let model = ModelCatalog.qwen35_0_8b
        let snapshot = URL.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshot) }

        try Data(count: 10).write(to: snapshot.appending(path: "weights.safetensors"))
        try HuggingFaceBackgroundDownloader().writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(
                path: "weights.safetensors",
                size: 10)],
            to: snapshot)

        #expect(!LLMService.backgroundHFSnapshotLooksComplete(model: model, at: snapshot))
    }

    @Test func backgroundHuggingFaceSnapshotWithoutWeightsIsNotDownloaded() throws {
        let model = ModelCatalog.qwen35_0_8b
        let snapshot = URL.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshot) }

        try Data("{}".utf8).write(to: snapshot.appending(path: "preprocessor_config.json"))
        try Data("{}".utf8).write(to: snapshot.appending(path: "config.json"))
        try HuggingFaceBackgroundDownloader().writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(
                path: "config.json",
                size: 2)],
            to: snapshot)

        #expect(!LLMService.backgroundHFSnapshotLooksComplete(model: model, at: snapshot))
    }

    @Test func backgroundHuggingFaceSnapshotIgnoresUnmanifestedWeights() throws {
        let model = ModelCatalog.qwen35_0_8b
        let snapshot = URL.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshot) }

        try Data("{}".utf8).write(to: snapshot.appending(path: "preprocessor_config.json"))
        try Data("{}".utf8).write(to: snapshot.appending(path: "config.json"))
        try Data(count: 10).write(to: snapshot.appending(path: "weights.safetensors"))
        try HuggingFaceBackgroundDownloader().writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(
                path: "config.json",
                size: 2)],
            to: snapshot)

        #expect(!LLMService.backgroundHFSnapshotLooksComplete(model: model, at: snapshot))
    }
}

/// `<think>` leakage from hybrid models is stripped, never asserted on —
/// one leaked token must not crash a recording.
struct StripThinkingTests {
    @Test func stripsClosedSpan() {
        #expect(LLMService.stripThinking("<think>reasoning</think>答案在这里")
            == "答案在这里")
    }

    @Test func stripsUnterminatedTrailingSpan() {
        #expect(LLMService.stripThinking("Answer first. <think>then it trailed off")
            == "Answer first.")
    }

    @Test func leavesCleanTextAlone() {
        #expect(LLMService.stripThinking("纪要：发布定于7月10日")
            == "纪要：发布定于7月10日")
    }
}

struct DiagnosticTokenEstimateTests {
    @Test func usesOnePointFiveContentCharsPerToken() {
        #expect(LLMService.estimatedDiagnosticTokens(in: "发布定于七月十日") == 8 / 1.5)
    }

    @Test func ignoresPunctuationAndWhitespace() {
        let plain = LLMService.estimatedDiagnosticTokens(in: "发布定于七月十日")
        let punctuated = LLMService.estimatedDiagnosticTokens(in: "发布，定于七月十日。\n")
        #expect(punctuated == plain)
    }
}

@MainActor
struct PipelineResourceTests {
    @Test func llmResourceMessagesCollapseToOneVisibleStatus() {
        let messages: [CaptionPipeline.StatusKey: String] = [
            .llm: "Warming up the AI model...",
            .thermal: "AI features off (device hot)",
            .memory: "AI features paused (low memory)",
            .asr: "SenseVoice unavailable...",
        ]

        #expect(CaptionPipeline.visibleStatusMessages(from: messages) == [
            "AI features paused (low memory)",
            "SenseVoice unavailable...",
        ])
    }

    @Test func backgroundSuspendsPostHocWorkThatCanReachMetal() {
        #expect(SummaryJobCenter.shouldSuspendForBackground(.downloadingModel(0)))
        #expect(SummaryJobCenter.shouldSuspendForBackground(
            .summarizing(done: 0, total: 1)))
        #expect(SummaryJobCenter.shouldSuspendForBackground(
            .retranscribing(.identifyingSpeakers(0))))
        #expect(SummaryJobCenter.shouldSuspendForBackground(
            .retranscribing(.transcribing(0))))
        #expect(SummaryJobCenter.shouldSuspendForBackground(
            .retranscribing(.cleaningUpTranscript(0))))
        #expect(SummaryJobCenter.shouldSuspendForBackground(
            .importing(.transcribing(0))))
        // The parked-but-started states must suspend too — a .preparing job
        // is mid-setup and a speaker download reaches the ANE/Metal; leaving
        // either running in the background risks the process abort.
        #expect(SummaryJobCenter.shouldSuspendForBackground(.preparing))
        #expect(SummaryJobCenter.shouldSuspendForBackground(.downloadingSpeakerModel(0)))
        // Already-parked states are NOT re-suspended (nothing to cancel).
        #expect(!SummaryJobCenter.shouldSuspendForBackground(.queuedRetranscribe))
        #expect(!SummaryJobCenter.shouldSuspendForBackground(.pausedForRecording))
        #expect(!SummaryJobCenter.shouldSuspendForBackground(.pausedForBackground))
    }

    @Test func recordingResumeLeavesLLMJobsPausedWhileBackgrounded() {
        #expect(!SummaryJobCenter.shouldResumeLLMJobsAfterRecording(isBackgrounded: true))
        #expect(SummaryJobCenter.shouldResumeLLMJobsAfterRecording(isBackgrounded: false))
    }

    /// Memory warnings full-unload the LLM during import-only jobs (their
    /// pipeline is ASR/translation; the auto-summary afterwards is its own
    /// job) but only shed the cache while a job actually uses the model.
    @Test func memoryWarningUnloadsLLMDuringImportOnlyJobs() {
        #expect(SummaryJobCenter.usesLLM(.summarizing(done: 0, total: 1)))
        #expect(SummaryJobCenter.usesLLM(.downloadingModel(0)))
        #expect(SummaryJobCenter.usesLLM(.retranscribing(.transcribing(0))))
        #expect(!SummaryJobCenter.usesLLM(.importing(.transcribing(0))))
        // …except the cleanup phase, which actively generates on the 230M.
        #expect(SummaryJobCenter.usesLLM(.importing(.cleaningUpTranscript(0))))
        #expect(!SummaryJobCenter.usesLLM(.queuedRetranscribe))
        #expect(!SummaryJobCenter.usesLLM(.pausedForBackground))
    }

    /// A background GPU abort must map to the suspend path even when the
    /// scene flag hasn't flipped yet (scenePhase delivery lag) — matched
    /// by error content. Anything else stays a real error.
    @Test func backgroundGPUAbortIsRecognizedByContent() {
        #expect(LLMService.isBackgroundGPUAbort(.caught(
            "[METAL] Command buffer execution failed: Insufficient Permission "
            + "(to submit GPU work from background) "
            + "(00000006:kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted)")))
        #expect(!LLMService.isBackgroundGPUAbort(.caught(
            "[METAL] Command buffer execution failed: Caused GPU Timeout Error")))
        #expect(!LLMService.isBackgroundGPUAbort(.caught("broadcast shape mismatch")))
    }

    /// A manual re-summarize with unchanged style+length is a redo and
    /// must bypass the cached-notes short-circuit (otherwise it reduce-
    /// only re-renders the same notes and "does nothing"); a style or
    /// length change keeps the cheap reduce-only path.
    @Test func sameStyleResummarizeIsARedoRequest() {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        var record = SessionRecord(
            mode: .captions, startedAt: timestamp, endedAt: timestamp, entries: [])

        // No summary yet: first-time summarize, not a redo.
        #expect(!SummaryJobCenter.isRedoRequest(record, style: .meeting, length: .standard))

        record.summary = "已有摘要"
        record.summaryStyle = SummaryStyle.meeting.rawValue
        record.summaryLength = SummaryLength.standard.rawValue
        #expect(SummaryJobCenter.isRedoRequest(record, style: .meeting, length: .standard))
        // Changed style or length: cheap reduce-only, not a redo.
        #expect(!SummaryJobCenter.isRedoRequest(record, style: .journal, length: .standard))
        #expect(!SummaryJobCenter.isRedoRequest(record, style: .meeting, length: .detailed))
        // Deleted session: nothing to redo.
        #expect(!SummaryJobCenter.isRedoRequest(nil, style: .meeting, length: .standard))
    }

    /// A resume must recognize the mid-map checkpoint so it skips the
    /// hygiene pass — re-running hygiene can wipe the checkpoint and
    /// remap the whole transcript (the background→foreground 0/N bug).
    @Test func resumeRecognizesUsableMapCheckpoint() {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let pair = LanguagePair(source: .chinese, target: .chinese)
        let covered = SessionRecord.Entry(
            sourceText: "第一段", translation: nil, speaker: nil,
            direction: pair, timestamp: timestamp)
        let uncovered = SessionRecord.Entry(
            sourceText: "第二段", translation: nil, speaker: nil,
            direction: pair, timestamp: timestamp)
        var record = SessionRecord(
            mode: .captions,
            startedAt: timestamp,
            endedAt: timestamp,
            entries: [covered, uncovered])

        // Fresh record: nothing to resume from.
        #expect(!SummaryJobCenter.hasUsableMapCheckpoint(record))

        // Mid-map checkpoint: one chunk mapped, coverage through it.
        record.chunkNotes = [.init(
            headline: "第一段", startedAt: timestamp, anchorEntryID: covered.id)]
        record.liveNotesEndEntryID = covered.id
        #expect(SummaryJobCenter.hasUsableMapCheckpoint(record))

        // Full coverage (resume during reduce) still counts.
        record.liveNotesEndEntryID = uncovered.id
        #expect(SummaryJobCenter.hasUsableMapCheckpoint(record))

        // A coverage boundary that no longer resolves (entry edited away)
        // can't be resumed from — hygiene must run.
        record.liveNotesEndEntryID = UUID()
        #expect(!SummaryJobCenter.hasUsableMapCheckpoint(record))
    }
}
