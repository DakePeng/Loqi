# Meaningful Summaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Loqi's post-session summaries meaningful even when the audio is garbled and/or a photo is the only clean signal — first by stopping the pipeline from amplifying noise on the current model (Phase 1), then by making a stronger text model (Bonsai-8B) selectable behind a flag (Phase 2).

**Architecture:** On-device map→reduce. Phase 1 changes are prompt + deterministic-render edits that keep noise out of the summary, no new dependencies. Phase 2 adds `prism-ml/Bonsai-8B-mlx-1bit` as a selectable summary/map model behind a UserDefaults flag, gated on a hard feasibility spike (it ships via a custom mlx-swift fork), keeping Qwen3.5-VL for photo description.

**Tech Stack:** Swift, Swift Testing (`@Test`/`#expect`), MLX / mlx-swift-lm 3.31.3, Qwen3.5 (2B summary / 0.8B live, both VLM-capable).

## Global Constraints

- **Test runner gotcha (verbatim, applies to every test step):** `xcodebuild test ... -only-testing:LoqiTests/SummaryEngineTests/<funcName>` matches **zero** Swift Testing tests and **vacuously passes**. ALWAYS run the whole suite: `-only-testing:LoqiTests/SummaryEngineTests`. Destination: `platform=iOS Simulator,name=iPhone 17 Pro`.
- **Never fabricate.** Summaries must contain only what was spoken or shown. No invented goals, to-dos, decisions, or "next steps."
- **The transcript is sacred.** Never modify the stored/displayed transcript text. Map-phase input may be cleaned in-memory only.
- **Multilingual.** All prompt/heading changes must hold for zh/ja/ko/en. Test fixtures use Chinese.
- **Map phase is style-independent and cached** (`chunkNotes`); changing the map prompt only affects newly-mapped chunks, which is fine.
- **Phase 2 is flag-gated and OFF by default.** Use a **2-bit** Bonsai (`prism-ml/Ternary-Bonsai-8B-mlx-2bit`, 8.19B ternary stored as MLX 2-bit, ~2.30 GB, text-only, Qwen3-8B arch) — it loads on **stock mlx-swift, no fork**. Do NOT use `Bonsai-8B-mlx-1bit`: stock MLX `quantize` supports only 2/3/4/5/6/8 bits and **fatal-crashes on 1-bit** (uncatchable). 4B-2bit (`prism-ml/Ternary-Bonsai-4B-mlx-2bit`, ~1.13 GB) is the lighter alt.

---

## Already landed (context — do NOT redo)

These are committed/working on `codex/summary-writing-quality` and have tests:
- **A1** `SummaryEngine.renderReducedSummary` stitches a dropped populated section instead of discarding the whole synthesis; helper `SummaryRecordReducer.sectionLines`.
- **A2** `reduceSummaryPrompt` has a "lead with the most important … drop minor details" instruction.
- **A3** `chunkRecordPrompt` keeps a grounded reason/qualifier clause; "one line" instead of "short".
- **B1** `SummaryEngine.hasSpokenSubstance(_:)` — `reduce()` renders deterministically when notes carry no non-photo, non-topic record (stops photo-only fabrication).
- **B2** `reduceSummaryPrompt`: "Photos are reference context only … never turn a photo into a key point, decision, to-do, or next step." Memo to-do hint = "to-do that was actually mentioned".

Baseline: `LoqiTests/SummaryEngineTests` = **37/37 green**.

---

## File Structure

**Phase 1 (current model):**
- `Loqi/Pipeline/Summary/SummaryEngine.swift` — `SummaryRecordReducer.records(from:)` (drop fallback-stub topics); new `SummaryEngine.cleanMapInput(_:)` + its use in `makeNotes`.
- `Loqi/Pipeline/Refinement/PromptBuilder.swift` — `chunkRecordPrompt` (skip-unintelligible instruction).
- `LoqiTests/SummaryEngineTests.swift` — tests for all three.

