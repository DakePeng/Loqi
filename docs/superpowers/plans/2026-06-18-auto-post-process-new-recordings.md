# Auto Post-Process New Recordings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings toggle that makes newly recorded sessions use the best already-downloaded ASR and diarization post-processing before their first summary.

**Architecture:** Keep the feature in the existing post-hoc job system. Add a pure policy for model selection, persist the recording-time speaker picker on each new session, compose existing offline ASR and file diarization in a focused post-processor, then route only post-stop auto-summary through that processor.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, XcodeGen/Xcode project, existing Loqi ASR/diarization/summary services.

---

## File Map

- Create `Loqi/Pipeline/Summary/NewRecordingPostProcessPlan.swift`: pure policy that selects Qwen3-ASR, SenseVoice, or no ASR, plus whether to run offline diarization.
- Create `Loqi/Pipeline/Summary/NewRecordingPostProcessor.swift`: best-effort service that optionally re-transcribes, optionally applies file diarization, regenerates translations, and returns a record ready for summary.
- Modify `Loqi/Pipeline/Summary/SessionRetranscriber.swift`: add `.identifyingSpeakers(Double)` to the existing phase enum so post-processing progress can stay under `.retranscribing`.
- Modify `Loqi/Pipeline/Summary/SummaryJobCenter.swift`: add new-session post-process request routing, serialize it through the existing re-transcribe queue, and run the normal summarizer after post-processing.
- Modify `Loqi/Models/SessionRecord.swift`: add optional `recordingSpeakerCount` to persist whether the recording was made with speaker separation enabled.
- Modify `Loqi/Support/SessionArchive.swift`: add `speakerCount` to `SessionArtifacts` and persist it into `SessionRecord`.
- Modify `Loqi/Support/CaptionPipeline.swift`: pass `captionSpeakerCount` into clean saves and crash journal snapshots.
- Modify `Loqi/Features/Settings/SettingsView.swift`: add the persisted toggle under high-accuracy re-transcription.
- Modify `Loqi/Features/Sessions/SessionDetailView.swift`: route only new-session auto-summary through the new job when the toggle is on, preserving the existing LLM download consent gate.
- Modify `Loqi/Features/Sessions/SessionsView.swift`: display retranscribe speaker-identification progress in list rows.
- Create `LoqiTests/NewRecordingPostProcessPlanTests.swift`: pure policy coverage.
- Create `LoqiTests/NewRecordingPostProcessorTests.swift`: pure speaker-mapping helper coverage.
- Modify `LoqiTests/SessionRecordTests.swift`: codable compatibility and round-trip coverage for `recordingSpeakerCount`.

## Prerequisites

The local `xcodebuild` may fail when Xcode is not selected. If `xcodebuild -list -project Loqi.xcodeproj` reports that the active developer directory is CommandLineTools, run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then verify the scheme:

```bash
xcodebuild -list -project Loqi.xcodeproj
```

Expected: the `Loqi` scheme appears and lists `LoqiTests` as its test target.

---

### Task 1: Add The Pure Post-Process Policy

**Files:**
- Create: `Loqi/Pipeline/Summary/NewRecordingPostProcessPlan.swift`
- Create: `LoqiTests/NewRecordingPostProcessPlanTests.swift`

- [ ] **Step 1: Write the failing policy tests**

Create `LoqiTests/NewRecordingPostProcessPlanTests.swift`:

