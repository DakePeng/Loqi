# Dual-Model Settings & Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Settings and onboarding accurately present the two LLM tiers that already run together — Qwen3.5 0.8B always during live recording, and the user's summary pick (default 2B) after recording — instead of one "Model" choice that hides the live tier.

**Architecture:** The runtime already swaps tiers (`CaptionPipeline` loads `ModelCatalog.liveModel` for live work; `SummaryJobCenter`/`SessionDetailView`/`ChatEngine` load `ModelCatalog.summaryModel` after). This change is UI-only: split the single onboarding LLM item into independently-selectable Live (0.8B) and Summary (2B) rows, and replace the single Settings "Model" picker with a fixed Live-model row plus a pickable Summary-model row, each owning its own download state. The now-orphaned bundle helpers (`ModelCatalog.requiredModels`, `ModelCatalog.onboardingLLMBytes`, `OnboardingItemKind.llmModelsInstalled`) are deleted.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`import Testing`, `@Test`/`#expect`) for unit tests, XCTest for UI tests, Xcode `String Catalog` (`Localizable.xcstrings`) for localization, MLX for on-device inference. Build/test via `xcodebuild` against the `Loqi` scheme.

## Global Constraints

- **Live tier is fixed and non-optional in concept:** live recording always uses `ModelCatalog.liveModel` (`mlx-community/Qwen3.5-0.8B-4bit`). Never expose a picker that changes the *live* model.
- **Summary tier is the user's pick:** persisted under `UserDefaults` key `"model.id"`, default `ModelCatalog.qwen35_2b` (`mlx-community/Qwen3.5-2B-4bit`). The Settings summary picker writes this key; `ModelCatalog.summaryModel == ModelCatalog.current` reads it.
- **Onboarding splits into two selectable LLM rows:** `.liveLLM` (0.8B, ~652 MB) and `.summaryLLM` (2B, ~1.75 GB). Both are recommended (pre-checked) but skippable.
- **Download source fan-out is unchanged:** region → `model.source`/`asr.source`/`diarizer.source` keys via `DownloadRegion.persistSources`. Do not touch `DownloadRegion`.
- **Localization targets zh-Hans and ja only.** The string catalog has no Korean UI localizations (verified: `langs seen: ['en','ja','zh-Hans']`). `en` is the source language. Every new user-facing `String(localized:)` / SwiftUI `Text` must get zh-Hans + ja translations.
- **On-device only:** the network is used solely for model downloads the user starts. No new network calls.
- **Build command:** `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (substitute any booted simulator from `xcrun simctl list devices available`).

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Loqi/Features/Onboarding/OnboardingCatalog.swift` | `OnboardingItemKind` enum: rows, sizes, install state, queue | Split `.llm` → `.liveLLM` + `.summaryLLM`; delete `llmModelsInstalled` |
| `Loqi/Features/Onboarding/OnboardingDownloadModel.swift` | Drives onboarding downloads | Split `downloadLLM` into per-tier downloads |
| `Loqi/Support/ModelCatalog.swift` | LLM catalog + role helpers | Delete `onboardingLLMBytes` (Task 1) and `requiredModels` (Task 2) |
| `Loqi/Features/Settings/SettingsView.swift` | Settings "On-device AI" section | Two explicit rows + per-model download state |
| `LoqiTests/OnboardingCatalogTests.swift` | Onboarding enum guards | Update for split |
| `LoqiTests/ModelCatalogTests.swift` | Catalog guards | Drop tests for deleted helpers |
| `LoqiUITests/OnboardingFlowUITests.swift` | Onboarding UI flow | Update LLM row labels |
| `Loqi/Localizable.xcstrings` | String catalog | Add zh-Hans + ja for new strings |

---

## Task 1: Split the onboarding LLM item into Live (0.8B) and Summary (2B)

**Files:**
- Modify: `Loqi/Features/Onboarding/OnboardingCatalog.swift`
- Modify: `Loqi/Features/Onboarding/OnboardingDownloadModel.swift`
- Modify: `Loqi/Support/ModelCatalog.swift` (delete `onboardingLLMBytes`)
- Test: `LoqiTests/OnboardingCatalogTests.swift`
- Test: `LoqiTests/ModelCatalogTests.swift` (delete one stale test)
- Test: `LoqiUITests/OnboardingFlowUITests.swift` (label updates)

