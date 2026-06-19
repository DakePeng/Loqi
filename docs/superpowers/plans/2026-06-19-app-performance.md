# App Performance: Launch, Journal & Live Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove three main-actor performance drains found in review — a cold-launch stall that decodes the whole session history synchronously, O(n²) per-utterance journal mapping during recording, and live-transcript regrouping on every render/scroll.

**Architecture:** Three independent changes. (A) Cache live-caption segment grouping in `CaptionStore`, invalidated only when entries change, so scroll/UI churn no longer regroups. (B) Move journal record-building + JSON encode entirely onto the `JournalWriter` actor by passing it raw `Sendable` entries instead of a pre-built record. (C) Make `SessionArchive` decode sessions off the main actor, sequencing crash-recovery and orphan-sweep to run only after the load completes (the sweep would delete every recording if it ran against empty `sessions`).

**Tech Stack:** Swift 6 concurrency (actors, `@MainActor`, `@Observable`, `Sendable`), SwiftUI + Observation, Swift Testing (`import Testing`, `@Test`, `#expect`), XcodeGen.

## Global Constraints

- **Test framework:** Swift Testing only (`import Testing` + `@testable import Loqi`). Mirror existing suites like `LoqiTests/CaptionStoreTests.swift`, `LoqiTests/ModelCatalogTests.swift`.
- **Test/build command:** Runtime test verification requires a real iPhone; do not use simulator tests/runs as a substitute. Run targeted Swift tests from Xcode on a real device. For compile-only CLI checks, use `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1 CODE_SIGNING_ALLOWED=NO`.
- **`@MainActor` tests:** suites that touch `CaptionStore`/`SessionArchive` must be annotated `@MainActor` (those types are main-actor isolated). See the Swift Testing `@MainActor struct` form in Task 2.
- **Sendable already holds:** `CaptionEntry`, `CaptionEntry.State`, `SessionMode` are `Sendable, Equatable` ([CaptionEntry.swift:15](Loqi/Models/CaptionEntry.swift:15)); `AudioTimeline`, `SessionRecord.ChunkNote`, `SessionRecord.Attachment` are `Sendable` (they live in `SessionArtifacts: Sendable`, [SessionArchive.swift:8](Loqi/Support/SessionArchive.swift:8)). `SessionArchive.mappedEntries` is already `nonisolated static` ([SessionArchive.swift:63](Loqi/Support/SessionArchive.swift:63)) — callable off-main.
- **Behavior must not change** — these are pure performance refactors. The crash-journal snapshot, archived records, and on-screen grouping must be byte-for-byte identical to today.
- **Single session mode:** all live sessions are `.captions` ([CaptionPipeline.swift:244](Loqi/Support/CaptionPipeline.swift:244)); grouping/mapping may assume one mode but must not delete the `SessionMode` field.
- **Commit cadence:** one commit per task (TDD: test → impl → pass → commit). Conventional Commits.

---

## File Structure