```swift
import Testing
@testable import Loqi

struct NewRecordingPostProcessPlanTests {
    @Test func disabledSettingSkipsAllPostProcessing() {
        let plan = NewRecordingPostProcessPlan.make(
            enabled: false,
            qwen3Downloaded: true,
            senseVoiceDownloaded: true,
            offlineDiarizerDownloaded: true,
            speakerSeparationEnabledForRecording: true)

        #expect(plan.asr == .none)
        #expect(plan.runDiarization == false)
        #expect(plan.hasEnhancement == false)
    }

    @Test func qwen3WinsWhenBothASRModelsAreDownloaded() {
        let plan = NewRecordingPostProcessPlan.make(
            enabled: true,
            qwen3Downloaded: true,
            senseVoiceDownloaded: true,
            offlineDiarizerDownloaded: false,
            speakerSeparationEnabledForRecording: false)

        #expect(plan.asr == .qwen3ASR)
        #expect(plan.offlineBackend == .qwen3ASR)
        #expect(plan.runDiarization == false)
        #expect(plan.hasEnhancement == true)
    }

    @Test func senseVoiceRunsWhenQwen3IsMissing() {
        let plan = NewRecordingPostProcessPlan.make(
            enabled: true,
            qwen3Downloaded: false,
            senseVoiceDownloaded: true,
            offlineDiarizerDownloaded: false,
            speakerSeparationEnabledForRecording: false)

        #expect(plan.asr == .senseVoice)
        #expect(plan.offlineBackend == .senseVoice)
        #expect(plan.runDiarization == false)
    }

    @Test func asrIsSkippedWhenNoASRModelIsDownloaded() {
        let plan = NewRecordingPostProcessPlan.make(
            enabled: true,
            qwen3Downloaded: false,
            senseVoiceDownloaded: false,
            offlineDiarizerDownloaded: false,
            speakerSeparationEnabledForRecording: false)

        #expect(plan.asr == .none)
        #expect(plan.offlineBackend == nil)
        #expect(plan.runDiarization == false)
        #expect(plan.hasEnhancement == false)
    }

    @Test func diarizationRequiresDownloadedOfflineModelAndRecordingIntent() {
        let withIntent = NewRecordingPostProcessPlan.make(
            enabled: true,
            qwen3Downloaded: false,
            senseVoiceDownloaded: false,
            offlineDiarizerDownloaded: true,
            speakerSeparationEnabledForRecording: true)

        let withoutIntent = NewRecordingPostProcessPlan.make(
            enabled: true,
            qwen3Downloaded: false,
            senseVoiceDownloaded: false,
            offlineDiarizerDownloaded: true,
            speakerSeparationEnabledForRecording: false)

        let withoutModel = NewRecordingPostProcessPlan.make(
            enabled: true,
            qwen3Downloaded: false,
            senseVoiceDownloaded: false,
            offlineDiarizerDownloaded: false,
            speakerSeparationEnabledForRecording: true)

        #expect(withIntent.runDiarization == true)
        #expect(withIntent.hasEnhancement == true)
        #expect(withoutIntent.runDiarization == false)
        #expect(withoutModel.runDiarization == false)
    }
}
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/NewRecordingPostProcessPlanTests
```

Expected: FAIL because `NewRecordingPostProcessPlan` does not exist.

- [ ] **Step 3: Implement the policy**

Create `Loqi/Pipeline/Summary/NewRecordingPostProcessPlan.swift`:

```swift
import Foundation

struct NewRecordingPostProcessPlan: Equatable {
    enum ASR: Equatable {
        case qwen3ASR
        case senseVoice
        case none
    }

    var asr: ASR
    var runDiarization: Bool

    var hasEnhancement: Bool {
        asr != .none || runDiarization
    }

    var offlineBackend: OfflineTranscriber.Backend? {
        switch asr {
        case .qwen3ASR:
            .qwen3ASR
        case .senseVoice:
            .senseVoice
        case .none:
            nil
        }
    }

    static func make(
        enabled: Bool,
        qwen3Downloaded: Bool,
        senseVoiceDownloaded: Bool,
        offlineDiarizerDownloaded: Bool,
        speakerSeparationEnabledForRecording: Bool
    ) -> Self {
        guard enabled else {
            return .init(asr: .none, runDiarization: false)
        }

        let asr: ASR
        if qwen3Downloaded {
            asr = .qwen3ASR
        } else if senseVoiceDownloaded {
            asr = .senseVoice
        } else {
            asr = .none
        }

        return .init(
            asr: asr,
            runDiarization: offlineDiarizerDownloaded
                && speakerSeparationEnabledForRecording)
    }
}
```

- [ ] **Step 4: Run the policy tests and verify they pass**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/NewRecordingPostProcessPlanTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/Summary/NewRecordingPostProcessPlan.swift LoqiTests/NewRecordingPostProcessPlanTests.swift
git commit -m "Add new recording post-process policy"
```

---

### Task 2: Persist Recording-Time Speaker Separation Intent

**Files:**
- Modify: `Loqi/Models/SessionRecord.swift`
- Modify: `Loqi/Support/SessionArchive.swift`
- Modify: `Loqi/Support/CaptionPipeline.swift`
- Modify: `LoqiTests/SessionRecordTests.swift`

- [ ] **Step 1: Write failing model persistence tests**

Append these tests inside `struct SessionRecordTests` in `LoqiTests/SessionRecordTests.swift`:

```swift
    @Test func recordingSpeakerCountDecodesAsNilForOlderRecords() throws {
        var record = makeRecord()
        record.recordingSpeakerCount = nil

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionRecord.self, from: data)

        #expect(decoded.recordingSpeakerCount == nil)
    }

    @Test func recordingSpeakerCountRoundTrips() throws {
        var record = makeRecord()
        record.recordingSpeakerCount = -1

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(record))

        #expect(decoded.recordingSpeakerCount == -1)
        #expect(VoiceprintService.clusterCap(
            forPickerValue: decoded.recordingSpeakerCount ?? 0) == 8)
    }