**Interfaces:**
- Consumes: `ModelCatalog.liveModel` (0.8B `ModelOption`), `ModelCatalog.qwen35_2b` (2B `ModelOption`), `LLMService.isDownloaded(model:) -> Bool` (static), `DownloadSpeedometer.start(totalBytes:)` / `.update(_ fraction: Double)`.
- Produces: `OnboardingItemKind.liveLLM` and `.summaryLLM` cases (replacing `.llm`); `defaultSelection` containing both; per-item `downloadBytes`/`isInstalled`. Later tasks rely on these case names.

- [ ] **Step 1: Update the failing unit tests in `OnboardingCatalogTests.swift`**

Replace the four affected tests so they describe the split. Replace `recommendedSelectionIncludesTranslationPacks`, `llmItemBytesCoverBothModels`, `llmItemRequiresBothModelsInstalled`, and add the install/size guards. Find this block (lines ~59-97):

```swift
    @Test func recommendedSelectionIncludesTranslationPacks() {
        #expect(OnboardingItemKind.defaultSelection == [
            .translationPacks,
            .senseVoice,
            .diarizer,
            .llm,
        ])
    }
```

and the two LLM tests below it, and replace all of them with:

```swift
    @Test func recommendedSelectionIncludesBothLLMTiers() {
        #expect(OnboardingItemKind.defaultSelection == [
            .translationPacks,
            .senseVoice,
            .diarizer,
            .liveLLM,
            .summaryLLM,
        ])
    }

    @Test func liveLLMItemMatchesTheFastTier() {
        #expect(OnboardingItemKind.liveLLM.downloadBytes == ModelCatalog.liveModel.downloadBytes)
        #expect(OnboardingItemKind.liveLLM.isRecommended)
    }

    @Test func summaryLLMItemMatchesTheTwoBTier() {
        #expect(OnboardingItemKind.summaryLLM.downloadBytes == ModelCatalog.qwen35_2b.downloadBytes)
        #expect(OnboardingItemKind.summaryLLM.isRecommended)
    }
```

- [ ] **Step 2: Fix the remaining `.llm` references in `OnboardingCatalogTests.swift`**

Three more tests name `.llm`. Update them:

In `totalSumsSelectedUninstalledItems`, change the selection set and the expected sum:

```swift
    @Test func totalSumsSelectedUninstalledItems() {
        let total = OnboardingItemKind.totalBytes(
            for: [.translationPacks, .senseVoice, .diarizer, .liveLLM, .summaryLLM],
            installed: [])
        let expected = SenseVoiceModelStore.totalExpectedBytes
            + StreamingDiarizer.approximateDownloadBytes
            + ModelCatalog.liveModel.downloadBytes
            + ModelCatalog.qwen35_2b.downloadBytes
        #expect(total == expected)
    }
```

In `totalIgnoresInstalledAndAppleSpeech`, swap `.llm` for `.summaryLLM`:

```swift
    @Test func totalIgnoresInstalledAndAppleSpeech() {
        let total = OnboardingItemKind.totalBytes(
            for: [.appleSpeech, .senseVoice, .summaryLLM], installed: [.summaryLLM])
        #expect(total == SenseVoiceModelStore.totalExpectedBytes)
    }
```

In `queueRunsFallbackEngineFirstAndOptionalLast`, replace `.llm` in both the selection and the expected order:

```swift
    @Test func queueRunsFallbackEngineFirstAndOptionalLast() {
        let queue = OnboardingItemKind.queueOrder(
            selection: [
                .translationPacks,
                .qwen3ASR,
                .liveLLM,
                .summaryLLM,
                .diarizer,
                .senseVoice,
            ],
            installed: [])
        #expect(queue == [
            .appleSpeech,
            .translationPacks,
            .senseVoice,
            .diarizer,
            .liveLLM,
            .summaryLLM,
            .qwen3ASR,
        ])
    }
```

In `queueDropsInstalledAndUnselected`, swap `.llm` for `.summaryLLM`:

```swift
    @Test func queueDropsInstalledAndUnselected() {
        let queue = OnboardingItemKind.queueOrder(
            selection: [.senseVoice, .summaryLLM], installed: [.senseVoice])
        #expect(queue == [.appleSpeech, .summaryLLM])
    }
```

