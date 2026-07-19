# LFM2.5-230M Live-Refine Candidate Implementation Plan

> **Superseded 2026-07-04.** Tasks 1–4 landed, but device testing showed the 230M cannot do stable structured output, and the live architecture was redesigned on this branch: the live LLM (0.8B default, LFM2.5 experimental) now does *monolingual transcript cleanup* only — Apple's Translation framework is the sole translator; the old LLM-refines-the-translation path is deleted. LFM2.5 never enters the summary lineup; the summary picker is Qwen 2B + Bonsai (promoted to standard). Live notes defer to post-session mapping while LFM2.5 is live. Task 5's device checklist below is superseded by the redesign's own verification list (see the branch's later commits / PR #13).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Re-validated 2026-07-04** against main @ `bccf6117` (post-PR #12 background-model-downloads merge): every "Find this block" snippet still matches verbatim; mlx-swift-lm still pinned at 3.31.3; only the CaptionPipeline call-site line anchor moved (1598→1656).

**Goal:** Add `LiquidAI/LFM2.5-230M-MLX-4bit` as an opt-in, off-by-default alternative to the fixed Qwen3.5 0.8B model for the *live-refine* role only (translation refinement + live notes during recording) — same settings-gated experimental pattern already used for the Bonsai 8B summary tier.

**Architecture:** `ModelCatalog.liveModel` (Qwen3.5 0.8B, vision-capable) currently serves two roles on the single shared `LLMService` actor: (a) live text refinement (`RefinementQueue`, driven from `CaptionPipeline.loadLLMIfAllowed()`) and (b) live/post-session photo description (`AttachmentDescribeQueue`, `SummaryJobCenter`'s vision back-fill). LFM2.5-230M is text-only, so it can only take over role (a). This plan introduces a new resolver, `ModelCatalog.liveRefineModel()`, that role (a) calls instead of `liveModel` directly; `liveModel` itself is untouched and keeps serving role (b) exactly as today. When the experimental flag is on and a photo is attached mid-recording, `AttachmentDescribeQueue` already treats any `describeImage` failure as best-effort (falls back to OCR-only) — `LLMService.describeImage` throws `.visionUnsupported` immediately when the resident model lacks vision, so this is a clean, already-handled degradation, not a new failure mode to build.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`import Testing`, `@Test`/`#expect`), MLX / mlx-swift-lm 3.31.3 (confirmed `LFM2.swift` architecture support at the pinned revision — `LiquidAI/LFM2.5-230M-MLX-4bit`'s `config.json` reports `"model_type": "lfm2"`, no vision config), Xcode String Catalog (`Localizable.xcstrings`) for zh-Hans/ja. Build/test via `xcodebuild` against the `Loqi` scheme.

## Global Constraints