```

- [ ] **Step 2: Run the persistence tests and verify they fail**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/SessionRecordTests
```

Expected: FAIL because `SessionRecord.recordingSpeakerCount` does not exist.

- [ ] **Step 3: Add the session field**

In `Loqi/Models/SessionRecord.swift`, insert this property immediately after `speakerNames`:

```swift
    /// Speaker-count picker value active while the recording was made.
    /// nil for legacy records and imports. `VoiceprintService.clusterCap`
    /// interprets the value: -1 = Auto, 2+ = speaker cap, 0/1 = off.
    var recordingSpeakerCount: Int?
```

- [ ] **Step 4: Add the artifact field and persist it**

In `Loqi/Support/SessionArchive.swift`, update `SessionArtifacts` to include `speakerCount`:

```swift
struct SessionArtifacts: Sendable {
    var sessionID: UUID
    var audioFileName: String?
    var chunkNotes: [SessionRecord.ChunkNote] = []
    var notesEndEntryID: UUID?
    /// Speaker-count picker value active while the session was recorded.
    var speakerCount: Int?
    /// Wall-clock -> audio-file mapping for stamping entry offsets.
    var timeline: AudioTimeline?
    /// Photos attached while recording.
    var attachments: [SessionRecord.Attachment] = []
}
```

In `SessionArchive.save`, after constructing `record`, set the field before `record.unseen = true`:

```swift
        record.recordingSpeakerCount = artifacts?.speakerCount
```

- [ ] **Step 5: Pass the active picker value from live saves**

In `Loqi/Support/CaptionPipeline.swift`, inside `writeJournal()`, after `speakerNames: speakerNames)` add:

```swift
        record.recordingSpeakerCount = captionSpeakerCount
```

In `endSession()`, update the `SessionArtifacts` initializer to pass `speakerCount`:

```swift
                artifacts: SessionArtifacts(
                    sessionID: sessionID ?? UUID(),
                    audioFileName: audioFileName,
                    chunkNotes: liveNotes,
                    notesEndEntryID: notesEndEntryID,
                    speakerCount: captionSpeakerCount,
                    timeline: audioFileName != nil && !audioAnchors.isEmpty
                        ? AudioTimeline(anchors: audioAnchors) : nil,
                    attachments: liveAttachments))
```

- [ ] **Step 6: Run the model tests**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/SessionRecordTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Loqi/Models/SessionRecord.swift Loqi/Support/SessionArchive.swift Loqi/Support/CaptionPipeline.swift LoqiTests/SessionRecordTests.swift
git commit -m "Persist recording speaker count"
```

---

### Task 3: Add The Best-Effort New Recording Post-Processor

**Files:**
- Create: `Loqi/Pipeline/Summary/NewRecordingPostProcessor.swift`
- Modify: `Loqi/Pipeline/Summary/SessionRetranscriber.swift`
- Create: `LoqiTests/NewRecordingPostProcessorTests.swift`

- [ ] **Step 1: Write failing pure helper tests**

Create `LoqiTests/NewRecordingPostProcessorTests.swift`:

```swift
import Foundation
import Testing
@testable import Loqi

struct NewRecordingPostProcessorTests {
    @Test func applyingDiarizationSegmentsMapsSpeakersByAudioOffset() {
        let direction = LanguagePair(source: .english, target: .english)
        let base = Date(timeIntervalSince1970: 1_000)
        var record = SessionRecord(
            mode: .captions,
            startedAt: base,
            endedAt: base.addingTimeInterval(20),
            entries: [
                .init(
                    sourceText: "first",
                    translation: nil,
                    speaker: nil,
                    direction: direction,
                    timestamp: base.addingTimeInterval(1),
                    audioOffset: 1),
                .init(
                    sourceText: "second",
                    translation: nil,
                    speaker: nil,
                    direction: direction,
                    timestamp: base.addingTimeInterval(7),
                    audioOffset: 7),
                .init(
                    sourceText: "third",
                    translation: nil,
                    speaker: nil,
                    direction: direction,
                    timestamp: base.addingTimeInterval(13),
                    audioOffset: 13)
            ])

        let segments = [
            SpeakerAttribution.Segment(slot: 0, start: 0, end: 5),
            SpeakerAttribution.Segment(slot: 1, start: 5, end: 11),
            SpeakerAttribution.Segment(slot: 0, start: 11, end: 17)
        ]

        NewRecordingPostProcessor.applyDiarizationSegments(
            segments, to: &record)

        #expect(record.entries.map(\.speaker) == [0, 1, 0])
    }