- [ ] **Step 3: Delete the stale `onboardingLLMBytes` test in `ModelCatalogTests.swift`**

Remove this test entirely (lines ~75-78):

```swift
    @Test func onboardingBytesCoverBothModels() {
        #expect(ModelCatalog.onboardingLLMBytes
            == ModelCatalog.qwen35_2b.downloadBytes + ModelCatalog.qwen35_0_8b.downloadBytes)
    }
```

- [ ] **Step 4: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LoqiTests/OnboardingCatalogTests \
  -only-testing:LoqiTests/ModelCatalogTests 2>&1 | tail -30
```
Expected: COMPILE FAILURE — `.liveLLM`/`.summaryLLM` are not yet members of `OnboardingItemKind` (and `OnboardingItemKind.llm` no longer referenced). This is the red state.

- [ ] **Step 5: Split the enum cases in `OnboardingCatalog.swift`**

Replace `case llm` in the case list:

```swift
enum OnboardingItemKind: String, CaseIterable, Identifiable {
    case appleSpeech
    case translationPacks
    case senseVoice
    case diarizer
    case liveLLM
    case summaryLLM
    case qwen3ASR
```

In `title`, replace the `.llm` arm:

```swift
        case .liveLLM: String(localized: "Live AI model (0.8B)")
        case .summaryLLM: String(localized: "Summary AI model (2B)")
```

In `subtitle`, replace the `.llm` arm:

```swift
        case .liveLLM:
            String(localized: "Fast on-device model for live translation and notes")
        case .summaryLLM:
            String(localized: "Higher-quality summaries, titles and chat")
```

In `downloadBytes`, replace the `.llm` arm:

```swift
        case .liveLLM: ModelCatalog.liveModel.downloadBytes
        case .summaryLLM: ModelCatalog.qwen35_2b.downloadBytes
```

- [ ] **Step 6: Update the remaining switch arms and helpers in `OnboardingCatalog.swift`**

In `isRecommended`, move both LLM cases to the recommended arm:

```swift
    var isRecommended: Bool {
        switch self {
        case .translationPacks, .senseVoice, .diarizer, .liveLLM, .summaryLLM: true
        case .appleSpeech, .qwen3ASR: false
        }
    }
```

In `systemAssetProgressText`, replace `.llm` in the passthrough arm:

```swift
        case .senseVoice, .diarizer, .liveLLM, .summaryLLM, .qwen3ASR:
            caption
```

In `isInstalled`, replace the `.llm` arm:

```swift
        case .liveLLM: LLMService.isDownloaded(model: ModelCatalog.liveModel)
        case .summaryLLM: LLMService.isDownloaded(model: ModelCatalog.qwen35_2b)
```

In `defaultSelection`, replace `.llm` with both tiers:

```swift
    static var defaultSelection: Set<OnboardingItemKind> {
        [.translationPacks, .senseVoice, .diarizer, .liveLLM, .summaryLLM]
    }
```

Delete the now-orphaned `llmModelsInstalled` static method in its entirety (lines ~124-129):

```swift
    static func llmModelsInstalled(
        isDownloaded: (ModelOption) -> Bool = { LLMService.isDownloaded(model: $0) }
    ) -> Bool {
        ModelCatalog.requiredModels(summaryModel: ModelCatalog.default)
            .allSatisfy(isDownloaded)
    }
```

- [ ] **Step 7: Delete `onboardingLLMBytes` from `ModelCatalog.swift`**

Remove this computed property (lines ~116-119); the per-item `downloadBytes` now read the tiers directly:

```swift
    /// Bytes onboarding pulls for the LLM step now that both tiers ship.
    static var onboardingLLMBytes: Int64 {
        requiredModels(summaryModel: `default`).map(\.downloadBytes).reduce(0, +)
    }
```

- [ ] **Step 8: Split the download driver in `OnboardingDownloadModel.swift`**

In the `download(_:into:)` switch, replace the `.llm` arm:

```swift
        case .liveLLM: await downloadSingleLLM(item, model: ModelCatalog.liveModel)
        case .summaryLLM: await downloadSingleLLM(item, model: ModelCatalog.qwen35_2b)
```

Replace the entire `downloadLLM(_:)` method (lines ~344-397) with one per-model helper:

```swift
    /// One LLM tier in isolation: bytes to disk, then unloaded — onboarding
    /// wants the file present, not 0.8/1.75 GB resident while later items
    /// (the other tier, Qwen3-ASR) may still download. The pipeline warm-loads
    /// lazily when a session needs it.
    private func downloadSingleLLM(_ item: Item, model: ModelOption) async {
        item.speedometer.start(totalBytes: model.downloadBytes)
        let llm = pipeline.llm
        // The shared pipeline was constructed before the region step wrote
        // the source keys — sync the actor like SettingsView's .task does.
        await llm.setSource(region.llmSource)
        await llm.setModel(model)
        do {
            try await llm.load { fraction in
                Task { @MainActor in item.speedometer.update(fraction) }
            }
            await llm.unload()
            if LLMService.isDownloaded(model: model) {
                item.speedometer.update(1)
                item.status = .done
            } else {
                item.status = .failed("Download incomplete")
            }
        } catch is CancellationError {
            await llm.unload()
            item.status = .skipped
        } catch {
            await llm.unload()
            // Tolerate a late error if the bytes actually landed.
            item.status = LLMService.isDownloaded(model: model)
                ? .done
                : .failed(error.localizedDescription)
        }
    }
```

- [ ] **Step 9: Update the LLM row labels in `OnboardingFlowUITests.swift`**

In `testChinaRegionThenSkipLandsInApp`, replace the `"Qwen3.5 2B AI model"` entry in the title list (line ~52) with both new rows:

```swift
        for title in [
            "Apple speech recognition",
            "Translation language packs",
            "SenseVoice live recognition",
            "Speaker recognition",
            "Live AI model (0.8B)",
            "Summary AI model (2B)",
            "Qwen3-ASR re-transcription",
        ] {
            XCTAssertTrue(app.staticTexts[title].exists, "missing row: \(title)")
        }
```

In `testSenseVoiceOnlyDownloadCompletes`, the line that unchecks the LLM row (line ~112) must uncheck both tiers:

```swift
        // Leave only SenseVoice checked (Qwen3-ASR starts unchecked).
        app.staticTexts["Translation language packs"].tap()
        app.staticTexts["Speaker recognition"].tap()
        app.staticTexts["Live AI model (0.8B)"].tap()
        app.staticTexts["Summary AI model (2B)"].tap()
```

- [ ] **Step 10: Run the unit tests to verify they pass**

Run:
```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LoqiTests/OnboardingCatalogTests \
  -only-testing:LoqiTests/ModelCatalogTests 2>&1 | tail -30
```
Expected: PASS — `** TEST SUCCEEDED **`. (UI tests are slow; run them in Task 2's full build, not here.)

- [ ] **Step 11: Commit**

```bash
git add Loqi/Features/Onboarding/OnboardingCatalog.swift \
  Loqi/Features/Onboarding/OnboardingDownloadModel.swift \
  Loqi/Support/ModelCatalog.swift \
  LoqiTests/OnboardingCatalogTests.swift \
  LoqiTests/ModelCatalogTests.swift \
  LoqiUITests/OnboardingFlowUITests.swift
git commit -m "feat: split onboarding LLM into live (0.8B) and summary (2B) rows"
```

---

## Task 2: Replace the Settings "Model" picker with explicit Live + Summary rows

**Files:**
- Modify: `Loqi/Features/Settings/SettingsView.swift`
- Modify: `Loqi/Support/ModelCatalog.swift` (delete `requiredModels`)
- Test: `LoqiTests/ModelCatalogTests.swift` (delete one stale test)

**Interfaces:**
- Consumes: `ModelCatalog.liveModel`, `ModelCatalog.all`, `ModelCatalog.option(for:) -> ModelOption`, `LLMService.isDownloaded(model:)`, `pipeline.llm.setModel(_:)` / `.load(_:)` / `.cancelLoad()` / `.setSource(_:)`, `DownloadProgressRow(speedometer:onStop:)`, `DownloadSpeedometer`.
- Produces: nothing consumed by later tasks. This is a leaf UI change.

- [ ] **Step 1: Swap the download-state `@State` fields in `SettingsView.swift`**

Find (line ~33):

```swift
    @State private var llmDownloaded = false
    @State private var availableMemory = "—"
    @State private var llmDownloading = false
    @State private var llmSpeedometer = DownloadSpeedometer()
    @State private var downloadError: String?
```

Replace with two install-state flags and an active-download identifier (the shared `pipeline.llm` actor serializes loads, so one download is in flight at a time — `downloadingModelID` says which row shows progress):

```swift
    @State private var liveDownloaded = false
    @State private var summaryDownloaded = false
    @State private var availableMemory = "—"
    // ponytail: one in-flight download (the LLM actor serializes loads); the
    // id picks which row renders the progress bar. Per-row flags would buy
    // nothing the actor doesn't already enforce.
    @State private var downloadingModelID: String?
    @State private var llmSpeedometer = DownloadSpeedometer()
    @State private var downloadError: String?
```

- [ ] **Step 2: Rewrite the "On-device AI" section body**

Replace the whole `Section { ... } header: { Text("On-device AI") } footer: { ... }` block (lines ~136-193) with the two-row layout:

```swift
                Section {
                    Toggle("AI features", isOn: $llmEnabled)
                        .onChange(of: llmEnabled) {
                            pipeline.setLLMEnabled(llmEnabled)
                        }

                    Group {
                        // Live tier — fixed 0.8B, runs during recording.
                        LabeledContent("Live model", value: "Qwen3.5 0.8B")
                        LabeledContent(
                            "Live model files",
                            value: liveDownloaded
                                ? String(localized: "Downloaded")
                                : String(localized: "Not downloaded"))
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

                        // Summary tier — user's pick, runs after recording.
                        Picker("Summary model", selection: $modelID) {
                            ForEach(ModelCatalog.all) { option in
                                Text(option.displayName).tag(option.id)
                            }
                        }
                        .onChange(of: modelID) {
                            Task {
                                await pipeline.llm.setModel(ModelCatalog.option(for: modelID))
                                await refreshStats()
                            }
                        }
                        LabeledContent(
                            "Summary model files",
                            value: summaryDownloaded
                                ? String(localized: "Downloaded")
                                : String(localized: "Not downloaded"))
                        if !summaryDownloaded {
                            let summary = ModelCatalog.option(for: modelID)
                            if downloadingModelID == summary.id {
                                DownloadProgressRow(
                                    speedometer: llmSpeedometer, onStop: stopDownload)
                            } else {
                                Button("Download summary model") {
                                    startDownload(summary)
                                }
                                .disabled(downloadingModelID != nil)
                            }
                        }

                        Picker("Download from", selection: $sourceRaw) {
                            ForEach(ModelSource.allCases) { source in
                                Text(source.displayName).tag(source.rawValue)
                            }
                        }
                        .onChange(of: sourceRaw) {
                            Task {
                                let source = ModelSource(rawValue: sourceRaw) ?? .huggingFace
                                await pipeline.llm.setSource(source)
                            }
                        }

                        if let downloadError {
                            Text(downloadError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(!llmEnabled)
                } header: {
                    Text("On-device AI")
                } footer: {
                    Text("Live recording always uses the fast Qwen3.5 0.8B model so captions and live translation stay responsive and cool. After a recording, summaries, titles, vocabulary and chat use the summary model you pick above.")
                }
```

- [ ] **Step 3: Replace `startDownload()` with a single-model version**

Replace the whole `private func startDownload()` method (lines ~316-352) with one that downloads exactly the passed model:

```swift
    private func startDownload(_ model: ModelOption) {
        downloadError = nil
        downloadingModelID = model.id
        llmSpeedometer.start(totalBytes: model.downloadBytes)
        Task {
            await pipeline.llm.setModel(model)
            do {
                try await pipeline.llm.load { progress in
                    Task { @MainActor in llmSpeedometer.update(progress) }
                }
            } catch is CancellationError {
                // Stopped by the user — not an error.
            } catch {
                downloadError = error.localizedDescription
            }
            // Restore the user's summary pick as the resident model.
            await pipeline.llm.setModel(ModelCatalog.option(for: modelID))
            downloadingModelID = nil
            await refreshStats()
        }
    }
```

`stopDownload()` (calls `pipeline.llm.cancelLoad()`) stays unchanged.

- [ ] **Step 4: Update install-state computation in `refreshStats()`**

Find (lines ~366-368):

```swift
        let selected = ModelCatalog.option(for: modelID)
        llmDownloaded = ModelCatalog.requiredModels(summaryModel: selected)
            .allSatisfy { LLMService.isDownloaded(model: $0) }
```

Replace with two independent checks:

```swift
        liveDownloaded = LLMService.isDownloaded(model: ModelCatalog.liveModel)
        summaryDownloaded = LLMService.isDownloaded(
            model: ModelCatalog.option(for: modelID))
```

- [ ] **Step 5: Delete the orphaned `requiredModels` helper from `ModelCatalog.swift`**

Nothing references `requiredModels` after Tasks 1-2. Remove it (lines ~112-114):

```swift
    static func requiredModels(summaryModel: ModelOption = current) -> [ModelOption] {
        summaryModel == liveModel ? [liveModel] : [summaryModel, liveModel]
    }
```

- [ ] **Step 6: Delete the stale `requiredModels` test in `ModelCatalogTests.swift`**

Remove (lines ~80-85):

```swift
    @Test func requiredModelsIncludeSummaryAndLiveWithoutDuplicates() {
        #expect(ModelCatalog.requiredModels(summaryModel: ModelCatalog.qwen35_2b)
            == [ModelCatalog.qwen35_2b, ModelCatalog.qwen35_0_8b])
        #expect(ModelCatalog.requiredModels(summaryModel: ModelCatalog.liveModel)
            == [ModelCatalog.liveModel])
    }
```

- [ ] **Step 7: Build and run the full unit-test suite**

Run:
```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LoqiTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`. There is no unit test for the SwiftUI view itself (views aren't unit-tested in this project); compilation plus the catalog tests are the automated gate.

- [ ] **Step 8: Manual smoke check of the Settings section**

Run the app (`xcodebuild build ...` then launch in Simulator, or open the project in Xcode and Run). In Settings → On-device AI, confirm:
- A fixed **Live model** row reads "Qwen3.5 0.8B" with a Downloaded / Not downloaded state.
- A **Summary model** picker offers "Qwen3.5 2B — recommended" and "Qwen3.5 0.8B — fastest"; switching it updates the "Summary model files" state.
- When a tier is missing, its own "Download live/summary model" button appears and shows a progress bar while downloading; the other row's button is disabled during the download.
- The footer explains the 0.8B-live / pick-summary split.

- [ ] **Step 9: Commit**

```bash
git add Loqi/Features/Settings/SettingsView.swift \
  Loqi/Support/ModelCatalog.swift \
  LoqiTests/ModelCatalogTests.swift
git commit -m "feat: split Settings AI into fixed live + pickable summary model rows"
```

---

## Task 3: Localize the new strings (zh-Hans + ja)

**Files:**
- Modify: `Loqi/Localizable.xcstrings`

**Interfaces:**
- Consumes: the exact English keys introduced in Tasks 1-2 (must match `String(localized:)` / `Text` source verbatim).
- Produces: zh-Hans + ja `stringUnit`s for each. No code consumes this.

- [ ] **Step 1: Add the new keys with translations via a JSON script**

The catalog is 5,300 lines — edit it as JSON, not by hand, so the structure can't break. Run this from the repo root:

```bash
python3 - <<'PY'
import json
path = "Loqi/Localizable.xcstrings"
cat = json.load(open(path))
entries = {
    "Live AI model (0.8B)": {
        "zh-Hans": "实时 AI 模型（0.8B）", "ja": "ライブAIモデル（0.8B）"},
    "Fast on-device model for live translation and notes": {
        "zh-Hans": "用于实时翻译和笔记的快速设备端模型",
        "ja": "リアルタイム翻訳とメモ用の高速オンデバイスモデル"},
    "Summary AI model (2B)": {
        "zh-Hans": "总结 AI 模型（2B）", "ja": "要約AIモデル（2B）"},
    "Higher-quality summaries, titles and chat": {
        "zh-Hans": "更高质量的总结、标题和聊天",
        "ja": "より高品質な要約・タイトル・チャット"},
    "Live model": {"zh-Hans": "实时模型", "ja": "ライブモデル"},
    "Live model files": {"zh-Hans": "实时模型文件", "ja": "ライブモデルファイル"},
    "Download live model": {
        "zh-Hans": "下载实时模型", "ja": "ライブモデルをダウンロード"},
    "Summary model": {"zh-Hans": "总结模型", "ja": "要約モデル"},
    "Summary model files": {"zh-Hans": "总结模型文件", "ja": "要約モデルファイル"},
    "Download summary model": {
        "zh-Hans": "下载总结模型", "ja": "要約モデルをダウンロード"},
    "Live recording always uses the fast Qwen3.5 0.8B model so captions and live translation stay responsive and cool. After a recording, summaries, titles, vocabulary and chat use the summary model you pick above.": {
        "zh-Hans": "录制时始终使用快速的 Qwen3.5 0.8B 模型，让字幕和实时翻译保持流畅、低发热。录制结束后，总结、标题、生词和聊天会使用你在上方选择的总结模型。",
        "ja": "録音中は常に高速なQwen3.5 0.8Bモデルを使用し、字幕とリアルタイム翻訳を快適かつ低発熱に保ちます。録音後は、要約・タイトル・単語・チャットに上で選んだ要約モデルを使用します。"},
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
Expected output: `added 11 keys`.

- [ ] **Step 2: Verify the catalog is still valid JSON and the keys landed**

Run:
```bash
python3 -c "
import json
cat = json.load(open('Loqi/Localizable.xcstrings'))
for k in ['Live model','Summary model','Live AI model (0.8B)','Summary AI model (2B)']:
    locs = cat['strings'][k]['localizations']
    assert {'zh-Hans','ja'} <= set(locs), k
    print('ok:', k, '->', locs['zh-Hans']['stringUnit']['value'])
print('valid JSON, all keys present')
"
```
Expected: four `ok:` lines then `valid JSON, all keys present`. (A non-zero exit / `KeyError` means a source string in Step 1 doesn't match the code verbatim — fix the entry key to match the `String(localized:)`/`Text` literal exactly, including punctuation.)

- [ ] **Step 3: Build to let Xcode reconcile the catalog**

Run:
```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. Xcode flips each `extractionState` from `manual` to extracted and marks the old `Model`, `Model files`, and `Qwen3.5 2B AI model` keys `stale` (harmless — they no longer appear in code; leave them for Xcode to prune).

- [ ] **Step 4: Commit**

```bash
git add Loqi/Localizable.xcstrings
git commit -m "i18n: localize dual-model settings and onboarding strings (zh-Hans, ja)"
```

---

## Self-Review

**1. Spec coverage**
- "Settings page should change" → Task 2 (two explicit rows: fixed live 0.8B + pickable summary). ✓
- "Onboarding process should change" → Task 1 (split `.llm` into `.liveLLM` + `.summaryLLM`, both selectable/skippable). ✓
- "Using 0.8B and 2B simultaneously" → already true in the engine; UI now reflects it. Footer + row copy state the live/summary split. ✓
- Localization (CJK-first app) → Task 3 covers every new string in zh-Hans + ja (the only UI locales). ✓
- Orphaned helpers removed (no dead flexibility): `onboardingLLMBytes` (Task 1), `requiredModels` + `llmModelsInstalled` (Tasks 1-2). ✓

**2. Placeholder scan** — No TBD/"handle errors"/"similar to". Every code step shows complete code. ✓

**3. Type consistency**
- New case names `.liveLLM` / `.summaryLLM` used identically across `OnboardingCatalog.swift`, `OnboardingDownloadModel.swift`, and both test files. ✓
- `startDownload(_ model: ModelOption)` (Task 2 Step 3) matches its call sites in Step 2. ✓
- `downloadingModelID: String?` compared against `ModelCatalog.liveModel.id` / `summary.id` — both `String`. ✓
- `downloadSingleLLM(_:model:)` signature matches its two call sites in the `download(_:into:)` switch. ✓
- `liveDownloaded` / `summaryDownloaded` declared (Step 1), set in `refreshStats` (Step 4), read in the section body (Step 2). ✓

**Edge case noted:** when the summary picker is set to 0.8B, the summary model *is* the live model (same file on disk), so both rows report the same install state and (if missing) both offer a 0.8B download — tapping either resolves both on the next `refreshStats`. Harmless redundancy, not worth a guard.