**Phase 2 (Bonsai behind flag):**
- `Loqi/Support/ModelCatalog.swift` — `bonsai8b` option, `bonsaiEnabled` flag, `all` → computed.
- `Loqi/Pipeline/Summary/SummaryJobCenter.swift` — vision-routing for the photo back-fill when the summary model is text-only.
- `Loqi/Features/Settings/SettingsView.swift` — picker already iterates `ModelCatalog.all`; verify the experimental row + a flag toggle.
- `LoqiTests/` — `ModelCatalogTests.swift` (new) for the flag/option logic.
- **Spike only (throwaway):** SPM `Package.swift`/project dependency on the prism-ml mlx-swift fork.

---

# PHASE 1 — Transcript-quality lever (current Qwen model)

Root cause from the calibration example: garbled multilingual ASR yields little real content; fallback "stub" chunks (headline = raw opening words) leak into the outline as fake topics, and the reduce model pads the template. Phase 1 keeps noise out and lets honest-thin summaries stand.

### Task 1: Drop fallback-stub topics from rendering

A failed chunk becomes a `ChunkNote` with `isFallback == true` and a headline of raw opening words (`makeNotes`, `SummaryEngine.swift:285-297`). `SummaryRecordReducer.records(from:)` turns that headline into a `.topic` record, so noise chunks seed fake outline topics. Drop them.

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryEngine.swift` (`SummaryRecordReducer.records(from note:)`, ~`702-736`)
- Test: `LoqiTests/SummaryEngineTests.swift`

**Interfaces:**
- Consumes: `SessionRecord.ChunkNote.isFallback: Bool?`, `SessionRecord.SummaryRecord`.
- Produces: no signature change to `static func records(from note:fallbackIndex:) -> [Record]`; behavior: a fallback note contributes `[]`.

- [ ] **Step 1: Write the failing test**

Add to `LoqiTests/SummaryEngineTests.swift`:

```swift
@Test func fallbackStubNotesContributeNoTopicRecord() {
    let timestamp = Date(timeIntervalSince1970: 1_000_000)
    let stub = SessionRecord.ChunkNote(
        headline: "应该是在的",          // raw opening words of a garbled chunk
        startedAt: timestamp,
        isFallback: true)
    let real = SessionRecord.ChunkNote(
        headline: "预算讨论",
        startedAt: timestamp,
        decisions: ["六月发布"])

    #expect(SummaryRecordReducer.records(from: stub).isEmpty)
    #expect(SummaryRecordReducer.records(from: real).contains { $0.kind == .topic })
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/SummaryEngineTests 2>&1 | grep -E "✘ Test|Test run with"`
Expected: FAIL — the stub currently yields one `.topic` record.

- [ ] **Step 3: Guard the topic append on `isFallback`**

In `SummaryRecordReducer.records(from note:)`, replace the unconditional topic append:

```swift
        // A fallback stub's headline is just the chunk's raw opening words —
        // noise, not a topic. Emitting it seeds fake outline entries.
        if note.isFallback != true {
            append(.topic, note.headline, offset: 0)
        }
```

(Leave the `facts`/`decisions`/`actions`/`terms` loops unchanged — a fallback note has none, so it now contributes nothing.)

- [ ] **Step 4: Run the suite to verify it passes**

Run: `xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/SummaryEngineTests 2>&1 | grep -E "✘ Test|Test run with"`
Expected: `Test run with 38 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/Summary/SummaryEngine.swift LoqiTests/SummaryEngineTests.swift
git commit -m "fix: drop fallback-stub headlines from summary topics"
```

### Task 2: Map prompt — skip unintelligible spans

Tell the extractor to skip garbled audio rather than invent a topic from it.

**Files:**
- Modify: `Loqi/Pipeline/Refinement/PromptBuilder.swift` (`chunkRecordPrompt`, system string ~`256-282`)
- Test: `LoqiTests/SummaryEngineTests.swift`

**Interfaces:**
- Consumes/Produces: `chunkRecordPrompt(chunkID:timeRange:contextOnly:target:vocabulary:in:) -> (system:String, user:String)` — unchanged signature; system gains one sentence.

- [ ] **Step 1: Write the failing test**

Add to `LoqiTests/SummaryEngineTests.swift`:

```swift
@Test func chunkRecordPromptSkipsUnintelligibleSpans() {
    let prompt = PromptBuilder().chunkRecordPrompt(
        chunkID: "c001",
        timeRange: "00:00-02:00",
        contextOnly: "",
        target: "m001\t什么消行 啊 不知道啊",
        in: .chinese)
    #expect(prompt.system.contains("unintelligible"))
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/SummaryEngineTests 2>&1 | grep -E "✘ Test|Test run with"`
Expected: FAIL — string not present.

- [ ] **Step 3: Add the instruction**

In `chunkRecordPrompt`, append to the system prompt right after `Skip empty \ncategories.`:

```swift
        Maximum records: 1 T, 3 P, 3 D, 3 A, 2 Q, 2 R, 3 E, 3 J. Skip empty \
        categories. If a span is garbled or unintelligible, skip it; do not \
        invent a topic_title or records from noise.
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/SummaryEngineTests 2>&1 | grep -E "✘ Test|Test run with"`
Expected: `Test run with 39 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Loqi/Pipeline/Refinement/PromptBuilder.swift LoqiTests/SummaryEngineTests.swift
git commit -m "feat: tell map phase to skip unintelligible spans"
```

### Task 3 (experimental — measure, then keep or revert): Map-input filler/stutter collapse

Garbled ASR repeats syllables ("有有有", "我我"). Collapse obvious stutters **for the map input only** — never the stored transcript — so extraction sees cleaner text.

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryEngine.swift` (new `static func cleanMapInput(_:)`; apply in `makeNotes` where `entry.sourceText` builds the chunk `text`, ~`244-247`)
- Test: `LoqiTests/SummaryEngineTests.swift`

**Interfaces:**
- Produces: `static func cleanMapInput(_ text: String) -> String` — collapses runs of one identical character repeated 3+ times to a single instance; trims. Used only to build map-phase prompt input.

- [ ] **Step 1: Write the failing test**

```swift
@Test func cleanMapInputCollapsesStutters() {
    #expect(SummaryEngine.cleanMapInput("有有有没有") == "有没有")
    #expect(SummaryEngine.cleanMapInput("预算定为42万") == "预算定为42万") // untouched
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/SummaryEngineTests 2>&1 | grep -E "✘ Test|Test run with"`
Expected: FAIL — `cleanMapInput` not defined.

- [ ] **Step 3: Implement the helper**

Add to `struct SummaryEngine`:

```swift
    /// Map-input hygiene: collapse a single character repeated 3+ times in a
    /// row to one. ASR stutters ("有有有") hurt extraction; legit doubles
    /// ("谢谢") are left alone. Applies to map prompt input ONLY — the stored
    /// transcript is never altered.
    // ponytail: 3-repeat threshold heuristic; raise/lower if it clips real text.
    static func cleanMapInput(_ text: String) -> String {
        var result = ""
        var last: Character?
        var run = 0
        for ch in text {
            if ch == last {
                run += 1
                if run >= 3 { continue }   // drop the 3rd+ repeat
            } else {
                last = ch
                run = 1
            }
            result.append(ch)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

- [ ] **Step 4: Apply it in `makeNotes`**

In `makeNotes`, change the chunk-text build to clean each entry's source:

```swift
            let text = zip(sourceIDs, chunk).map { id, entry in
                let speaker = speakerLabel(entry.speaker).map { "[\($0)] " } ?? ""
                return "\(id)\t\(speaker)\(Self.cleanMapInput(entry.sourceText))"
            }.joined(separator: "\n")
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/SummaryEngineTests 2>&1 | grep -E "✘ Test|Test run with"`
Expected: `Test run with 40 tests in 1 suite passed`.

- [ ] **Step 6: Measure before keeping**

Re-summarize the calibration session (the garbled "应该是在的" one) and a clean session. Keep this task only if the garbled summary improves with no regression on the clean one; otherwise `git revert` this commit. Record the call in the PR description.

- [ ] **Step 7: Commit**

```bash
git add Loqi/Pipeline/Summary/SummaryEngine.swift LoqiTests/SummaryEngineTests.swift
git commit -m "experiment: collapse map-input stutters for cleaner extraction"
```

---

# PHASE 2 — Bonsai-8B behind a flag

> **GATE (simplified — no fork):** the 2-bit Bonsai loads on the existing mlx-swift, so there is no dependency migration. Task 0 is now a device load+quality check, not a fork spike. If it fails, Phase 1 already delivers the meaningful-summary win.

### Task 0: Device load + quality check (on real hardware)

**Goal:** prove `prism-ml/Ternary-Bonsai-8B-mlx-2bit` loads via stock mlx-swift and generates a coherent Chinese summary.

- [ ] **Step 1:** Enable the Settings toggle (Task 3), pick Bonsai, download (~2.30 GB).
- [ ] **Step 2:** Evaluate against three pass criteria. ALL must hold:
  1. **Loads:** no crash. (1-bit fatal-crashed on the bits check; 2-bit must pass it.)
  2. **Not gibberish:** ternary-2bit packing on stock MLX is the open risk — confirm output isn't degenerate (`!PromptBuilder.hasDegenerateRepetition`; if it is, the reduce already falls back deterministically, no crash).
  3. **CJK quality + memory:** Chinese summary is coherent and at least as good as Qwen 2B on the calibration session; record the memory peak and set `bonsai8b.requiredHeadroom` accordingly (currently a 3.0 GB estimate).
- [ ] **Step 3:** Go/no-go note. If gibberish or worse than Qwen, keep the flag off by default; otherwise proceed to A/B (Task 4).

### Task 1: Add Bonsai as a flag-gated `ModelOption`

**Files:**
- Modify: `Loqi/Support/ModelCatalog.swift`
- Test: `LoqiTests/ModelCatalogTests.swift` (create)

**Interfaces:**
- Consumes: `ModelOption(id:displayName:requiredHeadroom:downloadBytes:supportsVision:)`.
- Produces: `ModelCatalog.bonsai8b: ModelOption`; `ModelCatalog.bonsaiEnabled: Bool`; `ModelCatalog.all` becomes a computed `[ModelOption]` that includes `bonsai8b` only when `bonsaiEnabled`.

- [ ] **Step 1: Write the failing test**

Create `LoqiTests/ModelCatalogTests.swift`:

```swift
import Testing
@testable import Loqi

struct ModelCatalogTests {
    @Test func bonsaiAppearsOnlyWhenFlagEnabled() {
        let defaults = UserDefaults(suiteName: "modelcatalog.test")!
        defaults.removePersistentDomain(forName: "modelcatalog.test")

        defaults.set(false, forKey: "model.bonsaiEnabled")
        #expect(!ModelCatalog.all(defaults: defaults).contains { $0.id == ModelCatalog.bonsai8b.id })

        defaults.set(true, forKey: "model.bonsaiEnabled")
        let on = ModelCatalog.all(defaults: defaults)
        #expect(on.contains { $0.id == ModelCatalog.bonsai8b.id })
        #expect(ModelCatalog.bonsai8b.supportsVision == false)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/ModelCatalogTests 2>&1 | grep -E "✘ Test|Test run with"`
Expected: FAIL — `bonsai8b` / `all(defaults:)` not defined.

- [ ] **Step 3: Implement in `ModelCatalog`**

Replace `static let all = [qwen35_2b, qwen35_0_8b]` with:

```swift
    /// Experimental text-only 8B at 1-bit (~1.30 GB). No vision tower — photo
    /// description routes to a vision model (see SummaryJobCenter). Gated OFF
    /// by default behind `model.bonsaiEnabled`. requiredHeadroom from spike.
    static let bonsai8b = ModelOption(
        id: "prism-ml/Ternary-Bonsai-8B-mlx-2bit",   // 2-bit loads on stock mlx-swift; 1-bit crashes
        displayName: "Bonsai 8B (ternary 2-bit) — experimental",
        requiredHeadroom: 3_000_000_000,   // ~2.3 GB weights + cache; tune on device
        downloadBytes: 2_300_000_000,
        supportsVision: false)

    static func bonsaiEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "model.bonsaiEnabled")
    }

    static func all(defaults: UserDefaults = .standard) -> [ModelOption] {
        bonsaiEnabled(defaults) ? [qwen35_2b, qwen35_0_8b, bonsai8b] : [qwen35_2b, qwen35_0_8b]
    }
```

Update `option(for:)` and `normalizeStoredSelection` to use `all()`:

```swift
    static func option(for id: String) -> ModelOption {
        all().first { $0.id == id } ?? `default`
    }
```

and in `normalizeStoredSelection`, change `!all.contains` to `!all(defaults: defaults).contains`.

- [ ] **Step 4: Run it to verify it passes**

Run: `xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/ModelCatalogTests 2>&1 | grep -E "✘ Test|Test run with"`
Expected: PASS.

- [ ] **Step 5: Fix any `ModelCatalog.all` references**

Run: `grep -rn "ModelCatalog.all\b" Loqi/` and change call sites (e.g. `SettingsView.swift:168` `ForEach(ModelCatalog.all)`) to `ModelCatalog.all()`. Re-run the suite above.

- [ ] **Step 6: Commit**

```bash
git add Loqi/Support/ModelCatalog.swift Loqi/Features/Settings/SettingsView.swift LoqiTests/ModelCatalogTests.swift
git commit -m "feat: flag-gated Bonsai-8B summary model option"
```

### Task 2: Route photo description to a vision model when the summary model is text-only

Today the summary-time photo back-fill is guarded `if await llm.model.supportsVision` (`SummaryJobCenter.swift:908`). With text-only Bonsai as the summary model, that guard skips, so photos in short sessions (where the live VLM queue never warmed) get **no** `vlmDescription`. Route description through the vision-capable live model instead of skipping.

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryJobCenter.swift` (the back-fill loop, ~`904-926`)
- Verify: `Loqi/Pipeline/Vision/AttachmentDescribeQueue.swift` (live path already uses the warm vision model — no change expected)

**Interfaces:**
- Consumes: `LLMService.setModel(_:)`, `LLMService.model`, `ModelCatalog.liveModel` (0.8B, `supportsVision == true`).

- [ ] **Step 1: Confirm the seam**

Read `AttachmentDescribeQueue.swift` and `SummaryJobCenter.swift:880-935`. Confirm: (a) the live queue describes photos with whatever model is warm during recording (the 0.8B VLM), and (b) the only summary-time vision use is this back-fill loop. Note the loaded-model order: the summary model is loaded just before this loop.

- [ ] **Step 2: Replace the skip-guard with a vision-model route**

Change the back-fill so a text-only summary model describes photos via the live VLM, then restores the summary model for reduce:

```swift
        // Photos need a vision model. The summary model may be text-only
        // (Bonsai); describe with the live VLM, then restore for reduce.
        // ponytail: a model swap per summarize when text-only + undescribed
        // photos exist — acceptable for an experimental tier.
        let needsDescribe = attachments.contains { $0.vlmDescription == nil }
        let summaryModel = await llm.model
        if needsDescribe, !summaryModel.supportsVision {
            await llm.setModel(ModelCatalog.liveModel)
        }
        if await llm.model.supportsVision {
            let language = SummaryEngine.summaryLanguage(for: record)
            let prompts = PromptBuilder()
            for index in attachments.indices where attachments[index].vlmDescription == nil {
                let url = SessionArchive.attachmentURL(fileName: attachments[index].fileName)
                let prompt = prompts.imageDescriptionPrompt(
                    in: language,
                    context: transcriptContext(around: attachments[index], in: record))
                guard let raw = try? await llm.describeImage(
                          at: url, system: prompt.system, user: prompt.user)
                else { continue }
                let text = prompts.plainDescription(raw)
                guard !text.isEmpty, !PromptBuilder.hasDegenerateRepetition(text)
                else { continue }
                attachments[index].vlmDescription = text
                attachments[index].summaryRecords = nil
                changed = true
            }
        }
        if await llm.model.id != summaryModel.id {
            await llm.setModel(summaryModel)
        }
```

- [ ] **Step 3: Build + smoke test**

Run the full app test suite: `xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests 2>&1 | grep -E "✘ Test|TEST (SUCCEEDED|FAILED)"`
Expected: `TEST SUCCEEDED` (no behavioral test exists for this swap; it's covered by Task 4 manual A/B).

- [ ] **Step 4: Commit**

```bash
git add Loqi/Pipeline/Summary/SummaryJobCenter.swift
git commit -m "fix: describe photos via vision model when summary model is text-only"
```

### Task 3: Surface the experimental toggle in Settings

The picker already iterates `ModelCatalog.all()`, so Bonsai shows once the flag is on. Add a developer toggle to set the flag.

**Files:**
- Modify: `Loqi/Features/Settings/SettingsView.swift` (near the summary-model picker, ~`166-196`)

- [ ] **Step 1: Add the flag binding + toggle**

Add an `@AppStorage("model.bonsaiEnabled") private var bonsaiEnabled = false` to `SettingsView`, and a `Toggle` in the AI section above the summary-model picker:

```swift
                        Toggle("Experimental: Bonsai 8B summary model", isOn: $bonsaiEnabled)
                            .onChange(of: bonsaiEnabled) {
                                if !bonsaiEnabled, modelID == ModelCatalog.bonsai8b.id {
                                    modelID = ModelCatalog.default.id
                                }
                            }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Loqi/Features/Settings/SettingsView.swift
git commit -m "feat: settings toggle for experimental Bonsai summary model"
```

### Task 4: A/B on a real session (manual verification)

- [ ] **Step 1:** On device: Settings → enable the Bonsai toggle → pick Bonsai → download.
- [ ] **Step 2:** Re-summarize the calibration session (garbled "应该是在的" + horse photo) on Qwen 2B, then on Bonsai 8B.
- [ ] **Step 3:** Compare: does Bonsai extract more meaningful non-photo content from the garbled transcript? Is the photo still folded in (not fabricated into a plan)? Is the photo still described (Task 2 working)?
- [ ] **Step 4:** Record findings. If Bonsai wins clearly, plan a follow-up to promote it from experimental; otherwise keep the flag off by default and document.

---

## Self-Review

- **Spec coverage:** "Both, phased" → Phase 1 (transcript-quality on current model: Tasks 1-3) + Phase 2 (Bonsai behind flag: Tasks 0-4). Covered.
- **Placeholder scan:** The only `TODO` is `requiredHeadroom` in Task 1, deliberately filled by the Task 0 spike measurement — flagged as such, not a silent placeholder.
- **Type consistency:** `ModelCatalog.all` becomes `all(defaults:)` everywhere (Task 1 Step 5 fixes call sites incl. `SettingsView`). `cleanMapInput`, `hasSpokenSubstance`, `sectionLines` names match their definitions. `bonsai8b.supportsVision == false` is consistent with the Task 2 vision route.
- **Gotcha baked in:** every Swift-test step runs the whole `-only-testing:LoqiTests/SummaryEngineTests` suite (per-func filters vacuously pass).

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-20-meaningful-summaries.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