    @Test func applyingDiarizationSegmentsUsesTimestampFallbackForLegacyOffsets() {
        let direction = LanguagePair(source: .english, target: .english)
        let base = Date(timeIntervalSince1970: 1_000)
        var record = SessionRecord(
            mode: .captions,
            startedAt: base,
            endedAt: base.addingTimeInterval(20),
            entries: [
                .init(
                    sourceText: "legacy",
                    translation: nil,
                    speaker: nil,
                    direction: direction,
                    timestamp: base.addingTimeInterval(12))
            ])

        let segments = [
            SpeakerAttribution.Segment(slot: 2, start: 10, end: 14)
        ]

        NewRecordingPostProcessor.applyDiarizationSegments(
            segments, to: &record)

        #expect(record.entries.map(\.speaker) == [2])
    }
}
```

- [ ] **Step 2: Run the helper tests and verify they fail**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/NewRecordingPostProcessorTests
```

Expected: FAIL because `NewRecordingPostProcessor` does not exist.

- [ ] **Step 3: Extend retranscribe progress phases**

In `Loqi/Pipeline/Summary/SessionRetranscriber.swift`, replace the `Phase` enum with:

```swift
    enum Phase: Equatable {
        case transcribing(Double)   // 0...1 through the file
        case identifyingSpeakers(Double)
        case translating(Double)
    }
```

- [ ] **Step 4: Implement the processor**

Create `Loqi/Pipeline/Summary/NewRecordingPostProcessor.swift`:

```swift
import AVFoundation
import Foundation
import os

@MainActor
struct NewRecordingPostProcessor {
    let llm: LLMService
    let translator: TranslationCoordinator
    let voiceprint: VoiceprintService
    let hotwords: HotwordStore
    private let logger = Logger(
        subsystem: "com.kunzhipeng.loqi",
        category: "new-post-process")

    init(
        llm: LLMService,
        translator: TranslationCoordinator,
        voiceprint: VoiceprintService,
        hotwords: HotwordStore
    ) {
        self.llm = llm
        self.translator = translator
        self.voiceprint = voiceprint
        self.hotwords = hotwords
    }

    func process(
        _ record: SessionRecord,
        plan: NewRecordingPostProcessPlan,
        onPhase: @escaping @MainActor @Sendable (SessionRetranscriber.Phase) -> Void
    ) async throws -> SessionRecord {
        guard plan.hasEnhancement,
              let fileName = record.audioFileName
        else { return record }

        let url = SessionArchive.recordingURL(fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return record
        }

        var updated = record
        if let backend = plan.offlineBackend {
            do {
                updated = try await retranscribe(
                    updated, audioURL: url, backend: backend, onPhase: onPhase)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("new-session ASR post-process failed: \(error.localizedDescription)")
            }
        }

        if plan.runDiarization {
            do {
                try Task.checkCancellation()
                updated = try await diarize(
                    updated, audioURL: url, onPhase: onPhase)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("new-session diarization failed: \(error.localizedDescription)")
            }
        }

        return updated
    }

    private func retranscribe(
        _ record: SessionRecord,
        audioURL: URL,
        backend: OfflineTranscriber.Backend,
        onPhase: @escaping @MainActor @Sendable (SessionRetranscriber.Phase) -> Void
    ) async throws -> SessionRecord {
        guard let direction = record.entries.first?.direction else { return record }
        let audioFile = try AVAudioFile(forReading: audioURL)
        if backend == .qwen3ASR {
            await llm.unload()
        }

        onPhase(.transcribing(0))
        let utterances = try await OfflineTranscriber.transcribe(
            audioFile,
            language: direction.source,
            backend: backend,
            hotwords: hotwords.biasStrings(for: direction.source)
        ) { fraction in
            onPhase(.transcribing(fraction))
        }
        guard !utterances.isEmpty else { return record }

        let speakers = inheritedSpeakers(utterances: utterances, from: record)
        var entries = utterances.enumerated().map { index, utterance in
            SessionRecord.Entry(
                sourceText: utterance.text,
                translation: nil,
                speaker: speakers[index],
                direction: direction,
                timestamp: record.startedAt.addingTimeInterval(utterance.start),
                audioOffset: utterance.start)
        }

        if direction.source != direction.target {
            await translator.addDirection(direction)
            for index in entries.indices {
                try Task.checkCancellation()
                onPhase(.translating(Double(index) / Double(max(entries.count, 1))))
                entries[index].translation = try? await translator.draft(
                    entries[index].sourceText, direction: direction)
            }
        }

        var updated = record
        updated.entries = entries
        updated.chunkNotes = nil
        updated.liveNotesEndEntryID = nil
        updated.summary = nil
        updated.summaryEdited = nil
        return updated
    }

    private func diarize(
        _ record: SessionRecord,
        audioURL: URL,
        onPhase: @escaping @MainActor @Sendable (SessionRetranscriber.Phase) -> Void
    ) async throws -> SessionRecord {
        guard VoiceprintService.isOfflineDiarizerDownloaded,
              let speakerCount = record.recordingSpeakerCount,
              let cap = VoiceprintService.clusterCap(forPickerValue: speakerCount)
        else { return record }

        onPhase(.identifyingSpeakers(0))
        let segments = try await voiceprint.diarizeFile(
            url: audioURL, maxSpeakers: cap, source: .current
        ) { progress in
            Task { @MainActor in
                switch progress {
                case .download:
                    break
                case .analysis(let fraction):
                    onPhase(.identifyingSpeakers(fraction))
                }
            }
        }

        var updated = record
        Self.applyDiarizationSegments(segments, to: &updated)
        updated.chunkNotes = nil
        updated.liveNotesEndEntryID = nil
        updated.summary = nil
        updated.summaryEdited = nil
        return updated
    }

    private func inheritedSpeakers(
        utterances: [OfflineTranscriber.Utterance],
        from record: SessionRecord
    ) -> [Int?] {
        SessionRetranscriber.inheritSpeakers(
            for: utterances.map { ($0.start, $0.end) },
            from: record)
    }

    nonisolated static func applyDiarizationSegments(
        _ segments: [SpeakerAttribution.Segment],
        to record: inout SessionRecord
    ) {
        let utterances = record.entries.enumerated().map { index, entry in
            let start = record.resolvedAudioOffset(of: entry)
            let end: TimeInterval
            if index + 1 < record.entries.count {
                end = max(
                    start,
                    record.resolvedAudioOffset(of: record.entries[index + 1]))
            } else {
                end = start + 3
            }
            return (start: start, end: end)
        }
        let slots = SpeakerAttribution.attribute(utterances: utterances, to: segments)
        for index in record.entries.indices {
            record.entries[index].speaker = slots[index]
        }
    }
}
```