**New files:**
- `Loqi/Models/CaptionSegment.swift` — the segment value type + pure grouping function (moved out of the view so it's testable and cacheable).
- `LoqiTests/CaptionGroupingTests.swift`, `LoqiTests/SessionArchiveLoadTests.swift`, `LoqiTests/JournalSnapshotTests.swift` — Swift Testing suites.

**Modified files:**
- `Loqi/Support/CaptionStore.swift` — cache segments, invalidate on `entries` change.
- `Loqi/Features/Captions/LiveCaptionsView.swift` — consume `store.segments()`; delete the view-private `Segment`/grouping.
- `Loqi/Support/SessionJournal.swift` — `JournalSnapshotInputs` + `JournalWriter.write(building:)` + pure `buildJournalRecord`.
- `Loqi/Support/CaptionPipeline.swift` — `writeJournal` passes raw inputs; async archive load sequencing.
- `Loqi/Support/SessionArchive.swift` — `decodeAll(in:)` off-main, `loadIfNeeded()`, `didLoad` sweep guard.

---

## Phase A — Live transcript: cache segment grouping

> Today [LiveCaptionsView.transcript](Loqi/Features/Captions/LiveCaptionsView.swift:292) rebuilds the full segment grouping (`segments(from:)`, O(n)) on **every body evaluation** — including the body re-runs fired continuously by `onScrollPhaseChange`/`onScrollGeometryChange` while scrolling, and by unrelated `@State` toggles. Caching in the store rebuilds only when `entries` actually change.

### Task 1: Extract `CaptionSegment` + pure `CaptionGrouping`

**Files:**
- Create: `Loqi/Models/CaptionSegment.swift`
- Test: `LoqiTests/CaptionGroupingTests.swift`

**Interfaces:**
- Produces: `struct CaptionSegment: Identifiable, Equatable { let id: UUID; let speaker: Int?; var entries: [CaptionEntry] }`; `enum CaptionGrouping` with `static let defaultGap: TimeInterval`, `static let defaultMaxEntries: Int`, and `static func segments(from: [CaptionEntry], gap: TimeInterval, maxEntries: Int) -> [CaptionSegment]`.

> The grouping body is moved verbatim from `LiveCaptionsView.segments(from:)` ([:239-255](Loqi/Features/Captions/LiveCaptionsView.swift:239)); constants from [:64-66](Loqi/Features/Captions/LiveCaptionsView.swift:64).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Loqi

struct CaptionGroupingTests {
    private func entry(
        _ text: String, speaker: Int? = nil, at offset: TimeInterval
    ) -> CaptionEntry {
        var e = CaptionEntry(
            sourceText: text,
            direction: LanguagePair(source: .english, target: .english),
            state: .finalized,
            createdAt: Date(timeIntervalSince1970: offset))
        e.speaker = speaker
        return e
    }

    @Test func consecutiveSameSpeakerWithinGapGroup() {
        let segs = CaptionGrouping.segments(
            from: [entry("a", speaker: 0, at: 0), entry("b", speaker: 0, at: 1)],
            gap: 12, maxEntries: 4)
        #expect(segs.count == 1)
        #expect(segs[0].entries.count == 2)
        #expect(segs[0].id == segs[0].entries[0].id)   // id is the first entry's
    }

    @Test func speakerChangeSplits() {
        let segs = CaptionGrouping.segments(
            from: [entry("a", speaker: 0, at: 0), entry("b", speaker: 1, at: 1)],
            gap: 12, maxEntries: 4)
        #expect(segs.count == 2)
    }

    @Test func longPauseSplitsSameSpeaker() {
        let segs = CaptionGrouping.segments(
            from: [entry("a", speaker: 0, at: 0), entry("b", speaker: 0, at: 100)],
            gap: 12, maxEntries: 4)
        #expect(segs.count == 2)
    }

    @Test func capForcesNewSegment() {
        let entries = (0..<5).map { entry("x", speaker: 0, at: Double($0)) }
        let segs = CaptionGrouping.segments(from: entries, gap: 12, maxEntries: 4)
        #expect(segs[0].entries.count == 4)
        #expect(segs[1].entries.count == 1)
    }

    @Test func nilSpeakerJoinsRunningSegment() {
        // entry.speaker == nil joins the previous card (matches view behavior).
        let segs = CaptionGrouping.segments(
            from: [entry("a", speaker: 0, at: 0), entry("b", speaker: nil, at: 1)],
            gap: 12, maxEntries: 4)
        #expect(segs.count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the `LoqiTests/CaptionGroupingTests` selection from Xcode on a real iPhone; do not use a simulator.
Expected: FAIL — "cannot find 'CaptionGrouping' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One card per coherent stretch of speech: same speaker, no long pause
/// between utterances, and bounded length. An approximation of semantic
/// segments that needs no extra ML. Extracted from LiveCaptionsView so the
/// store can cache it and tests can exercise it.
struct CaptionSegment: Identifiable, Equatable {
    let id: UUID            // first entry's id — stable
    let speaker: Int?
    var entries: [CaptionEntry]
}

enum CaptionGrouping {
    /// A pause this long starts a new card even for the same speaker.
    static let defaultGap: TimeInterval = 12
    /// Cards stay "little": cap utterances per card.
    static let defaultMaxEntries = 4

    static func segments(
        from entries: [CaptionEntry],
        gap: TimeInterval = defaultGap,
        maxEntries: Int = defaultMaxEntries
    ) -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        for entry in entries {
            if var last = segments.last,
               entry.speaker == nil || entry.speaker == last.speaker,
               last.entries.count < maxEntries,
               let previous = last.entries.last,
               entry.createdAt.timeIntervalSince(previous.createdAt) < gap {
                last.entries.append(entry)
                segments[segments.count - 1] = last
            } else {
                segments.append(CaptionSegment(
                    id: entry.id, speaker: entry.speaker, entries: [entry]))
            }
        }
        return segments
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the `LoqiTests/CaptionGroupingTests` selection from Xcode on a real iPhone; do not use a simulator.
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Models/CaptionSegment.swift LoqiTests/CaptionGroupingTests.swift
git commit -m "feat: extract CaptionSegment + pure CaptionGrouping"
```

---

### Task 2: Cache segments in CaptionStore

**Files:**
- Modify: `Loqi/Support/CaptionStore.swift:14` (entries declaration), add `segments()` + cache.
- Test: `LoqiTests/CaptionStoreTests.swift` (extend existing suite).

**Interfaces:**
- Consumes: `CaptionGrouping.segments`, `CaptionSegment`.
- Produces: `CaptionStore.segments() -> [CaptionSegment]`.

> Invalidate on any `entries` mutation via `didSet` (each in-place edit `entries[i].x = …` mutates the array, firing it). `@Observable` preserves stored-property observers, so this is safe; the cache is `@ObservationIgnored` (derived infra, like `onEvict`).

- [ ] **Step 1: Write the failing test**

Add to `LoqiTests/CaptionStoreTests.swift` (annotate the suite `@MainActor` if it isn't already):

```swift
    @MainActor
    @Test func segmentsGroupAndRecomputeAfterMutation() {
        let store = CaptionStore()
        let dir = LanguagePair(source: .english, target: .english)
        store.finalizeActive(text: "first", direction: dir)
        let firstCount = store.segments().count
        #expect(firstCount == 1)

        // A new finalized utterance changes the grouping result.
        store.finalizeActive(text: "second", direction: dir)
        #expect(store.segments().reduce(0) { $0 + $1.entries.count } == 2)
    }

    @MainActor
    @Test func segmentsCacheReturnsEqualResultWithoutMutation() {
        let store = CaptionStore()
        let dir = LanguagePair(source: .english, target: .english)
        store.finalizeActive(text: "hello", direction: dir)
        #expect(store.segments() == store.segments())   // stable across calls
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the `LoqiTests/CaptionStoreTests` selection from Xcode on a real iPhone; do not use a simulator.
Expected: FAIL — "value of type 'CaptionStore' has no member 'segments'".

- [ ] **Step 3: Write minimal implementation**

In `CaptionStore.swift`, change the `entries` declaration ([:14](Loqi/Support/CaptionStore.swift:14)) to invalidate the cache:

```swift
    private(set) var entries: [CaptionEntry] = [] {
        didSet { cachedSegments = nil }
    }

    /// Cached segment grouping, rebuilt lazily on first read after any
    /// entries mutation. Derived infra, not observed state — the view's
    /// dependency on `entries` is established by its own `entries(in:)` read.
    @ObservationIgnored private var cachedSegments: [CaptionSegment]?
```

Add the accessor near `entries(in:)` ([:35](Loqi/Support/CaptionStore.swift:35)):

```swift
    /// Speaker/pause-grouped cards for the live transcript. Cached so scroll
    /// and unrelated UI re-renders don't regroup; invalidated by `entries`.
    func segments() -> [CaptionSegment] {
        if let cachedSegments { return cachedSegments }
        let built = CaptionGrouping.segments(from: entries)
        cachedSegments = built
        return built
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the `LoqiTests/CaptionStoreTests` selection from Xcode on a real iPhone; do not use a simulator.
Expected: PASS (existing + 2 new).

> If the compiler rejects `didSet` on the `@Observable` stored property, fall back to invalidating in `prune()` and at the end of each mutator (`applyVolatile`, `finalizeActive`, `finalizeActiveSplit`, `discardActiveIfEmpty`, `finalizeActiveAsIs`, `setDraft`, `markDraftFailed`, `setSpeaker`, `markRefining`, `setRefined`, `clear`) with `cachedSegments = nil`. The `didSet` form is preferred (one line); only switch if it doesn't compile.

- [ ] **Step 5: Commit**

```bash
git add Loqi/Support/CaptionStore.swift LoqiTests/CaptionStoreTests.swift
git commit -m "perf: cache live caption segment grouping in CaptionStore"
```

---

### Task 3: LiveCaptionsView consumes the cached segments

**Files:**
- Modify: `Loqi/Features/Captions/LiveCaptionsView.swift` — delete the view-private `Segment`/`segmentGap`/`segmentMaxEntries`/`segments(from:)`; route `rows`/`segmentCard`/`LiveRow` through `CaptionSegment` and `store.segments()`.

**Interfaces:**
- Consumes: `CaptionStore.segments()`, `CaptionSegment`.

- [ ] **Step 1: Remove the view-private grouping**

Delete these from `LiveCaptionsView`:
- the `private struct Segment { … }` ([:57-61](Loqi/Features/Captions/LiveCaptionsView.swift:57)),
- `private static let segmentGap` / `segmentMaxEntries` ([:64-66](Loqi/Features/Captions/LiveCaptionsView.swift:64)),
- the whole `private func segments(from:)` ([:239-255](Loqi/Features/Captions/LiveCaptionsView.swift:239)).

- [ ] **Step 2: Point `LiveRow`/`rows` at `CaptionSegment` and the cache**

Change `LiveRow` to carry `CaptionSegment` ([:259-269](Loqi/Features/Captions/LiveCaptionsView.swift:259)):

```swift
    private enum LiveRow: Identifiable {
        case segment(CaptionSegment)
        case photo(SessionRecord.Attachment)

        var id: UUID {
            switch self {
            case .segment(let segment): segment.id
            case .photo(let attachment): attachment.id
            }
        }
    }
```

Replace `rows(from entries:)` ([:271-287](Loqi/Features/Captions/LiveCaptionsView.swift:271)) so it takes the cached segments instead of recomputing:

```swift
    private func rows(segments: [CaptionSegment]) -> [LiveRow] {
        let attachments = pipeline.liveAttachments
        guard !attachments.isEmpty else { return segments.map(LiveRow.segment) }
        var rows: [LiveRow] = []
        var remaining = attachments[...]
        for segment in segments {
            let start = segment.entries.first?.createdAt ?? .distantPast
            while let next = remaining.first, next.timestamp < start {
                rows.append(.photo(next))
                remaining.removeFirst()
            }
            rows.append(.segment(segment))
        }
        rows.append(contentsOf: remaining.map(LiveRow.photo))
        return rows
    }
```

In `transcript(_ entries:)` ([:293](Loqi/Features/Captions/LiveCaptionsView.swift:293)), source the segments from the store:

```swift
        let liveRows = rows(segments: pipeline.store.segments())
```

Change `segmentCard(_ segment: Segment, …)` ([:734](Loqi/Features/Captions/LiveCaptionsView.swift:734)) signature to `segmentCard(_ segment: CaptionSegment, …)`. (Its body uses only `segment.speaker` / `segment.entries`, which are identical on `CaptionSegment`.)

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1 CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. (Resolve any remaining `Segment` references the compiler flags to `CaptionSegment`. `HorizontalCaptionView` takes raw `entries` and does its own layout — leave it; out of scope.)

- [ ] **Step 4: Manual verify**

Manual (device or sim with audio): record several sentences across pauses/speakers; confirm cards group exactly as before, photos interleave at the right spots, and scrolling stays smooth (the regroup-on-scroll is gone).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Features/Captions/LiveCaptionsView.swift
git commit -m "perf: render live transcript from cached store segments"
```

---

## Phase B — Journal: build + encode off the main actor

> [writeJournal](Loqi/Support/CaptionPipeline.swift:664) fires every utterance and, on the main actor, builds `archivableEntries` and maps **every** entry (`SessionArchive.mappedEntries`) before handing a finished record to the writer. Because `evictedEntries` grows all session, that's O(n)/utterance → O(n²). Move the mapping + assembly onto the `JournalWriter` actor; the main actor only hands over `Sendable` raw arrays (cheap COW references).

### Task 4: `JournalSnapshotInputs` + pure `buildJournalRecord`

**Files:**
- Modify: `Loqi/Support/SessionJournal.swift` — add the inputs struct + builder + a `write(building:)` actor method.
- Test: `LoqiTests/JournalSnapshotTests.swift`

**Interfaces:**
- Produces: `struct JournalSnapshotInputs: Sendable { … }`; `static func JournalWriter.buildJournalRecord(from: JournalSnapshotInputs) -> SessionRecord`; `func JournalWriter.write(building: JournalSnapshotInputs)`.
- Consumes: `SessionArchive.mappedEntries` (nonisolated static), `SessionRecord`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Loqi

struct JournalSnapshotTests {
    private func finalized(_ text: String, at offset: TimeInterval) -> CaptionEntry {
        CaptionEntry(
            sourceText: text,
            direction: LanguagePair(source: .english, target: .english),
            state: .finalized,
            createdAt: Date(timeIntervalSince1970: offset))
    }

    @Test func buildsRecordWithMappedEntries() {
        let started = Date(timeIntervalSince1970: 0)
        let inputs = JournalSnapshotInputs(
            sessionID: UUID(),
            mode: .captions,
            startedAt: started,
            evicted: [finalized("old", at: 1)],
            live: [finalized("new", at: 2)],
            timeline: nil,
            speakerNames: [:],
            recordingSpeakerCount: 0,
            audioFileName: "rec.caf",
            chunkNotes: [],
            notesEndEntryID: nil,
            attachments: [])

        let record = JournalWriter.buildJournalRecord(from: inputs)
        #expect(record.entries.map(\.sourceText) == ["old", "new"])   // evicted then live, in order
        #expect(record.audioFileName == "rec.caf")
        #expect(record.startedAt == started)
    }

    @Test func dropsVolatileAndPreSessionEntries() {
        let started = Date(timeIntervalSince1970: 10)
        var volatile = finalized("typing", at: 11)
        volatile.state = .volatile
        let inputs = JournalSnapshotInputs(
            sessionID: UUID(), mode: .captions, startedAt: started,
            evicted: [], live: [finalized("before", at: 5), volatile, finalized("kept", at: 12)],
            timeline: nil, speakerNames: [:], recordingSpeakerCount: 0,
            audioFileName: nil, chunkNotes: [], notesEndEntryID: nil, attachments: [])

        let record = JournalWriter.buildJournalRecord(from: inputs)
        #expect(record.entries.map(\.sourceText) == ["kept"])   // volatile + pre-start dropped
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the `LoqiTests/JournalSnapshotTests` selection from Xcode on a real iPhone; do not use a simulator.
Expected: FAIL — "cannot find 'JournalSnapshotInputs' in scope".

- [ ] **Step 3: Write minimal implementation**

In `SessionJournal.swift`, add the inputs struct (top level):

```swift
/// Everything `writeJournal` needs to assemble a crash snapshot, as cheap-to-
/// pass Sendable values. The mapping (mappedEntries, O(n)) and JSON encode run
/// on the JournalWriter actor, never the main actor.
struct JournalSnapshotInputs: Sendable {
    let sessionID: UUID
    let mode: SessionMode
    let startedAt: Date
    let evicted: [CaptionEntry]
    let live: [CaptionEntry]
    let timeline: AudioTimeline?
    let speakerNames: [Int: String]
    let recordingSpeakerCount: Int
    let audioFileName: String?
    let chunkNotes: [SessionRecord.ChunkNote]
    let notesEndEntryID: UUID?
    let attachments: [SessionRecord.Attachment]
}
```

Add to `JournalWriter` a pure builder + the new entry point (mirrors the old `writeJournal` body exactly, minus the mode filter, which is a no-op with a single mode — all entries are `.captions`):

```swift
    /// Assemble the snapshot record. Pure + static so it's testable and runs
    /// off the main actor inside `write(building:)`.
    static func buildJournalRecord(from inputs: JournalSnapshotInputs) -> SessionRecord {
        var record = SessionRecord(
            id: inputs.sessionID,
            mode: inputs.mode,
            startedAt: inputs.startedAt,
            endedAt: .now,
            entries: SessionArchive.mappedEntries(
                from: inputs.evicted + inputs.live,
                startedAt: inputs.startedAt,
                timeline: inputs.timeline),
            speakerNames: inputs.speakerNames)
        record.recordingSpeakerCount = inputs.recordingSpeakerCount
        if inputs.audioFileName != nil { record.audioFileName = inputs.audioFileName }
        if !inputs.chunkNotes.isEmpty {
            record.chunkNotes = inputs.chunkNotes
            record.liveNotesEndEntryID = inputs.notesEndEntryID
        }
        if !inputs.attachments.isEmpty { record.attachments = inputs.attachments }
        return record
    }

    /// Build the record off-main, then queue it like any snapshot.
    func write(building inputs: JournalSnapshotInputs) {
        pending = Self.buildJournalRecord(from: inputs)
        startDraining()
    }
```

> Verify against the original `writeJournal` ([CaptionPipeline.swift:664-687](Loqi/Support/CaptionPipeline.swift:664)): the original sets `audioFileName` only when `recorder != nil`. That gate moves to the call site in Task 5 (it sets `audioFileName` in the inputs only when a recorder exists), so `buildJournalRecord` assigns it whenever present — equivalent.

- [ ] **Step 4: Run test to verify it passes**

Run the `LoqiTests/JournalSnapshotTests` selection from Xcode on a real iPhone; do not use a simulator.
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Support/SessionJournal.swift LoqiTests/JournalSnapshotTests.swift
git commit -m "perf: build crash-journal record on the writer actor"
```

---

### Task 5: `writeJournal` hands over raw inputs

**Files:**
- Modify: `Loqi/Support/CaptionPipeline.swift:664-687` (`writeJournal`).

**Interfaces:**
- Consumes: `JournalSnapshotInputs`, `JournalWriter.write(building:)`, `CaptionStore.entries`.

- [ ] **Step 1: Replace the body**

Replace `writeJournal` ([:664-687](Loqi/Support/CaptionPipeline.swift:664)) with:

```swift
    private func writeJournal() {
        guard let sessionID, let startedAt = sessionStartedAt else { return }
        // Cheap on the main actor: COW array references + small values. The
        // O(n) mapping and JSON encode happen on the JournalWriter actor.
        let inputs = JournalSnapshotInputs(
            sessionID: sessionID,
            mode: sessionMode,
            startedAt: startedAt,
            evicted: evictedEntries,
            live: store.entries,
            timeline: audioAnchors.isEmpty ? nil : AudioTimeline(anchors: audioAnchors),
            speakerNames: speakerNames,
            recordingSpeakerCount: captionSpeakerCount,
            audioFileName: recorder != nil ? SessionRecorder.fileName(for: sessionID) : nil,
            chunkNotes: liveNotes,
            notesEndEntryID: notesEndEntryID,
            attachments: liveAttachments)
        Task { await journalWriter.write(building: inputs) }
    }
```

> `store.entries` is `private(set)` and main-actor readable; it includes the active volatile entry, which `mappedEntries` drops by `state`. With a single mode this matches the old `archivableEntries` (`evicted + store.entries(in:)`) exactly.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1 CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Confirm journal tests pass**

Run the `LoqiTests/SessionJournalTests` selection from Xcode on a real iPhone; do not use a simulator.
Expected: PASS.

- [ ] **Step 4: Manual verify crash recovery still works**

Manual (device): start recording, speak a few lines, force-quit the app, relaunch. Expected: the interrupted session is recovered identically to before (post-stop "interrupted" framing, transcript + audio intact).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Support/CaptionPipeline.swift
git commit -m "perf: pass raw inputs to the journal writer, mapping off-main"
```

---

## Phase C — Archive: decode the session history off the main actor

> ⚠️ **Data-loss hazard:** `sweepOrphans` deletes any recording/attachment file not referenced by `sessions` ([SessionArchive.swift:218-240](Loqi/Support/SessionArchive.swift:218)). If load becomes async and the sweep runs against an *empty* `sessions`, it deletes **every** recording. The sweep (and crash recovery) must run only after the load completes. This phase sequences that explicitly and adds a `didLoad` guard as a backstop.

### Task 6: Off-main decode (`decodeAll(in:)`) + guarded `loadIfNeeded()`

**Files:**
- Modify: `Loqi/Support/SessionArchive.swift` — split `load()` into a `nonisolated static` decode + an async `loadIfNeeded()`; add `didLoad`; guard `sweepOrphans`.
- Test: `LoqiTests/SessionArchiveLoadTests.swift`

**Interfaces:**
- Produces: `nonisolated static func SessionArchive.decodeAll(in: URL) -> [SessionRecord]`; `func SessionArchive.loadIfNeeded() async`; `SessionArchive.didLoad` semantics (sweep no-ops until loaded).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Loqi

struct SessionArchiveLoadTests {
    private func writeRecord(_ record: SessionRecord, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: dir.appending(path: "\(record.id.uuidString).json"))
    }

    private func record(at offset: TimeInterval, importing: Bool = false) -> SessionRecord {
        var r = SessionRecord(
            mode: .captions,
            startedAt: Date(timeIntervalSince1970: offset),
            endedAt: Date(timeIntervalSince1970: offset + 1),
            entries: [])
        if importing { r.importing = true }
        return r
    }

    @Test func decodesSortsDescendingAndDropsImporting() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRecord(record(at: 100), to: dir)
        try writeRecord(record(at: 300), to: dir)
        try writeRecord(record(at: 200, importing: true), to: dir)

        let decoded = SessionArchive.decodeAll(in: dir)
        let kept = decoded.filter { $0.importing != true }
            .sorted { $0.startedAt > $1.startedAt }
        #expect(decoded.count == 3)                       // raw decode keeps all
        #expect(kept.map(\.startedAt) == [
            Date(timeIntervalSince1970: 300), Date(timeIntervalSince1970: 100)])
    }

    @Test func missingDirectoryDecodesEmpty() {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(SessionArchive.decodeAll(in: dir).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the `LoqiTests/SessionArchiveLoadTests` selection from Xcode on a real iPhone; do not use a simulator.
Expected: FAIL — "type 'SessionArchive' has no member 'decodeAll'".

- [ ] **Step 3: Write minimal implementation**

In `SessionArchive.swift`, remove the `load()` call from `init` ([:46-48](Loqi/Support/SessionArchive.swift:46)):

```swift
    init() {}   // load() is async now; the pipeline drives loadIfNeeded()
```

Add the `didLoad` flag near `sessions` ([:23](Loqi/Support/SessionArchive.swift:23)):

```swift
    private(set) var sessions: [SessionRecord] = []
    /// True once disk decode has populated `sessions`. The orphan sweep
    /// refuses to run before this — sweeping empty `sessions` would delete
    /// every recording on disk.
    private var didLoad = false
```

Replace the private `load()` ([:244-262](Loqi/Support/SessionArchive.swift:244)) with a `nonisolated static` decode + an async loader:

```swift
    /// Decode every session JSON in `directory` (importing tombstones
    /// included — the caller decides). Pure I/O + decode, runs off the main
    /// actor. Missing directory → empty.
    nonisolated static func decodeAll(in directory: URL) -> [SessionRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
    }

    /// Populate `sessions` from disk, decoding off the main actor. Idempotent.
    /// Tombstones (records still marked importing) are swept here.
    func loadIfNeeded() async {
        guard !didLoad else { return }
        let directory = Self.directory
        let decoded = await Task.detached { Self.decodeAll(in: directory) }.value
        let fm = FileManager.default
        for abandoned in decoded where abandoned.importing == true {
            try? fm.removeItem(
                at: directory.appending(path: "\(abandoned.id.uuidString).json"))
        }
        sessions = decoded
            .filter { $0.importing != true }
            .sorted { $0.startedAt > $1.startedAt }
        didLoad = true
    }
```

Guard the sweep ([:54-57](Loqi/Support/SessionArchive.swift:54)):

```swift
    func sweepOrphans() {
        guard didLoad else { return }   // never sweep against an unloaded (empty) list
        sweepOrphanedRecordings()
        sweepOrphanedAttachments()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the `LoqiTests/SessionArchiveLoadTests` selection from Xcode on a real iPhone; do not use a simulator.
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Support/SessionArchive.swift LoqiTests/SessionArchiveLoadTests.swift
git commit -m "perf: decode session history off the main actor"
```

---

### Task 7: Sequence load → recover → sweep at launch

**Files:**
- Modify: `Loqi/Support/CaptionPipeline.swift:291-317` (the init block that runs recovery + sweep).

**Interfaces:**
- Consumes: `SessionArchive.loadIfNeeded()`, `recoverInterruptedSession()`, `SessionArchive.sweepOrphans()`.

> Order is mandatory: load (so `sessions` reflects disk) → recover (dedupes against `sessions`, claims the interrupted session's audio) → sweep (deletes truly-orphaned files). The comment at [:291-293](Loqi/Support/CaptionPipeline.swift:291) already requires recover-before-sweep; this keeps that and adds load-before-both.

- [ ] **Step 1: Replace the synchronous recover/sweep with a sequenced Task**

Replace ([:291-295](Loqi/Support/CaptionPipeline.swift:291)):

```swift
        // A journal on disk means the last process died mid-recording —
        // recover BEFORE the orphan sweep, which would otherwise delete
        // the very audio recovery exists to save.
        recoverInterruptedSession()
        archive.sweepOrphans()
```

with:

```swift
        // History decode is off-main now, so recovery + orphan sweep must
        // wait for it: sweeping an unloaded (empty) archive would delete
        // every recording. Order: load → recover (dedupes vs sessions,
        // claims interrupted audio) → sweep.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.archive.loadIfNeeded()
            self.recoverInterruptedSession()
            self.archive.sweepOrphans()
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1 CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verify launch + recovery + no data loss**

Manual (device with existing saved sessions **and** at least one saved recording):
1. Cold launch → Sessions list populates (a frame later than before is fine) with all prior sessions, audio intact (confirms the sweep didn't nuke recordings).
2. Force-quit mid-recording, relaunch → interrupted session recovered with audio.
3. Settings → Diagnostics or just observe: launch feels snappier with a large history.

- [ ] **Step 4: Commit**

```bash
git add Loqi/Support/CaptionPipeline.swift
git commit -m "perf: sequence async archive load before recovery and sweep"
```

---

### Task 8: Full regression pass

**Files:** none (verification only).

- [ ] **Step 1: Run the whole suite**

Run the full Swift test suite from Xcode on a real iPhone; do not use a simulator.
Expected: ALL TESTS PASS — especially `CaptionStoreTests`, `SessionJournalTests`, `CaptionGroupingTests`, `JournalSnapshotTests`, `SessionArchiveLoadTests`.

- [ ] **Step 2: End-to-end manual smoke**

Manual (device): record a multi-minute session with pauses, speakers, and a photo → grouping + photo interleave correct, scrolling smooth. Stop → session saves with full transcript/audio. Relaunch → list loads, all history + recordings present. Force-quit mid-record → recovery intact.

- [ ] **Step 3: Commit any fixups**

```bash
git add -A
git commit -m "test: full regression for launch/journal/rendering perf"
```

---

## Self-Review

**Spec coverage** (the three review findings + minors):
- Finding #1 cold-launch decode on main → Phase C (Tasks 6–7): off-main `decodeAll`, async `loadIfNeeded`, sequenced recover/sweep with `didLoad` guard.
- Finding #2 O(n²) journal mapping on main → Phase B (Tasks 4–5): `buildJournalRecord` on the writer actor, `writeJournal` passes raw `Sendable` inputs.
- Finding #3 regroup-on-render → Phase A (Tasks 1–3): pure `CaptionGrouping`, store cache invalidated by `entries`, view consumes `store.segments()`.
- Minor: observable granularity → addressed by #3 (transcript was the remaining coarse observer).
- **Deferred, with rationale (YAGNI, not silent drops):**
  - *Vestigial `entries(in:)` mode filter* — after #3 caches segments and #2 moves the journal map off-main, its remaining hot-path cost is one filter per body. Removing the `SessionMode` dimension is a cross-cutting refactor (touches `SessionRecord`, archive, exports) for marginal gain. Not worth it now.
  - *`SessionArchive.persist` encodes on the main actor* — discovered while reading; it fires only at stop/summarize/import (low frequency, one record), not on a hot loop. Same `decodeAll`/`detached` pattern would move it off-main if it ever shows up in a trace. Out of scope here.

**Placeholder scan:** none — every code step shows complete code; every test step shows assertions; every run step shows the command + expected result. The one conditional ("if `didSet` is rejected…") names the exact fallback call sites, not a vague "handle it".

**Type consistency:** `CaptionSegment`/`CaptionGrouping.segments` (Task 1) used identically in Tasks 2–3. `CaptionStore.segments()` (Task 2) called in Task 3. `JournalSnapshotInputs` field names + `buildJournalRecord`/`write(building:)` (Task 4) matched exactly by the call site in Task 5. `decodeAll(in:)`/`loadIfNeeded()`/`didLoad` (Task 6) consumed in Task 7. `SessionArchive.mappedEntries(from:startedAt:timeline:)` used with its real signature in Task 4.

**Known follow-ups to verify during execution (not blockers):**
- Task 2: confirm `@Observable` accepts `didSet` on `entries`; fallback is specified.
- Task 3: the compiler will flag every residual `Segment` reference — rename each to `CaptionSegment`; `HorizontalCaptionView` is intentionally left alone.
- Task 7: confirm no other code path calls `archive.sweepOrphans()` before `loadIfNeeded()` (grep `sweepOrphans` — currently only this init site).
