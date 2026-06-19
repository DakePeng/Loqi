# Map Summary Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four actionable review issues on `codex/map-only-summary` without widening the feature.

**Architecture:** Keep fixes local to existing files. Restore the no-download default for speaker separation, make background resume wait for canceled retranscribe teardown, key action dedup on rendered action text, and keep summary progress bounded.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, existing Loqi pipeline classes.

---

## File Map

- Modify `Loqi/Features/Captions/LiveCaptionsView.swift`: default speaker picker back to off.
- Modify `Loqi/Support/CaptionPipeline.swift`: missing speaker preference resolves to off.
- Modify `Loqi/Pipeline/Summary/SummaryJobCenter.swift`: store background-canceled retranscribe tasks and await teardown before draining.
- Modify `Loqi/Pipeline/Summary/SummaryEngine.swift`: dedup actions by rendered action text and include reduce in progress total.
- Modify `LoqiTests/SummaryEngineTests.swift`: add coverage for same-task actions with different owners.

## Prerequisite

The local machine currently points `xcodebuild` at CommandLineTools. Before running the simulator tests:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -list -project Loqi.xcodeproj
```

Expected: the `Loqi` scheme is listed.

---

### Task 1: Stop Silent Speaker Model Downloads

**Files:**
- Modify: `Loqi/Features/Captions/LiveCaptionsView.swift:31-33`
- Modify: `Loqi/Support/CaptionPipeline.swift:218-223`

- [ ] **Step 1: Change the view default back to off**

In `LiveCaptionsView`, replace the speaker count storage with:

```swift
// 0/1 = single speaker (no diarization), -1 = Auto, 2+ = hard cap.
// Default off so first recording never downloads the speaker model silently.
@AppStorage("captions.speakerCount") private var speakerCount = 0
```

- [ ] **Step 2: Change the pipeline fallback to match**

In `CaptionPipeline.captionSpeakerCount`, replace the fallback with:

```swift
/// Captions-mode speaker picker value; 0/1 = diarization off, -1 =
/// Auto, 2+ = hard cap (see VoiceprintService.clusterCap). Unset defaults
/// to off so recording never downloads the speaker model silently.
var captionSpeakerCount: Int {
    (UserDefaults.standard.object(forKey: "captions.speakerCount") as? Int) ?? 0
}
```

- [ ] **Step 3: Run the smallest relevant tests**

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/LLMServiceTests
```

Expected: PASS.

---

### Task 2: Await Background-Canceled Retranscribe Teardown

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryJobCenter.swift:80-245`

- [ ] **Step 1: Add storage for canceled retranscribe tasks**

Near `suspendedSummaries`, add:

```swift
/// Retranscribe tasks canceled by backgrounding. Foreground resume waits for
/// their `finishJob` before reusing the same activity/task slots.
@ObservationIgnored private var backgroundPausedRetranscribeTasks: [UUID: Task<Void, Never>] = [:]
```

- [ ] **Step 2: Clear the stored task on explicit cancel**

In `cancel(_:)`, after clearing `suspendedSummaries`, add:

```swift
backgroundPausedRetranscribeTasks[sessionID] = nil
```

- [ ] **Step 3: Store the old task when suspending retranscribe**

In `suspendBackgroundUnsafeJobs()`, inside the `.retranscribing` branch before setting `.pausedForBackground`, add:

```swift
backgroundPausedRetranscribeTasks[sessionID] = tasks[sessionID]
```

Keep the existing queue insert and cancellation.

- [ ] **Step 4: Replace the immediate resume loop**

Replace `resumeBackgroundJobs()` with:

```swift
private func resumeBackgroundJobs() {
    resumeLLMJobs()
    let pausedRetranscribes = activities.compactMap { sessionID, activity -> UUID? in
        guard activity == .pausedForBackground,
              retranscribeQueue.contains(where: { $0.sessionID == sessionID })
        else { return nil }
        return sessionID
    }

    for sessionID in pausedRetranscribes {
        let oldTask = backgroundPausedRetranscribeTasks.removeValue(forKey: sessionID)
        Task { [weak self] in
            await oldTask?.value
            guard let self,
                  !self.isBackgrounded,
                  self.activities[sessionID] == .pausedForBackground,
                  self.retranscribeQueue.contains(where: { $0.sessionID == sessionID })
            else { return }
            self.activities[sessionID] = .queuedRetranscribe
            self.drainRetranscribeQueue()
        }
    }
}
```

- [ ] **Step 5: Run queue-adjacent tests**

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/LLMServiceTests
```

Expected: PASS.

---

### Task 3: Dedup Actions With Owner And Deadline

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryEngine.swift:514-523`
- Modify: `Loqi/Pipeline/Summary/SummaryEngine.swift:668-684`
- Modify: `LoqiTests/SummaryEngineTests.swift`

- [ ] **Step 1: Add a failing reducer test**

Add this test to `SummaryEngineTests` near the existing `SummaryRecordReducer.render` tests:

```swift
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
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/SummaryEngineTests/renderKeepsSameTaskActionsForDifferentOwners
```

Expected: FAIL because one action is deduped away.

- [ ] **Step 3: Add one helper for dedup text**

In `SummaryRecordReducer`, near `displayText`, add:

```swift
private static func dedupText(_ record: Record) -> String {
    record.kind == .action ? actionText(record) : record.text
}
```

- [ ] **Step 4: Use the helper in both dedup passes**

In `displayUnused(_:)`, change:

```swift
let key = SummaryEngine.dedupKey(record.text)
```

to:

```swift
let key = SummaryEngine.dedupKey(dedupText(record))
```

In `deduped(_:)`, change:

```swift
let base = SummaryEngine.dedupKey(record.text)
```

to:

```swift
let base = SummaryEngine.dedupKey(dedupText(record))
```

- [ ] **Step 5: Run the reducer test**

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/SummaryEngineTests/renderKeepsSameTaskActionsForDifferentOwners
```

Expected: PASS.

---

### Task 4: Keep Summary Progress Bounded

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryEngine.swift:410-430`

- [ ] **Step 1: Include reduce in the total**

In `SummaryEngine.summarize`, replace:

```swift
// Detailed Notes assembly is deterministic after the reduce, so
// progress only tracks real async map work.
let mapChunks = Self.chunkEntries(uncovered).count
let totalSteps = mapChunks
```

with:

```swift
let mapChunks = Self.chunkEntries(uncovered).count
let totalSteps = mapChunks + 1
```

This keeps the existing `reduce` progress tick and prevents `done > total`.

- [ ] **Step 2: Run summary tests**

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/SummaryEngineTests
```

Expected: PASS.

---

### Task 5: Final Verification

**Files:**
- No edits.

- [ ] **Step 1: Check whitespace**

```bash
git diff --check
```

Expected: no output.

- [ ] **Step 2: Run focused test set**

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/SummaryEngineTests -only-testing:LoqiTests/LLMServiceTests
```

Expected: PASS.

- [ ] **Step 3: Review the final diff**

```bash
git diff -- Loqi/Features/Captions/LiveCaptionsView.swift Loqi/Support/CaptionPipeline.swift Loqi/Pipeline/Summary/SummaryJobCenter.swift Loqi/Pipeline/Summary/SummaryEngine.swift LoqiTests/SummaryEngineTests.swift
```

Expected: only the four reviewed fixes plus the one reducer test.