- [ ] **Step 5: Run the helper tests**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/NewRecordingPostProcessorTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Loqi/Pipeline/Summary/NewRecordingPostProcessor.swift Loqi/Pipeline/Summary/SessionRetranscriber.swift LoqiTests/NewRecordingPostProcessorTests.swift
git commit -m "Add new recording post-processor"
```

---

### Task 4: Route New-Recording Post-Processing Through SummaryJobCenter

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryJobCenter.swift`

- [ ] **Step 1: Add request shape to the serial ASR queue**

In `SummaryJobCenter`, replace `RetranscribeRequest` with this version:

```swift
    private struct RetranscribeRequest {
        enum Kind {
            case manual
            case newRecording(plan: NewRecordingPostProcessPlan)
        }

        let sessionID: UUID
        let style: SummaryStyle
        let length: SummaryLength
        let allowDownload: Bool
        let suggestVocabulary: Bool
        let kind: Kind
    }
```

Update manual request construction in `enqueueRetranscribe`:

```swift
            retranscribeQueue.append(RetranscribeRequest(
                sessionID: id, style: style, length: length,
                allowDownload: allowDownload,
                suggestVocabulary: false,
                kind: .manual))
```

- [ ] **Step 2: Add the public new-session entry point**

Insert this method after `retranscribeAndSummarize`:

```swift
    func postProcessAndSummarizeNewSession(
        sessionID: UUID,
        style: SummaryStyle,
        length: SummaryLength,
        allowDownload: Bool = false,
        suggestVocabulary: Bool = false
    ) {
        guard !isRecording(),
              !isBusy(sessionID),
              let session = archive.sessions.first(where: { $0.id == sessionID })
        else { return }

        let speakerEnabled = VoiceprintService.clusterCap(
            forPickerValue: session.recordingSpeakerCount ?? 0) != nil
        let plan = NewRecordingPostProcessPlan.make(
            enabled: true,
            qwen3Downloaded: Qwen3ASRModelStore.isInstalled,
            senseVoiceDownloaded: SenseVoiceModelStore.isInstalled,
            offlineDiarizerDownloaded: VoiceprintService.isOfflineDiarizerDownloaded,
            speakerSeparationEnabledForRecording: speakerEnabled)

        guard plan.hasEnhancement,
              SessionRetranscriber.canRetranscribe(session)
        else {
            summarize(
                sessionID: sessionID,
                style: style,
                length: length,
                allowDownload: allowDownload,
                suggestVocabulary: suggestVocabulary)
            return
        }

        errors[sessionID] = nil
        activities[sessionID] = .queuedRetranscribe
        retranscribeQueue.append(RetranscribeRequest(
            sessionID: sessionID,
            style: style,
            length: length,
            allowDownload: allowDownload,
            suggestVocabulary: suggestVocabulary,
            kind: .newRecording(plan: plan)))
        drainRetranscribeQueue()
    }
```