- **This plan intentionally revisits a prior constraint.** `docs/superpowers/plans/2026-06-20-dual-model-settings-onboarding.md` states "Never expose a picker that changes the *live* model" — that plan only ever considered the fixed Qwen 0.8B tier. This plan adds an explicit, off-by-default experimental override for the live-refine role specifically (not the vision role), at the user's request.
- **`ModelCatalog.liveModel` (`mlx-community/Qwen3.5-0.8B-4bit`) never changes.** It stays the always-available vision-capable fallback for `AttachmentDescribeQueue` and `SummaryJobCenter`'s vision back-fill. Do not repoint it.
- **The new candidate never enters the summary-role lineup.** `ModelCatalog.availableModels(defaults:)` / the Settings "Summary model" picker must never list `lfm2_5_230m` — it is a live-refine-only candidate, gated by its own flag (`model.liveRefineLFM2Enabled`), independent of `model.bonsaiEnabled`. *(Superseded 2026-07-04 at the user's request: the same flag now also lists LFM2.5 in the summary lineup, Bonsai-style, for A/B against the Qwen tiers.)*
- **License:** LFM Open License v1.0 (LiquidAI's own repo ships `LICENSE`) — free for commercial use under $10M annual revenue, no restriction relevant to an OSS project. No runtime license-gate needed; this is a due-diligence note, not a code requirement.
- **Localization targets zh-Hans and ja only** (verified existing catalog langs). Every new user-facing `String(localized:)` / SwiftUI `Text` needs zh-Hans + ja entries. Model names (`"Qwen3.5 0.8B"`, `"Liquid LFM2.5 230M"`) are proper nouns and are not localized, matching existing precedent.
- **MLX never runs in the iOS Simulator** (`LLMService.swift:19`: "this never runs in the simulator"). Unit tests cover pure `ModelCatalog` logic only; actual model load/generate correctness for `lfm2_5_230m` requires a real device pass (Task 5).
- **Build command:** `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
- **Test runner gotcha:** `xcodebuild test ... -only-testing:LoqiTests/ModelCatalogTests/<funcName>` matches zero Swift Testing tests and vacuously passes. Always run the whole suite class: `-only-testing:LoqiTests/ModelCatalogTests`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Loqi/Support/ModelCatalog.swift` | LLM catalog + role resolution | Add `lfm2_5_230m` `ModelOption`, `liveRefineLFM2Enabled(_:)` flag, `liveRefineModel(_:)` resolver |
| `Loqi/Support/CaptionPipeline.swift` | Live recording pipeline | `loadLLMIfAllowed()` calls `ModelCatalog.liveRefineModel()` instead of `ModelCatalog.liveModel` |
| `Loqi/Features/Settings/SettingsView.swift` | Settings "On-device AI" section | New experimental toggle; "Live model" row/download becomes dynamic; footer copy updated |
| `Loqi/Localizable.xcstrings` | String catalog | zh-Hans + ja for the new toggle label and updated footer |
| `LoqiTests/ModelCatalogTests.swift` | Catalog guards | New tests for the candidate, flag, and resolver |

---

## Task 1: Add the LFM2.5 candidate and live-refine resolver to ModelCatalog

**Files:**
- Modify: `Loqi/Support/ModelCatalog.swift:113-118`
- Test: `LoqiTests/ModelCatalogTests.swift`

**Interfaces:**
- Consumes: existing `ModelOption` struct (`Loqi/Support/ModelCatalog.swift:56-70`), existing `ModelCatalog.liveModel` constant.
- Produces: `ModelCatalog.lfm2_5_230m: ModelOption`, `ModelCatalog.liveRefineLFM2Enabled(_ defaults: UserDefaults = .standard) -> Bool`, `ModelCatalog.liveRefineModel(_ defaults: UserDefaults = .standard) -> ModelOption`. Tasks 2 and 3 call `ModelCatalog.liveRefineModel()`.

- [x] **Step 1: Write the failing tests**

Add to `LoqiTests/ModelCatalogTests.swift`, right after the existing `summaryModelFollowsUserPick` test (before the closing `}` of the `struct ModelCatalogTests`):

```swift
    @Test func lfm2CandidateIsTextOnlyAndLighterThanLiveModel() {
        #expect(ModelCatalog.lfm2_5_230m.supportsVision == false)
        #expect(ModelCatalog.lfm2_5_230m.requiredHeadroom
            < ModelCatalog.liveModel.requiredHeadroom)
    }

    @Test func lfm2CandidateNeverAppearsInSummaryLineup() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "model.liveRefineLFM2Enabled")
        defaults.set(true, forKey: "model.bonsaiEnabled")
        #expect(!ModelCatalog.availableModels(defaults: defaults)
            .contains { $0.id == ModelCatalog.lfm2_5_230m.id })
    }

    @Test func liveRefineModelDefaultsToLiveModelTier() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ModelCatalog.liveRefineModel(defaults).id == ModelCatalog.liveModel.id)
    }

    @Test func liveRefineModelSwapsToLFM2WhenFlagEnabled() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "model.liveRefineLFM2Enabled")
        #expect(ModelCatalog.liveRefineModel(defaults).id == ModelCatalog.lfm2_5_230m.id)
        // liveModel itself must stay the vision-capable fixed tier.
        #expect(ModelCatalog.liveModel.id == ModelCatalog.qwen35_0_8b.id)
    }
```

- [x] **Step 2: Run the tests to verify they fail to compile**

Run:
```bash
xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/ModelCatalogTests 2>&1 | grep -E "error:|Test run with"
```
Expected: compiler errors like `error: type 'ModelCatalog' has no member 'lfm2_5_230m'` (and `liveRefineModel`). This confirms the tests exercise code that doesn't exist yet.

- [x] **Step 3: Implement in ModelCatalog.swift**

Find this block (`Loqi/Support/ModelCatalog.swift:113-118`):

```swift
    static let `default` = qwen35_2b
    /// Model that runs *during* a live recording: the fast, low-memory,
    /// low-heat tier. Always 0.8B regardless of the user's quality pick, so
    /// translation refinement and live notes never load the heavy VLM beside
    /// SenseVoice's in-process ONNX.
    static let liveModel = qwen35_0_8b
```

Replace it with:

```swift
    static let `default` = qwen35_2b
    /// Model that runs *during* a live recording for photo description:
    /// the fast, low-memory, low-heat vision-capable tier. Always 0.8B
    /// regardless of the user's quality pick, so live photo description and
    /// the post-session vision back-fill (see SummaryJobCenter) never load
    /// the heavy VLM beside SenseVoice's in-process ONNX. This never changes
    /// — `liveRefineModel` below is the swappable one.
    static let liveModel = qwen35_0_8b

    /// Experimental text-only 230M live-refine candidate (Liquid AI's
    /// LFM2.5), first-party MLX port — mlx-swift-lm 3.31.3 already ships
    /// `LFM2.swift`, so no fork is needed (config.json model_type "lfm2").
    /// No vision tower: while active, a photo attached live falls back to
    /// OCR-only (AttachmentDescribeQueue already treats every
    /// `describeImage` failure as best-effort). Hidden behind
    /// `model.liveRefineLFM2Enabled` (off by default).
    static let lfm2_5_230m = ModelOption(
        id: "LiquidAI/LFM2.5-230M-MLX-4bit",
        displayName: "Liquid LFM2.5 230M (live refine) — experimental",
        requiredHeadroom: 300_000_000,   // ~151 MB weights; tune on device
        downloadBytes: 151_000_000,
        supportsVision: false)

    /// Whether the experimental LFM2.5 live-refine tier replaces the fixed
    /// 0.8B during recording. Off by default.
    static func liveRefineLFM2Enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "model.liveRefineLFM2Enabled")
    }

    /// Model `CaptionPipeline` loads during recording for translation
    /// refinement and live notes (text-only path; never touches vision).
    /// Defaults to `liveModel`; swaps to the LFM2.5 candidate when the
    /// experimental flag is on.
    static func liveRefineModel(_ defaults: UserDefaults = .standard) -> ModelOption {
        liveRefineLFM2Enabled(defaults) ? lfm2_5_230m : liveModel
    }
```

- [x] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests/ModelCatalogTests 2>&1 | grep -E "✘ Test|Test run with"
```
Expected: no `✘ Test` lines, and `Test run with N tests passed` (N = the prior count + 4).

- [x] **Step 5: Commit**

```bash
git add Loqi/Support/ModelCatalog.swift LoqiTests/ModelCatalogTests.swift
git commit -m "feat: add LFM2.5-230M as an experimental live-refine candidate"
```

---

## Task 2: Wire the resolver into CaptionPipeline's live loader

**Files:**
- Modify: `Loqi/Support/CaptionPipeline.swift:1656-1657`

**Interfaces:**
- Consumes: `ModelCatalog.liveRefineModel() -> ModelOption` (Task 1).
- Produces: nothing new — `loadLLMIfAllowed()`'s behavior is unchanged when the flag is off (resolver returns `liveModel`, identical to today).

- [x] **Step 1: Swap the call site**

Find (`Loqi/Support/CaptionPipeline.swift:1656-1657`):

```swift
        Task { [llm] in
            await llm.setModel(ModelCatalog.liveModel)
```

Replace with:

```swift
        Task { [llm] in
            // ponytail: LFM2.5 has no vision tower, so a photo attached live
            // this session degrades to OCR-only while the experimental flag
            // is on — accepted, AttachmentDescribeQueue already treats every
            // describeImage failure as best-effort. Revisit if live photo
            // description quality regressions get reported.
            await llm.setModel(ModelCatalog.liveRefineModel())
```

- [x] **Step 2: Build**

Run:
```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 3: Run the full unit test suite as a regression check**

Run:
```bash
xcodebuild test -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LoqiTests 2>&1 | grep -E "✘ Test|TEST (SUCCEEDED|FAILED)"
```
Expected: no `✘ Test` lines, `TEST SUCCEEDED`.

- [x] **Step 4: Commit**

```bash
git add Loqi/Support/CaptionPipeline.swift
git commit -m "feat: route live refinement through ModelCatalog.liveRefineModel"
```

---

## Task 3: Settings UI — experimental toggle, dynamic live-model row, footer copy

**Files:**
- Modify: `Loqi/Features/Settings/SettingsView.swift:8` (new `@AppStorage`)
- Modify: `Loqi/Features/Settings/SettingsView.swift:158-186` (live-model row + new toggle)
- Modify: `Loqi/Features/Settings/SettingsView.swift:240` (footer copy)
- Modify: `Loqi/Features/Settings/SettingsView.swift:435` (`refreshStats()`)

**Interfaces:**
- Consumes: `ModelCatalog.liveRefineModel() -> ModelOption`, `ModelCatalog.liveRefineLFM2Enabled`/flag key `"model.liveRefineLFM2Enabled"` (Task 1); existing `startDownload(_:)`, `stopDownload()`, `downloadingModelID`, `liveDownloaded` (all unchanged in shape).
- Produces: nothing further downstream — this is the leaf UI surface.

- [x] **Step 1: Add the `@AppStorage` flag**

Find (`Loqi/Features/Settings/SettingsView.swift:8`):

```swift
    @AppStorage("model.bonsaiEnabled") private var bonsaiEnabled = false
```

Add directly below it:

```swift
    @AppStorage("model.bonsaiEnabled") private var bonsaiEnabled = false
    @AppStorage("model.liveRefineLFM2Enabled") private var liveRefineLFM2Enabled = false
```

- [x] **Step 2: Make the live-model row dynamic and add the experimental toggle**

Find (`Loqi/Features/Settings/SettingsView.swift:158-186`):

```swift
                    Group {
                        // Live tier — fixed 0.8B, runs during recording.
                        LabeledContent("Live model", value: "Qwen3.5 0.8B")
                        LabeledContent(
                            "Live model files",
                            value: liveDownloaded
                                ? localized("Downloaded")
                                : localized("Not downloaded"))
                        if !liveDownloaded {
                            if downloadingModelID == ModelCatalog.liveModel.id {
                                DownloadProgressRow(
                                    speedometer: llmSpeedometer, onStop: stopDownload)
                            } else {
                                Button("Download live model") {
                                    startDownload(ModelCatalog.liveModel)
                                }
                                .disabled(downloadingModelID != nil)
                            }
                        }

                        // Experimental: a stronger text-only model for the
                        // summary tier. Needs the 1-bit-kernel mlx-swift fork
                        // to actually load; off by default.
                        Toggle("Experimental: Bonsai 8B summary model", isOn: $bonsaiEnabled)
                            .onChange(of: bonsaiEnabled) {
                                if !bonsaiEnabled, modelID == ModelCatalog.bonsai8b.id {
                                    modelID = ModelCatalog.default.id
                                }
                            }
```

Replace with:

```swift
                    Group {
                        // Live tier — runs during recording. Fixed 0.8B
                        // unless the experimental toggle below is on.
                        LabeledContent(
                            "Live model",
                            value: liveRefineLFM2Enabled
                                ? "Liquid LFM2.5 230M" : "Qwen3.5 0.8B")
                        LabeledContent(
                            "Live model files",
                            value: liveDownloaded
                                ? localized("Downloaded")
                                : localized("Not downloaded"))
                        if !liveDownloaded {
                            if downloadingModelID == ModelCatalog.liveRefineModel().id {
                                DownloadProgressRow(
                                    speedometer: llmSpeedometer, onStop: stopDownload)
                            } else {
                                Button("Download live model") {
                                    startDownload(ModelCatalog.liveRefineModel())
                                }
                                .disabled(downloadingModelID != nil)
                            }
                        }

                        // Experimental: a smaller text-only model for the
                        // live-refine tier (translation refinement + live
                        // notes). No vision tower — photos attached live
                        // fall back to OCR-only while this is on. Off by
                        // default.
                        Toggle(
                            "Experimental: Liquid LFM2.5 live-refine model",
                            isOn: $liveRefineLFM2Enabled)
                            .onChange(of: liveRefineLFM2Enabled) {
                                Task { await refreshStats() }
                            }

                        // Experimental: a stronger text-only model for the
                        // summary tier. Needs the 1-bit-kernel mlx-swift fork
                        // to actually load; off by default.
                        Toggle("Experimental: Bonsai 8B summary model", isOn: $bonsaiEnabled)
                            .onChange(of: bonsaiEnabled) {
                                if !bonsaiEnabled, modelID == ModelCatalog.bonsai8b.id {
                                    modelID = ModelCatalog.default.id
                                }
                            }
```

- [x] **Step 3: Update `refreshStats()`'s download-state check**

Find (`Loqi/Features/Settings/SettingsView.swift:435`):

```swift
        liveDownloaded = LLMService.isDownloaded(model: ModelCatalog.liveModel)
```

Replace with:

```swift
        liveDownloaded = LLMService.isDownloaded(model: ModelCatalog.liveRefineModel())
```

- [x] **Step 4: Update the footer copy**

Find (`Loqi/Features/Settings/SettingsView.swift:240`):

```swift
                    Text("Live recording always uses the fast Qwen3.5 0.8B model so captions and live translation stay responsive and cool. After a recording, summaries, titles, vocabulary and chat use the summary model you pick above.")
```

Replace with:

```swift
                    Text("Live recording uses the fast Qwen3.5 0.8B model by default — or the experimental Liquid LFM2.5 above — so captions and live translation stay responsive and cool. Live photo description needs the 0.8B model, so photos attached while LFM2.5 is active keep their OCR text until the recording ends. After a recording, summaries, titles, vocabulary and chat use the summary model you pick above.")
```

- [x] **Step 5: Build**

Run:
```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 6: Commit**

```bash
git add Loqi/Features/Settings/SettingsView.swift
git commit -m "feat: add experimental Liquid LFM2.5 toggle to Settings live-model row"
```

---

## Task 4: Localize the new/changed strings (zh-Hans + ja)

**Files:**
- Modify: `Loqi/Localizable.xcstrings`

**Interfaces:**
- Consumes: the exact English source strings introduced/changed in Task 3 (must match `Text(...)` literals verbatim).
- Produces: zh-Hans + ja `stringUnit`s. No code consumes this.

- [x] **Step 1: Add the new keys with translations via a JSON script**

Run from the repo root:

```bash
python3 - <<'PY'
import json
path = "Loqi/Localizable.xcstrings"
cat = json.load(open(path))
entries = {
    "Experimental: Liquid LFM2.5 live-refine model": {
        "zh-Hans": "实验性：实时精炼使用 Liquid LFM2.5 模型",
        "ja": "実験的機能：ライブ精緻化にLiquid LFM2.5モデルを使用"},
    "Live recording uses the fast Qwen3.5 0.8B model by default — or the experimental Liquid LFM2.5 above — so captions and live translation stay responsive and cool. Live photo description needs the 0.8B model, so photos attached while LFM2.5 is active keep their OCR text until the recording ends. After a recording, summaries, titles, vocabulary and chat use the summary model you pick above.": {
        "zh-Hans": "录制时默认使用快速的 Qwen3.5 0.8B 模型（或上方的实验性 Liquid LFM2.5 模型），让字幕和实时翻译保持流畅、低发热。实时图片描述需要 0.8B 模型，因此在 LFM2.5 生效期间添加的照片会保留其文字识别结果，直到录制结束。录制结束后，总结、标题、生词和聊天会使用你在上方选择的总结模型。",
        "ja": "録音中はデフォルトで高速なQwen3.5 0.8Bモデル(または上の実験的なLiquid LFM2.5)を使用し、字幕とリアルタイム翻訳を快適かつ低発熱に保ちます。ライブ写真の説明には0.8Bモデルが必要なため、LFM2.5が有効な間に追加された写真は、録音が終わるまでOCRテキストのままになります。録音後は、要約・タイトル・単語・チャットに上で選んだ要約モデルを使用します。"},
}
for key, langs in entries.items():
    locs = {lang: {"stringUnit": {"state": "translated", "value": val}}
            for lang, val in langs.items()}
    cat["strings"][key] = {"extractionState": "manual", "localizations": locs}
json.dump(cat, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
print("added", len(entries), "keys")
PY
```
Expected output: `added 2 keys`.

- [x] **Step 2: Verify the catalog is still valid JSON and the keys landed**

Run:
```bash
python3 -c "
import json
cat = json.load(open('Loqi/Localizable.xcstrings'))
for k in ['Experimental: Liquid LFM2.5 live-refine model']:
    locs = cat['strings'][k]['localizations']
    assert {'zh-Hans','ja'} <= set(locs), k
    print('ok:', k, '->', locs['zh-Hans']['stringUnit']['value'])
print('valid JSON, all keys present')
"
```
Expected: one `ok:` line then `valid JSON, all keys present`.

- [x] **Step 3: Build to let Xcode reconcile the catalog**

Run:
```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. Xcode marks the old (pre-Task-3) footer string `stale` — harmless, it no longer appears in code.

- [x] **Step 4: Commit**

```bash
git add Loqi/Localizable.xcstrings
git commit -m "i18n: localize the LFM2.5 live-refine toggle and footer copy (zh-Hans, ja)"
```

---

## Task 5: On-device verification (manual — cannot run in the Simulator)

MLX does not run in the iOS Simulator, so whether `LiquidAI/LFM2.5-230M-MLX-4bit` actually loads through mlx-swift-lm's `LFM2.swift` factory and produces usable refinements can only be confirmed on a real iPhone. This mirrors the still-open Bonsai device check already tracked for this project.

- [ ] **Step 1: Install the build on a real device and open Settings**

Enable "Experimental: Liquid LFM2.5 live-refine model". Confirm the "Live model" row now reads "Liquid LFM2.5 230M" and "Live model files" reads "Not downloaded".

- [ ] **Step 2: Download and load**

Tap "Download live model". Expected: progress bar completes (~151 MB), "Live model files" flips to "Downloaded", Diagnostics → "Model state" reaches `Ready` without a crash.

- [ ] **Step 3: Start a live recording and check refinement**

Speak a sentence with live translation active. Expected: a refined translation appears (not just the Tier-1 draft), Diagnostics → "Last generation" shows a plausible tok/s figure (compare against the existing 0.8B figure for the same device — should be noticeably higher given the ~3.5x smaller model), and no `<think>` tag or repetition-loop garbage leaks into the caption.

- [ ] **Step 4: Confirm the accepted vision degradation**

While still in that recording, attach a photo. Expected: the photo keeps its OCR text only (no AI description appears live) — this is the accepted trade-off from Task 2, not a bug. Confirm no crash and no error surfaced to the user.

- [ ] **Step 5: Confirm Chinese live-refine quality is at least usable**

Repeat Step 3 with Chinese speech + zh↔en live translation. Expected: refined output is coherent Chinese/English, not garbled — LFM2.5's model card claims Chinese support but has no translation-specific benchmark, so this is the actual bar this plan needs cleared before recommending the toggle be turned on by default in a future plan.

- [ ] **Step 6: Record findings**

If Steps 2-5 pass, the candidate is viable for the flag to eventually flip to on-by-default in a follow-up decision (out of scope here). If Step 5 fails (garbled/unusable output), leave the flag off-by-default indefinitely and note the failure mode for future reference.

---

## Self-Review

**1. Spec coverage:** "Add LFM2.5-230M as an experimental candidate for the live-refine slot, Bonsai's opt-in pattern" → Task 1 (catalog+flag+resolver, mirrors `bonsaiEnabled`/`availableModels`), Task 2 (wiring), Task 3 (Settings toggle mirroring the Bonsai toggle), Task 4 (localization, a hard requirement in this codebase), Task 5 (the real-device check this project already tracks as pending for every new model candidate). No gaps.

**2. Placeholder scan:** every step has verbatim code/commands and stated expected output; no "TBD"/"handle errors appropriately"/"similar to Task N" language.

**3. Type consistency:** `ModelCatalog.liveRefineModel(_ defaults: UserDefaults = .standard) -> ModelOption` is defined once in Task 1 and called identically (`ModelCatalog.liveRefineModel()`) in Tasks 2 and 3. `ModelCatalog.lfm2_5_230m` and `ModelCatalog.liveRefineLFM2Enabled` are likewise defined once and referenced with matching names throughout.

