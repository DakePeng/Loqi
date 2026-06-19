# Real-Time Translation: Heat & Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop live LLM translation from hitting "low memory" / "device hot" after ~1 sentence by (a) measuring which subsystem actually drives heat, (b) shipping cheap heat/latency knobs, and (c) running a light 0.8B model live while reserving the 2B model for post-session summarization.

**Architecture:** One shared `LLMService` keeps a single model resident; it runs the **live tier (0.8B)** during recording and swaps to the **summary tier (2B, the user's quality pick)** only after the session stops — so the heavy VLM never sits in memory beside SenseVoice's in-process ONNX. Heat tuning is gated behind a single `perf.reduceHeat` toggle plus a thermal-aware refinement gate; instrumentation accumulates per-component active time so the SenseVoice-vs-LLM question becomes a number in Diagnostics.

**Tech Stack:** Swift 6 concurrency (actors, `@MainActor`, `@Observable`), MLX / MLXVLM (Qwen3.5), sherpa-onnx (SenseVoice + silero VAD), Apple `Translation` framework, Swift Testing (`import Testing`, `@Test`, `#expect`), XcodeGen (`project.yml`).

## Global Constraints

- **Test framework:** Swift Testing only (`import Testing` + `@testable import Loqi`). No XCTest in new tests. Follow existing files like `LoqiTests/ModelCatalogTests.swift`.
- **Test/build command:** `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1` (substitute any installed iOS simulator for `iPhone 16`). Single test: append `-only-testing:LoqiTests/<Suite>/<testFunc>`. Constrained `-jobs 1` per `AGENTS.md`.
- **MLX never runs in tests/simulator** (see `LLMService.swift:19`). Every LLM-touching test must exercise a *pure* function (no `container`, no Metal). Mirror the `LLMService.admittedCacheLimit` test style.
- **Model ids (verbatim):** live = `mlx-community/Qwen3.5-0.8B-4bit`; summary/default = `mlx-community/Qwen3.5-2B-4bit`. Both are VLMs (`supportsVision == true`).
- **Headroom (verbatim, unchanged):** 0.8B `requiredHeadroom: 1_100_000_000`, `downloadBytes: 652_000_000`. 2B `requiredHeadroom: 2_200_000_000`, `downloadBytes: 1_750_000_000`.
- **New UserDefaults keys:** `"perf.reduceHeat"` (Bool, default **false** — opt-in, preserves current behavior), `"display.keepScreenOn"` (Bool, default **true**). Defaults read via the `object(forKey:) == nil ? default : bool(forKey:)` idiom used by `llm.enabled` (see `CaptionPipeline.swift:1538`).
- **Logging subsystem:** `"com.kunzhipeng.loqi"` (match existing `Logger` categories).
- **Ponytail:** no new abstractions beyond the named pure helpers below; reuse existing machinery (`suspendedSummaries`/`resumeLLMJobs`, `setModel`, static decision-func pattern). Skipped items are listed in each phase — do not build them.
- **Commit cadence:** one commit per task (TDD: test → impl → pass → commit). Conventional Commit messages.

---

## File Structure

**New files:**
- `Loqi/Pipeline/Refinement/RefinementGate.swift` — pure decision: should a finalized utterance be refined, given length / thermal / reduce-heat. One responsibility: the tier-2 admission rule.
- `Loqi/Pipeline/ASR/SenseVoiceTuning.swift` — pure: partial re-decode interval + decoder thread count as a function of `reduceHeat`.
- `Loqi/Support/SessionHeatStats.swift` — pure: holds per-component active seconds + a `dominant` classifier for Diagnostics.
- `LoqiTests/RefinementGateTests.swift`, `LoqiTests/SenseVoiceTuningTests.swift`, `LoqiTests/SessionHeatStatsTests.swift`, `LoqiTests/ThermalMonitorTests.swift` — Swift Testing suites.

**Modified files:**
- `Loqi/Support/ModelCatalog.swift` — add `liveModel`, `summaryModel`, `onboardingLLMBytes`.
- `Loqi/Support/ThermalMonitor.swift` — bounded thermal-transition log (pure trimmer).
- `Loqi/Pipeline/Refinement/LLMService.swift` — `generateActiveSeconds` accumulator + `resetHeatStats()`.
- `Loqi/Pipeline/ASR/SenseVoiceEngine.swift` — tunable partial interval + decoder threads; `decodeActiveSeconds` accumulator + reset.
- `Loqi/Support/CaptionPipeline.swift` — live-model selection, refinement gate, screen-keep-on gate, heat-stats reset, `reduceHeat` accessor.
- `Loqi/Pipeline/Summary/SummaryJobCenter.swift` — summary-model selection; summarize yields to recording.
- `Loqi/Features/Onboarding/OnboardingDownloadModel.swift` + `Loqi/Features/Onboarding/OnboardingCatalog.swift` — download both models at setup.
- `Loqi/Features/Settings/SettingsView.swift` — `perf.reduceHeat` + `display.keepScreenOn` toggles; expanded Diagnostics readout.

---

## Phase 0 — Heat instrumentation (measure first)

> Rationale: we don't yet know whether SenseVoice's every-0.7s re-decode or the LLM dominates heat *on a real device*. Ship the meter before tuning, so the rest is data-driven.

### Task 1: SessionHeatStats — per-component active-time classifier

**Files:**
- Create: `Loqi/Support/SessionHeatStats.swift`
- Test: `LoqiTests/SessionHeatStatsTests.swift`

**Interfaces:**
- Produces: `struct SessionHeatStats` with `mutating func add(llm:)`, `add(asr:)`, `var llmActiveSeconds`, `var asrActiveSeconds`, and `static func dominant(llmSeconds:asrSeconds:) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Loqi

struct SessionHeatStatsTests {
    @Test func accumulatesPerComponent() {
        var stats = SessionHeatStats()
        stats.add(llm: 1.5)
        stats.add(llm: 0.5)
        stats.add(asr: 4.0)
        #expect(stats.llmActiveSeconds == 2.0)
        #expect(stats.asrActiveSeconds == 4.0)
    }

    @Test func dominantPicksLargerComponent() {
        #expect(SessionHeatStats.dominant(llmSeconds: 5, asrSeconds: 40) == "ASR")
        #expect(SessionHeatStats.dominant(llmSeconds: 30, asrSeconds: 10) == "LLM")
    }

    @Test func dominantIsDashWhenIdle() {
        #expect(SessionHeatStats.dominant(llmSeconds: 0, asrSeconds: 0) == "—")
    }

    @Test func dominantNeedsAClearMargin() {
        // Within 20% is "≈" — neither clearly drives heat.
        #expect(SessionHeatStats.dominant(llmSeconds: 10, asrSeconds: 11) == "≈")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/SessionHeatStatsTests`
Expected: FAIL — "cannot find 'SessionHeatStats' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Per-session active-time tally for the two heavy compute paths, so the
/// Diagnostics screen can answer "is SenseVoice or the LLM driving heat?"
/// with a number instead of a guess. Active seconds, not wall seconds:
/// each path adds only the time it spent computing.
struct SessionHeatStats: Equatable {
    private(set) var llmActiveSeconds: Double = 0
    private(set) var asrActiveSeconds: Double = 0

    mutating func add(llm seconds: Double) { llmActiveSeconds += max(0, seconds) }
    mutating func add(asr seconds: Double) { asrActiveSeconds += max(0, seconds) }

    /// "LLM" / "ASR" when one clearly leads, "≈" when within 20%, "—" when idle.
    static func dominant(llmSeconds: Double, asrSeconds: Double) -> String {
        let total = llmSeconds + asrSeconds
        guard total > 0 else { return "—" }
        let lead = abs(llmSeconds - asrSeconds)
        if lead < 0.2 * max(llmSeconds, asrSeconds) { return "≈" }
        return llmSeconds > asrSeconds ? "LLM" : "ASR"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/SessionHeatStatsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Support/SessionHeatStats.swift LoqiTests/SessionHeatStatsTests.swift
git commit -m "feat: add SessionHeatStats per-component heat classifier"
```

---

### Task 2: LLMService — accumulate generation active time

**Files:**
- Modify: `Loqi/Pipeline/Refinement/LLMService.swift:26-28` (add stored property near `lastTokensPerSecond`), `:344-349` (accumulate in `generate`), and add `resetHeatStats()`.

**Interfaces:**
- Consumes: nothing new.
- Produces: `LLMService.generateActiveSeconds: Double` (actor-isolated, `private(set)`), `func resetHeatStats()`.

- [ ] **Step 1: Add the accumulator property**

In `LLMService.swift`, directly under the existing `lastTokensPerSecond` declaration (currently `:27`):

```swift
    /// Last measured generation speed, for the debug screen.
    private(set) var lastTokensPerSecond: Double = 0

    /// Cumulative wall time spent inside `generate`/`describeImage` this
    /// session — Diagnostics compares it against SenseVoice decode time to
    /// show which path drives heat. Reset by the pipeline at session start.
    private(set) var generateActiveSeconds: Double = 0
```

- [ ] **Step 2: Accumulate in `generate`**

In `generate`, the elapsed time is already computed (`:344-349`). Add one line after `lastTokensPerSecond` is set:

```swift
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        generateActiveSeconds += seconds
        if seconds > 0 {
            lastTokensPerSecond = Self.estimatedDiagnosticTokens(in: result) / seconds
        }
```

- [ ] **Step 3: Add `resetHeatStats`**

Add next to `clearCache()` (`:291`):

```swift
    func resetHeatStats() {
        generateActiveSeconds = 0
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED. (No unit test — MLX `generate` can't run in the simulator; correctness is one accumulation line, verified by build + the Diagnostics readout in Task 11.)

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/Refinement/LLMService.swift
git commit -m "feat: accumulate LLM generation active time for diagnostics"
```

---

### Task 3: SenseVoiceEngine — accumulate decode active time

**Files:**
- Modify: `Loqi/Pipeline/ASR/SenseVoiceEngine.swift` — add `decodeActiveSeconds` to the engine actor, time each decode, add `resetHeatStats()`.

**Interfaces:**
- Produces: `SenseVoiceEngine.decodeActiveSeconds: Double` (`private(set)`), `func resetHeatStats()`.

> Note: read the file first to find the exact decode call sites — the engine drives `decoder` in `maybeDecodePartial()` (`~:172`) and at the final/flush decode. Wrap **each** decode call with a `ContinuousClock` measurement and add to `decodeActiveSeconds`.

- [ ] **Step 1: Add the accumulator property**

Near the other private vars at the top of `SenseVoiceEngine` (around `:31`):

```swift
    /// Cumulative wall time spent in SenseVoice decode this session (partial
    /// + final), the ASR counterpart to LLMService.generateActiveSeconds.
    private(set) var decodeActiveSeconds: Double = 0
```

- [ ] **Step 2: Time each decode call**

Wrap every `decoder?.decode(...)` / `await decoder...` invocation (partial and final) like:

```swift
        let decodeStart = ContinuousClock.now
        let result = await decoder?.decode(samples: utteranceCopy)   // existing call, unchanged args
        let d = decodeStart.duration(to: .now)
        decodeActiveSeconds += Double(d.components.seconds)
            + Double(d.components.attoseconds) / 1e18
```

Apply the identical wrapper at the final/flush decode site as well. Do not change decode arguments or control flow — only measure.

- [ ] **Step 3: Add `resetHeatStats`**

```swift
    func resetHeatStats() {
        decodeActiveSeconds = 0
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/ASR/SenseVoiceEngine.swift
git commit -m "feat: accumulate SenseVoice decode active time for diagnostics"
```

---

### Task 4: ThermalMonitor — bounded transition log

**Files:**
- Modify: `Loqi/Support/ThermalMonitor.swift` — add a `Transition` type, a `transitions` ring, and a pure static trimmer; record in `apply`.
- Test: `LoqiTests/ThermalMonitorTests.swift`

**Interfaces:**
- Produces: `ThermalMonitor.Transition` (`struct { let state: ProcessInfo.ThermalState; let at: Date }`), `ThermalMonitor.transitions: [Transition]` (`private(set)`), `static func appendTransition(_:to:limit:) -> [Transition]`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Loqi

struct ThermalMonitorTests {
    @Test func appendKeepsNewestWithinLimit() {
        var log: [ThermalMonitor.Transition] = []
        let base = Date(timeIntervalSince1970: 0)
        for i in 0..<25 {
            log = ThermalMonitor.appendTransition(
                .init(state: .nominal, at: base.addingTimeInterval(Double(i))),
                to: log, limit: 20)
        }
        #expect(log.count == 20)
        #expect(log.first?.at == base.addingTimeInterval(5))   // oldest 5 dropped
        #expect(log.last?.at == base.addingTimeInterval(24))
    }

    @Test func appendUnderLimitGrows() {
        var log: [ThermalMonitor.Transition] = []
        log = ThermalMonitor.appendTransition(
            .init(state: .serious, at: Date(timeIntervalSince1970: 1)), to: log, limit: 20)
        #expect(log.count == 1)
        #expect(log.first?.state == .serious)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/ThermalMonitorTests`
Expected: FAIL — "type 'ThermalMonitor' has no member 'Transition'".

- [ ] **Step 3: Write minimal implementation**

In `ThermalMonitor.swift`, add inside the class:

```swift
    struct Transition: Equatable, Sendable {
        let state: ProcessInfo.ThermalState
        let at: Date
    }

    /// Recent thermal-state changes for the Diagnostics screen (newest last).
    private(set) var transitions: [Transition] = []

    /// Pure ring-append: keep the newest `limit` transitions. Static so it's
    /// testable without the live notification stream.
    static func appendTransition(
        _ transition: Transition, to log: [Transition], limit: Int = 20
    ) -> [Transition] {
        var next = log
        next.append(transition)
        if next.count > limit { next.removeFirst(next.count - limit) }
        return next
    }
```

Then in `apply(_:)`, record the change when the state actually differs. Replace the first line of `apply`:

```swift
    private func apply(_ state: ProcessInfo.ThermalState) {
        if state != thermalState {
            transitions = Self.appendTransition(.init(state: state, at: .now), to: transitions)
        }
        thermalState = state
```

(`ProcessInfo.ThermalState` is already `Comparable`/usable here; `Equatable` is satisfied by the raw enum.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/ThermalMonitorTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Support/ThermalMonitor.swift LoqiTests/ThermalMonitorTests.swift
git commit -m "feat: record bounded thermal transition log"
```

---

### Task 5: Wire heat stats into the pipeline + Diagnostics

**Files:**
- Modify: `Loqi/Support/CaptionPipeline.swift` — reset stats at `beginSession`; add a `reduceHeat` accessor (used later too).
- Modify: `Loqi/Features/Settings/SettingsView.swift:227-236` (Diagnostics section) + `refreshStats()` (`:318-331`).

**Interfaces:**
- Consumes: `LLMService.generateActiveSeconds`/`resetHeatStats()`, `SenseVoiceEngine.decodeActiveSeconds`/`resetHeatStats()`, `ThermalMonitor.transitions`, `SessionHeatStats.dominant`.
- Produces: `CaptionPipeline.reduceHeat: Bool`.

- [ ] **Step 1: Add `reduceHeat` accessor + reset stats at session start**

In `CaptionPipeline.swift`, near `llmEnabled` (`:1538`):

```swift
    /// Opt-in low-heat / low-power mode (Settings). Trades caption latency
    /// and refinement frequency for less sustained compute.
    var reduceHeat: Bool { UserDefaults.standard.bool(forKey: "perf.reduceHeat") }
```

In `beginSession`, just after `ensureEngine(for: route.source)` (`:485`), reset the meters:

```swift
        ensureEngine(for: route.source)
        Task { [llm] in await llm.resetHeatStats() }
        if let engine = engines[engineKey(for: route.source)] as? SenseVoiceEngine {
            Task { await engine.resetHeatStats() }
        }
```

- [ ] **Step 2: Surface in Diagnostics**

In `SettingsView.swift`, add `@State` vars near `tokensPerSecond` (`:26`):

```swift
    @State private var tokensPerSecond: Double?
    @State private var llmActiveSeconds: Double = 0
    @State private var asrActiveSeconds: Double = 0
    @State private var thermalTransitions = 0
```

Extend the Diagnostics `Section` (`:227`) after the `tokensPerSecond` row:

```swift
                Section("Diagnostics") {
                    LabeledContent("Model state", value: llmState)
                    LabeledContent("Available memory", value: availableMemory)
                    LabeledContent("Thermal state", value: thermalLabel)
                    LabeledContent("Thermal changes", value: "\(thermalTransitions)")
                    if let tokensPerSecond {
                        LabeledContent(
                            "Last generation",
                            value: String(format: "%.1f tok/s", tokensPerSecond))
                    }
                    LabeledContent("LLM active", value: String(format: "%.1fs", llmActiveSeconds))
                    LabeledContent("ASR active", value: String(format: "%.1fs", asrActiveSeconds))
                    LabeledContent(
                        "Heat driver",
                        value: SessionHeatStats.dominant(
                            llmSeconds: llmActiveSeconds, asrSeconds: asrActiveSeconds))
                }
```

- [ ] **Step 3: Populate them in `refreshStats()`**

In `refreshStats()` (after the existing `tokensPerSecond` line, `:331`):

```swift
        llmActiveSeconds = await pipeline.llm.generateActiveSeconds
        asrActiveSeconds = await pipeline.activeSenseVoiceDecodeSeconds()
        thermalTransitions = pipeline.thermal.transitions.count
```

Add the helper to `CaptionPipeline` (it knows the active engine; keep the SenseVoice cast in one place):

```swift
    /// Decode active-seconds of the live SenseVoice engine, or 0 when the
    /// active engine is Apple's recognizer (no in-process decode cost).
    func activeSenseVoiceDecodeSeconds() async -> Double {
        for engine in engines.values {
            if let sv = engine as? SenseVoiceEngine {
                return await sv.decodeActiveSeconds
            }
        }
        return 0
    }
```

- [ ] **Step 4: Build + manual verify**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.
Manual (on device, since SenseVoice/MLX need real hardware): record ~30s with SenseVoice + translation on, open Settings → Diagnostics, confirm "LLM active", "ASR active", "Heat driver", and "Thermal changes" populate.

- [ ] **Step 5: Commit**

```bash
git add Loqi/Support/CaptionPipeline.swift Loqi/Features/Settings/SettingsView.swift
git commit -m "feat: surface per-component heat stats in Diagnostics"
```

> **Phase 0 skipped (YAGNI):** no charts, no CSV export, no historical persistence across launches. The live numbers answer the SenseVoice-vs-LLM question; add persistence only if a single session proves insufficient.

---

## Phase 1 — Cheap heat / latency knobs (gated by `perf.reduceHeat`)

### Task 6: SenseVoiceTuning — partial interval + decoder threads

**Files:**
- Create: `Loqi/Pipeline/ASR/SenseVoiceTuning.swift`
- Test: `LoqiTests/SenseVoiceTuningTests.swift`

**Interfaces:**
- Produces: `enum SenseVoiceTuning` with `static func partialInterval(reduceHeat: Bool) -> Int` and `static func decoderThreads(reduceHeat: Bool) -> Int`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Loqi

struct SenseVoiceTuningTests {
    @Test func partialIntervalSlowsUnderReduceHeat() {
        // Default cadence is 0.7s @ 16kHz = 11_200 samples.
        #expect(SenseVoiceTuning.partialInterval(reduceHeat: false) == 11_200)
        // Reduced: ~1.6s, far fewer whole-utterance re-decodes per sentence.
        #expect(SenseVoiceTuning.partialInterval(reduceHeat: true) == 25_600)
        #expect(SenseVoiceTuning.partialInterval(reduceHeat: true)
            > SenseVoiceTuning.partialInterval(reduceHeat: false))
    }

    @Test func decoderThreadsDropUnderReduceHeat() {
        #expect(SenseVoiceTuning.decoderThreads(reduceHeat: false) == 2)
        #expect(SenseVoiceTuning.decoderThreads(reduceHeat: true) == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/SenseVoiceTuningTests`
Expected: FAIL — "cannot find 'SenseVoiceTuning' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// SenseVoice live-decode knobs. The recognizer is non-streaming and
/// re-decodes the *entire growing utterance* every partial interval, so
/// raising the interval and dropping decode threads are the two cheapest
/// during-speech heat cuts. ponytail: two constants, gated by one toggle.
enum SenseVoiceTuning {
    /// Samples between volatile partial re-decodes (16kHz). 0.7s default;
    /// ~1.6s under reduce-heat — captions pulse a little slower, the final
    /// decode at the pause is unchanged.
    static func partialInterval(reduceHeat: Bool) -> Int {
        reduceHeat ? 25_600 : 11_200
    }

    /// ONNX decode threads for the live engine. Fewer = lower peak CPU/heat
    /// at slightly slower partials.
    static func decoderThreads(reduceHeat: Bool) -> Int {
        reduceHeat ? 1 : 2
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/SenseVoiceTuningTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/ASR/SenseVoiceTuning.swift LoqiTests/SenseVoiceTuningTests.swift
git commit -m "feat: add SenseVoice reduce-heat tuning knobs"
```

---

### Task 7: Apply SenseVoice tuning in the engine

**Files:**
- Modify: `Loqi/Pipeline/ASR/SenseVoiceEngine.swift` — replace the `static let partialInterval` constant (`:41`) with a per-prepare instance value; pass tuned thread count to `SenseVoiceDecoder` (`:55`, decoder default at `:232`).

**Interfaces:**
- Consumes: `SenseVoiceTuning.partialInterval`, `SenseVoiceTuning.decoderThreads`.

- [ ] **Step 1: Make the partial interval an instance value**

Replace the static constant usage. Add an instance var near the other per-session state (`:31`):

```swift
    /// Resolved from `perf.reduceHeat` at prepare() — see SenseVoiceTuning.
    private var partialInterval = SenseVoiceTuning.partialInterval(reduceHeat: false)
```

Remove `private static let partialInterval = 11_200` (`:41`). In `maybeDecodePartial()` change `Self.partialInterval` to `partialInterval` (`:173`).

- [ ] **Step 2: Resolve the knobs in `prepare()`**

At the top of `prepare()` (before constructing `decoder`, `:55`):

```swift
        let reduceHeat = UserDefaults.standard.bool(forKey: "perf.reduceHeat")
        partialInterval = SenseVoiceTuning.partialInterval(reduceHeat: reduceHeat)
        decoder = SenseVoiceDecoder(
            sourceSelection: sourceSelection,
            numThreads: SenseVoiceTuning.decoderThreads(reduceHeat: reduceHeat))
```

(The `SenseVoiceDecoder(sourceSelection:numThreads:)` initializer already exists with `numThreads: Int = 2` at `:232`.)

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Confirm existing SenseVoice tests still pass**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/SpeechRunLimiterTests`
Expected: PASS (no regression in the limiter that shares this engine).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/ASR/SenseVoiceEngine.swift
git commit -m "feat: apply reduce-heat partial interval and decode threads"
```

---

### Task 8: RefinementGate — thermal-aware, length-aware tier-2 admission

**Files:**
- Create: `Loqi/Pipeline/Refinement/RefinementGate.swift`
- Test: `LoqiTests/RefinementGateTests.swift`

**Interfaces:**
- Produces: `enum RefinementGate` with `static func shouldRefine(textLength: Int, forced: Bool, thermalState: ProcessInfo.ThermalState, reduceHeat: Bool) -> Bool`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Loqi

struct RefinementGateTests {
    @Test func forcedAlwaysRefines() {
        // Hotword near-miss: refine even a 1-char utterance, even when warm.
        #expect(RefinementGate.shouldRefine(
            textLength: 1, forced: true, thermalState: .fair, reduceHeat: true))
    }

    @Test func shortUtterancesSkipWhenNotForced() {
        #expect(!RefinementGate.shouldRefine(
            textLength: 5, forced: false, thermalState: .nominal, reduceHeat: false))
        #expect(RefinementGate.shouldRefine(
            textLength: 12, forced: false, thermalState: .nominal, reduceHeat: false))
    }

    @Test func fairThermalRaisesThreshold() {
        // 16 chars passes when nominal, is held back at .fair (pre-emptive).
        #expect(RefinementGate.shouldRefine(
            textLength: 16, forced: false, thermalState: .nominal, reduceHeat: false))
        #expect(!RefinementGate.shouldRefine(
            textLength: 16, forced: false, thermalState: .fair, reduceHeat: false))
    }

    @Test func reduceHeatRaisesThreshold() {
        #expect(!RefinementGate.shouldRefine(
            textLength: 16, forced: false, thermalState: .nominal, reduceHeat: true))
    }

    @Test func seriousAndCriticalNeverRefine() {
        #expect(!RefinementGate.shouldRefine(
            textLength: 999, forced: false, thermalState: .serious, reduceHeat: false))
        #expect(!RefinementGate.shouldRefine(
            textLength: 999, forced: false, thermalState: .critical, reduceHeat: false))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/RefinementGateTests`
Expected: FAIL — "cannot find 'RefinementGate' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Tier-2 admission. The tier-1 Apple draft is already on screen, so a 2B/0.8B
/// generation is an *upgrade* we can skip cheaply. Skips trivially short
/// utterances and pre-emptively tightens before the thermal ladder (which
/// only pauses after a 60s `.serious` dwell) ever trips.
enum RefinementGate {
    /// Floor length (characters) worth a generation when cool.
    static let baseThreshold = 12
    /// Raised floor under early heat / reduce-heat.
    static let throttledThreshold = 24

    static func shouldRefine(
        textLength: Int,
        forced: Bool,
        thermalState: ProcessInfo.ThermalState,
        reduceHeat: Bool
    ) -> Bool {
        if forced { return true }
        switch thermalState {
        case .serious, .critical:
            return false
        case .fair:
            return textLength >= throttledThreshold
        default:
            return textLength >= (reduceHeat ? throttledThreshold : baseThreshold)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/RefinementGateTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/Refinement/RefinementGate.swift LoqiTests/RefinementGateTests.swift
git commit -m "feat: add thermal- and length-aware refinement gate"
```

---

### Task 9: Apply RefinementGate in the pipeline

**Files:**
- Modify: `Loqi/Support/CaptionPipeline.swift:1284-1291` (`processFinalizedEntry`, the `wantsRefinement` computation).

**Interfaces:**
- Consumes: `RefinementGate.shouldRefine`, `CaptionPipeline.reduceHeat`, `thermal.thermalState`.

- [ ] **Step 1: Replace the refinement decision**

Current (`:1284-1291`):

```swift
        // Hotword near-misses force refinement even for short utterances —
        // names usually appear in exactly those.
        let wantsRefinement = refine
            || matcher.shouldForceRefine(text, language: direction.source)
        // !isBackgrounded: the paused queue silently DROPS enqueued jobs — a
        // backgrounded entry marked refining would spin forever. It takes the
        // draft path instead.
        if wantsRefinement, llmEnabled, !isBackgrounded,
           thermal.policy == .full, await llmIsReady() {
```

Replace with:

```swift
        // Hotword near-misses force refinement even for short utterances —
        // names usually appear in exactly those. Otherwise the gate skips
        // trivially short lines and pre-emptively throttles under early heat.
        let forced = matcher.shouldForceRefine(text, language: direction.source)
        let wantsRefinement = (refine || forced) && RefinementGate.shouldRefine(
            textLength: text.count,
            forced: forced,
            thermalState: thermal.thermalState,
            reduceHeat: reduceHeat)
        // !isBackgrounded: the paused queue silently DROPS enqueued jobs — a
        // backgrounded entry marked refining would spin forever. It takes the
        // draft path instead.
        if wantsRefinement, llmEnabled, !isBackgrounded,
           thermal.policy == .full, await llmIsReady() {
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Confirm no caption/test regressions**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/CaptionStoreTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Loqi/Support/CaptionPipeline.swift
git commit -m "feat: gate tier-2 refinement by length and thermal state"
```

---

### Task 10: Screen-keep-on toggle (let the display sleep)

**Files:**
- Modify: `Loqi/Support/CaptionPipeline.swift:508-510` (the `isIdleTimerDisabled = true` in `beginSession`) and `:692-695` (reset in `endSession`).
- Modify: `Loqi/Features/Settings/SettingsView.swift` — add a toggle to the Recording section.

**Interfaces:**
- Consumes: `UserDefaults` key `"display.keepScreenOn"` (default true).

> The display is one of the largest heat/power sinks; locked-screen recording already works (audio background mode keeps ASR alive, Metal pauses). This makes "keep screen on" optional. ponytail: a gated one-liner, no auto-dim.

- [ ] **Step 1: Gate the idle-timer disable**

In `beginSession` (`:508-510`):

```swift
        #if os(iOS)
        let keepOn = UserDefaults.standard.object(forKey: "display.keepScreenOn") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "display.keepScreenOn")
        UIApplication.shared.isIdleTimerDisabled = keepOn
        #endif
```

(The `endSession` reset to `false` at `:693-695` stays as-is — always re-enable the idle timer when recording stops.)

- [ ] **Step 2: Add the Settings toggle**

In `SettingsView.swift`, add the `@AppStorage` near the others (`:10`):

```swift
    @AppStorage("display.keepScreenOn") private var keepScreenOn = true
```

In the Recording `Section` (`:219-225`), add below "Save audio recordings":

```swift
                Section {
                    Toggle("Save audio recordings", isOn: $saveRecordings)
                    Toggle("Keep screen on while recording", isOn: $keepScreenOn)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Keep each session's audio alongside its transcript. Recordings are stored only on this iPhone and are deleted with their session. Turning off “Keep screen on” lets the display sleep during long recordings — captions keep running and it runs noticeably cooler.")
                }
```

- [ ] **Step 3: Build + manual verify**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.
Manual (device): toggle off, start recording, confirm the screen auto-locks after the system idle interval and captions continue; toggle on, confirm screen stays awake.

- [ ] **Step 4: Commit**

```bash
git add Loqi/Support/CaptionPipeline.swift Loqi/Features/Settings/SettingsView.swift
git commit -m "feat: optional keep-screen-on to let the display sleep while recording"
```

---

### Task 11: `perf.reduceHeat` toggle in Settings

**Files:**
- Modify: `Loqi/Features/Settings/SettingsView.swift` — add the reduce-heat toggle (its own section or under an existing "AI"/performance section).

**Interfaces:**
- Produces: the user-facing switch for `"perf.reduceHeat"` consumed by Tasks 6–9.

- [ ] **Step 1: Add the `@AppStorage` and toggle**

Near the other `@AppStorage` (`:11`):

```swift
    @AppStorage("perf.reduceHeat") private var reduceHeat = false
```

Add a section (place it just above the `Diagnostics` section, `:227`):

```swift
                Section {
                    Toggle("Reduce heat", isOn: $reduceHeat)
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Lowers sustained heat during long recordings: slower live-caption updates, fewer thread for speech recognition, and refinement only on longer sentences. Takes effect on the next recording.")
                }
```

- [ ] **Step 2: Build + verify the round-trip**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.
Manual (device): enable Reduce heat, start a session, confirm captions pulse less often (SenseVoice) and short utterances no longer flip to refined; watch Diagnostics "Heat driver" / "ASR active" drop vs a baseline session.

- [ ] **Step 3: Commit**

```bash
git add Loqi/Features/Settings/SettingsView.swift
git commit -m "feat: add Reduce heat performance toggle"
```

> **Phase 1 skipped (YAGNI / not yet justified):** auto-dim brightness control; an Apple-ASR "real-time mode" switch (Apple is already selectable in Settings — revisit only if Diagnostics shows SenseVoice dominates *and* the knobs above aren't enough); SenseVoice CoreML/ANE execution-provider migration (separate investigation — sherpa-onnx provider support is unverified; do not attempt blind).

---

## Phase 2 — Dual model: 0.8B live, 2B summary

> The big memory win: only the 0.8B (1.1 GB headroom) is resident *during* recording beside SenseVoice; the 2B (2.2 GB) loads only after the mic and SenseVoice are torn down. One shared `LLMService`, model swapped at the session boundary via the existing `setModel` (which unloads the old model — peak = max, never the sum).

### Task 12: Model roles in ModelCatalog

**Files:**
- Modify: `Loqi/Support/ModelCatalog.swift` — add `liveModel`, `summaryModel`, `onboardingLLMBytes`.
- Test: `LoqiTests/ModelCatalogTests.swift` (extend the existing suite).

**Interfaces:**
- Produces: `ModelCatalog.liveModel: ModelOption`, `ModelCatalog.summaryModel: ModelOption` (computed from `current`), `ModelCatalog.onboardingLLMBytes: Int64`.

- [ ] **Step 1: Write the failing tests**

Append to `LoqiTests/ModelCatalogTests.swift`:

```swift
    @Test func liveModelIsTheFastTier() {
        #expect(ModelCatalog.liveModel.id == ModelCatalog.qwen35_0_8b.id)
        // Live tier must fit beside SenseVoice — strictly lighter than 2B.
        #expect(ModelCatalog.liveModel.requiredHeadroom
            < ModelCatalog.qwen35_2b.requiredHeadroom)
    }

    @Test func summaryModelFollowsUserPick() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ModelCatalog.qwen35_0_8b.id, forKey: "model.id")
        // summaryModel reads `current`, which reads standard defaults; assert
        // the relationship via option(for:) instead of mutating standard.
        #expect(ModelCatalog.summaryModel.id == ModelCatalog.current.id)
    }

    @Test func onboardingBytesCoverBothModels() {
        #expect(ModelCatalog.onboardingLLMBytes
            == ModelCatalog.qwen35_2b.downloadBytes + ModelCatalog.qwen35_0_8b.downloadBytes)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/ModelCatalogTests`
Expected: FAIL — "type 'ModelCatalog' has no member 'liveModel'".

- [ ] **Step 3: Add the roles**

In `ModelCatalog.swift`, after `static let default = qwen35_2b` (`:100`):

```swift
    /// Model that runs *during* a live recording: the fast, low-memory,
    /// low-heat tier. Always 0.8B regardless of the user's quality pick, so
    /// translation refinement and live notes never load the heavy VLM beside
    /// SenseVoice's in-process ONNX.
    static let liveModel = qwen35_0_8b

    /// Model post-session summary / title / vocabulary runs on: the user's
    /// quality pick (default 2B). Equals `liveModel` when the user picked the
    /// fast tier, in which case the boundary swap is a no-op.
    static var summaryModel: ModelOption { current }

    /// Bytes onboarding pulls for the LLM step now that both tiers ship.
    static var onboardingLLMBytes: Int64 {
        summaryModelDownloadBytes + liveModel.downloadBytes
    }

    /// The default/quality tier's size (onboarding runs before the user has
    /// picked, so this is `default`, not `current`).
    private static var summaryModelDownloadBytes: Int64 { `default`.downloadBytes }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/ModelCatalogTests`
Expected: PASS (all, including the 3 new).

- [ ] **Step 5: Commit**

```bash
git add Loqi/Support/ModelCatalog.swift LoqiTests/ModelCatalogTests.swift
git commit -m "feat: add live (0.8B) and summary (2B) model roles"
```

---

### Task 13: Live path loads the live (0.8B) model

**Files:**
- Modify: `Loqi/Support/CaptionPipeline.swift:1558-1605` (`loadLLMIfAllowed` — set the live model before loading).

**Interfaces:**
- Consumes: `ModelCatalog.liveModel`, `LLMService.setModel`.

> `loadLLMIfAllowed` is the single choke for every live-session load (deferred start-load, first-silence-gap load, foreground reload). Setting the model here guarantees the live tier without touching the other call sites. `setModel` unloads if the option differs and no-ops if it matches.

- [ ] **Step 1: Set the live model inside the load task**

In `loadLLMIfAllowed`, inside the `Task { [llm] in ... }` (`:1570`), before the `if case .ready` early return:

```swift
        Task { [llm] in
            await llm.setModel(ModelCatalog.liveModel)
            // Called on every silence gap; only show status when there is
            // actually a load to do (llm.load joins in-flight loads).
            if case .ready = await llm.loadState {
                self.setStatus(.llm, nil)
                return
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Loqi/Support/CaptionPipeline.swift
git commit -m "feat: load the 0.8B live model during recording"
```

---

### Task 14: Summarize yields to recording (prevents 2B during a live session)

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryJobCenter.swift:165-197` (`yieldToRecording` / `resumeAfterRecording`).

**Interfaces:**
- Consumes / reuses: existing `suspendedSummaries`, `activeSummarizeRequest`, `resumeLLMJobs()`.

> Today `yieldToRecording` pauses re-transcribe and import but **not** a plain `.summarizing` job — so a post-stop summary could run a 2B model while the next recording wants 0.8B, and the boundary swap would unload it mid-generation. Reuse the background-suspend machinery (`suspendedSummaries` + `resumeLLMJobs`) so summaries never run during recording. This is also correct for memory/heat regardless of the model split.

- [ ] **Step 1: Suspend summarize in `yieldToRecording`**

In `yieldToRecording`, add a `.summarizing` / `.downloadingModel` case to the switch (`:167-182`):

```swift
        for (sessionID, activity) in activities {
            switch activity {
            case .retranscribing:
                if let req = activeRetranscribeRequest[sessionID] {
                    retranscribeQueue.insert(req, at: 0)
                }
                activities[sessionID] = .pausedForRecording
                tasks[sessionID]?.cancel()
            case .summarizing, .downloadingModel:
                // A live summary would hold the 2B model the recording needs
                // freed for the 0.8B tier. Suspend and restart after, exactly
                // like backgrounding does (the partial summary was never saved).
                if let req = activeSummarizeRequest[sessionID] {
                    suspendedSummaries[sessionID] = req
                }
                activities[sessionID] = .pausedForRecording
                tasks[sessionID]?.cancel()
            case .importing:
                tasks[sessionID]?.cancel()
            case .queuedRetranscribe:
                activities[sessionID] = .pausedForRecording
            default:
                break
            }
        }
```

- [ ] **Step 2: Restart suspended summaries in `resumeAfterRecording`**

In `resumeAfterRecording` (`:188-197`), after flipping held activities, kick the LLM-job resume:

```swift
    func resumeAfterRecording() {
        guard pausedForRecording else { return }
        pausedForRecording = false
        for (sessionID, activity) in activities {
            if case .pausedForRecording = activity {
                // Retranscribes re-queue; summaries restart via resumeLLMJobs,
                // which clears their held activity before re-running.
                if suspendedSummaries[sessionID] != nil {
                    activities[sessionID] = .pausedForBackground
                } else {
                    activities[sessionID] = .queuedRetranscribe
                }
            }
        }
        resumeLLMJobs()
        drainRetranscribeQueue()
    }
```

> Note: `resumeLLMJobs` (`:266-289`) already clears a `.pausedForBackground` activity and re-calls `summarize(...)`. Marking suspended summaries `.pausedForBackground` lets that existing path own the restart; non-summary holds keep the `.queuedRetranscribe` route.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual verify the race**

Manual (device): start a summary of a long saved session, then immediately start a new recording. Expected: the summary pauses (no error row), the recording runs on 0.8B, and after stopping the recording the summary restarts and completes.

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/Summary/SummaryJobCenter.swift
git commit -m "feat: suspend summaries during live recording so the live tier owns the GPU"
```

---

### Task 15: Summary path loads the summary (2B) model

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryJobCenter.swift:723-735` (`loadModel`) and `:582-583` (`startImport` task — import does LLM translation).

**Interfaces:**
- Consumes: `ModelCatalog.summaryModel`, `LLMService.setModel`.

- [ ] **Step 1: Select the summary model in `loadModel`**

At the top of `loadModel` (`:723`), before the `allowDownload` branch:

```swift
    private func loadModel(sessionID: UUID, allowDownload: Bool) async throws {
        guard llmEnabled else { throw JobError.aiDisabled }
        await llm.setModel(ModelCatalog.summaryModel)
        if allowDownload {
```

- [ ] **Step 2: Select the summary model for imports**

In `startImport`'s task (`:582`), set the model before constructing the importer:

```swift
        tasks[sessionID] = Task {
            defer { finishJob(sessionID) }
            do {
                await llm.setModel(ModelCatalog.summaryModel)
                let importer = FileImportEngine(
                    translator: translator, voiceprint: voiceprint,
                    llm: llm, hotwords: hotwords)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Confirm summary tests still pass**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/SummaryEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/Summary/SummaryJobCenter.swift
git commit -m "feat: run post-session summary on the 2B summary model"
```

---

### Task 16: Download both models at onboarding

**Files:**
- Modify: `Loqi/Features/Onboarding/OnboardingDownloadModel.swift:344-361` (`downloadLLM`).
- Modify: `Loqi/Features/Onboarding/OnboardingCatalog.swift:114-119` (the `.llm` `downloadBytes`).
- Test: `LoqiTests/OnboardingCatalogTests.swift` (extend).

**Interfaces:**
- Consumes: `ModelCatalog.liveModel`, `ModelCatalog.summaryModel`, `ModelCatalog.onboardingLLMBytes`.

- [ ] **Step 1: Write the failing catalog-size test**

In `LoqiTests/OnboardingCatalogTests.swift`, add (match the file's existing style — read it first):

```swift
    @Test func llmItemBytesCoverBothModels() {
        #expect(OnboardingItemKind.llm.downloadBytes == ModelCatalog.onboardingLLMBytes)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/OnboardingCatalogTests`
Expected: FAIL — size mismatch (currently `ModelCatalog.default.downloadBytes`).

- [ ] **Step 3: Update the catalog size**

In `OnboardingCatalog.swift` (`:119`), change:

```swift
        case .llm: ModelCatalog.onboardingLLMBytes
```

- [ ] **Step 4: Download both in `downloadLLM`**

Replace `downloadLLM` (`:344-361`) so it pulls the summary tier then the live tier, reporting a combined fraction, and leaves the pipeline on the live model:

```swift
    private func downloadLLM(_ item: Item) async {
        item.speedometer.start(totalBytes: ModelCatalog.onboardingLLMBytes)
        let llm = pipeline.llm
        await llm.setSource(region.llmSource)

        let summary = ModelCatalog.summaryModel
        let live = ModelCatalog.liveModel
        let summaryShare = Double(summary.downloadBytes)
            / Double(ModelCatalog.onboardingLLMBytes)

        do {
            // Summary tier (the big one) first.
            await llm.setModel(summary)
            try await llm.load { fraction in
                Task { @MainActor in item.speedometer.update(fraction * summaryShare) }
            }
            // Then the live tier; together they make the boundary swap instant.
            await llm.setModel(live)
            try await llm.load { fraction in
                Task { @MainActor in
                    item.speedometer.update(summaryShare + fraction * (1 - summaryShare))
                }
            }
            if LLMService.isDownloaded(model: summary), LLMService.isDownloaded(model: live) {
                item.status = .done
            } else {
                item.status = .failed("Download incomplete")
            }
        } catch is CancellationError {
            item.status = .failed("Stopped")
        } catch {
            item.status = .failed(error.localizedDescription)
        }
    }
```

> Read the surrounding `downloadLLM` / `Item.status` shape first and match the existing success/failure assignment exactly — the snippet above mirrors the original's `setModel`/`load`/`isDownloaded` pattern, but the `item.status` enum cases must match `Status` (`:14`).

- [ ] **Step 5: Run tests + build**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1 -only-testing:LoqiTests/OnboardingCatalogTests`
Expected: PASS.
Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Loqi/Features/Onboarding/OnboardingDownloadModel.swift Loqi/Features/Onboarding/OnboardingCatalog.swift LoqiTests/OnboardingCatalogTests.swift
git commit -m "feat: download both live and summary models during onboarding"
```

---

### Task 17: Settings copy — clarify the model picker governs the summary tier

**Files:**
- Modify: `Loqi/Features/Settings/SettingsView.swift` — the model-picker section footer.

**Interfaces:** none (copy only).

> With roles, the existing model picker now selects the **summary/quality** tier; live always uses 0.8B. Say so, or users will expect their pick to change live translation.

- [ ] **Step 1: Update the model-picker footer**

Find the model-picker `Section` (the one bound to `$modelID`) and set its footer text to:

```swift
                    Text("This model writes summaries, titles and vocabulary after a recording ends. Live translation always uses the fast 0.8B model so it stays responsive and cool while recording.")
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Loqi/Features/Settings/SettingsView.swift
git commit -m "docs: clarify model picker selects the summary tier"
```

---

### Task 18: Full regression pass

**Files:** none (verification only).

- [ ] **Step 1: Run the whole suite**

Run: `xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16' -jobs 1`
Expected: ALL TESTS PASS. Pay attention to `LLMServiceTests`, `ModelCatalogTests`, `SummaryEngineTests`, `ChunkNoteQueueTests`, `OnboardingCatalogTests`, plus the four new suites.

- [ ] **Step 2: Device smoke test (the original bug)**

Manual (8 GB device, SenseVoice ASR + translation on): record several sentences. Expected: **no** "AI features paused (low memory)" after sentence 1 (0.8B fits beside SenseVoice); refinement upgrades drafts during silence gaps. Then enable Reduce heat + screen-off and confirm a long session stays out of `.serious` longer (watch Diagnostics "Thermal changes" and "Heat driver"). Stop and summarize: confirm the summary runs on 2B (Diagnostics "Model state: Ready", quality unchanged).

- [ ] **Step 3: Commit (if any fixups were needed)**

```bash
git add -A
git commit -m "test: full regression pass for heat + dual-model changes"
```

> **Phase 2 skipped (YAGNI):** no per-session live-model override (live is always 0.8B; revisit only if a user with an 8 GB device and no heat issue asks to run 2B live); no second `LLMService` instance (one instance + `setModel` keeps peak memory = max, not sum).

---

## Self-Review

**Spec coverage** (each item the user asked to consolidate):
- 0.8B addition → Phase 2 (Tasks 12–17): roles, live-load, summary-load, summarize-yields-to-recording, onboarding both-downloads, copy.
- Heat monitoring feature → Phase 0 (Tasks 1–5): SessionHeatStats, LLM + SenseVoice active-time accumulators, thermal transition log, Diagnostics readout.
- "Slow SenseVoice re-decode" → Tasks 6–7 (`partialInterval`).
- "Fewer SenseVoice threads" → Tasks 6–7 (`decoderThreads`).
- "Min-length / thermal-aware refinement gate" (combined the min-length and proactive-throttle ideas) → Tasks 8–9 (`RefinementGate`).
- "Let the screen turn off" → Task 10.
- "Reduce heat" user switch tying the knobs together → Task 11.
- Apple-ASR real-time path + ANE provider → explicitly deferred (Phase 1 skipped note) — investigation-gated, not blind work.

**Placeholder scan:** no "TBD"/"handle edge cases"/"similar to Task N" — every code step shows code; every test step shows assertions; every run step shows the exact command + expected result.

**Type consistency:** `liveModel`/`summaryModel`/`onboardingLLMBytes` (Task 12) are consumed with those exact names in Tasks 13, 15, 16. `RefinementGate.shouldRefine(textLength:forced:thermalState:reduceHeat:)` defined in Task 8, called identically in Task 9. `perf.reduceHeat` / `display.keepScreenOn` keys consistent across Tasks 5–11. `resetHeatStats()` / `generateActiveSeconds` / `decodeActiveSeconds` defined in Tasks 2–3, consumed in Task 5. `ThermalMonitor.Transition` / `appendTransition` consistent between Task 4 and Task 5.

**Known follow-ups to verify during execution (not blockers):**
- Task 3/5: confirm the exact SenseVoice decode call sites and that the active engine is reachable via `engines.values` (Apple engine returns 0 decode seconds — correct).
- Task 14: confirm `resumeLLMJobs` clears `.pausedForBackground` before re-running `summarize` (it does, `:279-281`) so the recording-suspended summary restarts cleanly.
- Task 16: match `OnboardingDownloadModel.Item.Status` enum cases exactly (`:14`).