- [ ] **Step 3: Split the queue runner by request kind**

Replace `runRetranscribe(_:)` with:

```swift
    private func runRetranscribe(_ request: RetranscribeRequest) async {
        switch request.kind {
        case .manual:
            await runManualRetranscribe(request)
        case .newRecording(let plan):
            await runNewRecordingPostProcess(request, plan: plan)
        }
    }
```

Add this method immediately below it:

```swift
    private func runManualRetranscribe(_ request: RetranscribeRequest) async {
        let sessionID = request.sessionID
        guard let session = archive.sessions.first(where: { $0.id == sessionID })
        else {
            activities[sessionID] = nil
            return
        }
        activities[sessionID] = .retranscribing(.transcribing(0))
        beginGrace(sessionID, name: "retranscribe")
        defer { finishJob(sessionID) }
        do {
            guard llmEnabled else { throw JobError.aiDisabled }
            if !request.allowDownload, !LLMService.isDownloaded(model: ModelCatalog.current) {
                throw LLMServiceError.modelNotDownloaded
            }
            let retranscriber = SessionRetranscriber(
                llm: llm, translator: translator, hotwords: hotwords)
            let updated = try await retranscriber.retranscribe(session) { [weak self] phase in
                self?.retranscribeProgress(sessionID: sessionID, phase: phase)
            }
            try Task.checkCancellation()
            archive.update(updated)
            activeSummarizeRequest[sessionID] = SummarizeRequest(
                style: request.style,
                length: request.length,
                allowDownload: request.allowDownload,
                suggestVocabulary: false)
            try await loadModel(sessionID: sessionID, allowDownload: request.allowDownload)
            activities[sessionID] = .summarizing(done: 0, total: 0)
            try await runSummarize(
                sessionID: sessionID,
                style: request.style,
                length: request.length,
                suggestVocabulary: false)
        } catch is CancellationError {
        } catch {
            errors[sessionID] = error.localizedDescription
        }
    }
```

- [ ] **Step 4: Add the new-recording runner**

Add this method below `runManualRetranscribe`:

```swift
    private func runNewRecordingPostProcess(
        _ request: RetranscribeRequest,
        plan: NewRecordingPostProcessPlan
    ) async {
        let sessionID = request.sessionID
        guard let session = archive.sessions.first(where: { $0.id == sessionID })
        else {
            activities[sessionID] = nil
            return
        }
        activities[sessionID] = .retranscribing(.transcribing(0))
        beginGrace(sessionID, name: "new-post-process")
        defer { finishJob(sessionID) }
        do {
            guard llmEnabled else { throw JobError.aiDisabled }
            if !request.allowDownload, !LLMService.isDownloaded(model: ModelCatalog.current) {
                throw LLMServiceError.modelNotDownloaded
            }

            let processor = NewRecordingPostProcessor(
                llm: llm,
                translator: translator,
                voiceprint: voiceprint,
                hotwords: hotwords)
            let updated = try await processor.process(session, plan: plan) { [weak self] phase in
                self?.retranscribeProgress(sessionID: sessionID, phase: phase)
            }
            try Task.checkCancellation()
            archive.update(updated)

            activeSummarizeRequest[sessionID] = SummarizeRequest(
                style: request.style,
                length: request.length,
                allowDownload: request.allowDownload,
                suggestVocabulary: request.suggestVocabulary)
            try await loadModel(sessionID: sessionID, allowDownload: request.allowDownload)
            activities[sessionID] = .summarizing(done: 0, total: 0)
            try await runSummarize(
                sessionID: sessionID,
                style: request.style,
                length: request.length,
                suggestVocabulary: request.suggestVocabulary)
        } catch is CancellationError {
        } catch {
            errors[sessionID] = error.localizedDescription
        }
    }
```

- [ ] **Step 5: Add progress handling for speaker identification**

In `retranscribeProgress(sessionID:phase:)`, add this switch case between `.transcribing` and `.translating`:

```swift
        case .identifyingSpeakers(let f):
            setProgress(sessionID, .retranscribing(.identifyingSpeakers(Self.percent(f))),
                        phaseKey: "re.diarize", fraction: f)
```

- [ ] **Step 6: Run a focused build**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/NewRecordingPostProcessPlanTests -only-testing:LoqiTests/NewRecordingPostProcessorTests
```

Expected: PASS and no compile errors in `SummaryJobCenter`.

- [ ] **Step 7: Commit**

```bash
git add Loqi/Pipeline/Summary/SummaryJobCenter.swift
git commit -m "Route new recording post-processing"
```

---

### Task 5: Add The Settings Toggle And Auto-Summary Routing

**Files:**
- Modify: `Loqi/Features/Settings/SettingsView.swift`
- Modify: `Loqi/Features/Sessions/SessionDetailView.swift`

- [ ] **Step 1: Add the Settings storage and toggle**

In `SettingsView`, add this property beside the existing `@AppStorage` properties:

```swift
    @AppStorage("summary.autoPostProcessNewRecordings")
    private var autoPostProcessNewRecordings = false
```

In the `High-accuracy re-transcription` section, add the toggle before the `LabeledContent("Qwen3-ASR model", ...)` row:

```swift
                    Toggle(
                        "Auto post-process new recordings",
                        isOn: $autoPostProcessNewRecordings)
```

Replace that section footer text with:

```swift
                    Text("Once downloaded, Re-transcribe & summarize uses Qwen3-ASR automatically, and imports can select it. Auto post-process re-transcribes and identifies speakers before the first summary for new recordings, using downloaded models only. Live captions stay on the fast engines.")
```

- [ ] **Step 2: Add SessionDetailView storage and download action case**

In `SessionDetailView`, add this property beside `autoSuggest`:

```swift
    @AppStorage("summary.autoPostProcessNewRecordings")
    private var autoPostProcessNewRecordings = false
```

Update `DownloadAction`:

```swift
    private enum DownloadAction: Equatable {
        case summarize(SummaryStyle, SummaryLength, suggestVocabulary: Bool)
        case postProcessNewRecording(SummaryStyle, SummaryLength, suggestVocabulary: Bool)
        case retranscribe
        case suggestHotwords
    }
```

- [ ] **Step 3: Add the auto-summary request helper**

Add this method near `requestSummarize`:

```swift
    private func requestAutoSummarize(
        style: SummaryStyle,
        length: SummaryLength,
        suggestVocabulary: Bool
    ) {
        guard autoPostProcessNewRecordings else {
            requestSummarize(
                style: style,
                length: length,
                suggestVocabulary: suggestVocabulary)
            return
        }
        guard pipeline.llmEnabled else {
            showNotice(String(
                localized: "AI features are off — turn them on in Settings to summarize."))
            return
        }
        guard pipeline.llmDownloaded else {
            pendingDownload = .postProcessNewRecording(
                style, length, suggestVocabulary: suggestVocabulary)
            return
        }
        pipeline.jobs.postProcessAndSummarizeNewSession(
            sessionID: sessionID,
            style: style,
            length: length,
            suggestVocabulary: suggestVocabulary)
    }
```

- [ ] **Step 4: Use the helper only for post-stop auto-summary**

In the `.task` that checks `autoSummarizeStyle`, replace:

```swift
            requestSummarize(
                style: style,
                length: autoSummarizeLength ?? selectedLength,
                suggestVocabulary: autoSuggest)
```

with:

```swift
            requestAutoSummarize(
                style: style,
                length: autoSummarizeLength ?? selectedLength,
                suggestVocabulary: autoSuggest)
```

- [ ] **Step 5: Run the new action after LLM download consent**

In `runAfterDownloadConsent(_:)`, add this switch case after `.summarize`:

```swift
        case .postProcessNewRecording(let style, let length, let suggestVocabulary):
            pipeline.jobs.postProcessAndSummarizeNewSession(
                sessionID: sessionID,
                style: style,
                length: length,
                allowDownload: true,
                suggestVocabulary: suggestVocabulary)
```

- [ ] **Step 6: Compile the UI**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/NewRecordingPostProcessPlanTests
```

Expected: PASS and no compile errors in `SettingsView` or `SessionDetailView`.

- [ ] **Step 7: Commit**

```bash
git add Loqi/Features/Settings/SettingsView.swift Loqi/Features/Sessions/SessionDetailView.swift
git commit -m "Add auto post-process setting"
```

---

### Task 6: Update Progress UI For Retranscribe Speaker Identification

**Files:**
- Modify: `Loqi/Features/Sessions/SessionDetailView.swift`
- Modify: `Loqi/Features/Sessions/SessionsView.swift`

- [ ] **Step 1: Add detail-screen progress row support**

In `SessionDetailView.jobProgressRow`, add this switch case between retranscribing `.transcribing` and `.translating`:

```swift
        case .retranscribing(.identifyingSpeakers(let fraction)):
            PercentProgressRow(
                label: "Identifying speakers…", fraction: fraction,
                detail: remainingText)
```

- [ ] **Step 2: Add toolbar percent support**

In `SessionDetailView.wandLabel`, update the first case to include speaker identification:

```swift
        case .retranscribing(.transcribing(let fraction)),
             .retranscribing(.identifyingSpeakers(let fraction)),
             .downloadingModel(let fraction):
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
```

- [ ] **Step 3: Add sessions-list progress support**

In `SessionsView.info(for:)`, add this case between retranscribing `.transcribing` and `.translating`:

```swift
        case .retranscribing(.identifyingSpeakers(let f)):
            (String(localized: "Identifying speakers…"), f)
```

- [ ] **Step 4: Compile progress UI**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/NewRecordingPostProcessPlanTests
```

Expected: PASS and no non-exhaustive switch errors.

- [ ] **Step 5: Commit**

```bash
git add Loqi/Features/Sessions/SessionDetailView.swift Loqi/Features/Sessions/SessionsView.swift
git commit -m "Show new recording post-process progress"
```

---

### Task 7: Verify Full Behavior And Guard Manual Paths

**Files:**
- Test: `LoqiTests/NewRecordingPostProcessPlanTests.swift`
- Test: `LoqiTests/NewRecordingPostProcessorTests.swift`
- Test: `LoqiTests/SessionRecordTests.swift`

- [ ] **Step 1: Run focused tests**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/NewRecordingPostProcessPlanTests -only-testing:LoqiTests/NewRecordingPostProcessorTests -only-testing:LoqiTests/SessionRecordTests
```

Expected: PASS.

- [ ] **Step 2: Run the full unit suite**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: PASS for `LoqiTests`.

- [ ] **Step 3: Inspect manual path call sites**

Run:

```bash
rg -n "postProcessAndSummarizeNewSession|requestAutoSummarize|requestSummarize\\(|retranscribeAndSummarize" Loqi/Features/Sessions/SessionDetailView.swift Loqi/Pipeline/Summary/SummaryJobCenter.swift
```

Expected:

```text
SessionDetailView.swift: autoSummarize task calls requestAutoSummarize
SessionDetailView.swift: manual action menu still calls requestSummarize
SessionDetailView.swift: explicit re-transcribe still calls retranscribeAndSummarize
SummaryJobCenter.swift: postProcessAndSummarizeNewSession exists
SummaryJobCenter.swift: summarize and retranscribeAndSummarize still exist
```

- [ ] **Step 4: Device verification with Qwen3-ASR**

On a real device with Qwen3-ASR and the offline diarizer downloaded:

1. Enable Settings -> High-accuracy re-transcription -> Auto post-process new recordings.
2. Set speaker separation to Auto or 2+ speakers.
3. Record a short two-speaker mixed-language session.
4. Stop recording.
5. Confirm progress shows re-transcribing, identifying speakers, then summarizing.
6. Confirm the transcript is replaced with post-processed text, speaker labels are assigned, and the summary appears.

- [ ] **Step 5: Device verification with SenseVoice fallback**

On a real device with SenseVoice downloaded and Qwen3-ASR not downloaded:

1. Enable the same toggle.
2. Record and stop a short session.
3. Confirm no Qwen3-ASR download prompt appears.
4. Confirm the post-ASR phase completes and the summary appears.

- [ ] **Step 6: Device verification with no post-ASR model**

On a real device with neither Qwen3-ASR nor SenseVoice downloaded:

1. Enable the same toggle.
2. Record and stop a short session.
3. Confirm no ASR download prompt appears.
4. Confirm the app summarizes the live transcript.

- [ ] **Step 7: Device verification with missing offline diarizer**

On a real device without the offline diarizer downloaded:

1. Enable the same toggle.
2. Record with speaker separation enabled.
3. Stop recording.
4. Confirm no diarizer download prompt appears.
5. Confirm the session still summarizes.

- [ ] **Step 8: Commit final verification notes if code changed during fixes**

If verification required code fixes, commit them:

```bash
git add Loqi LoqiTests
git commit -m "Stabilize auto post-process new recordings"
```

Expected: no commit is needed when all previous tasks passed without changes.
