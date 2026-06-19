# Loqi Architecture Audit

Date: 2026-06-18

## Summary

Loqi is a Swift 6 / XcodeGen app whose source of truth is `project.yml`, not the generated `Loqi.xcodeproj`. The core design is capture-first: `CaptionPipeline` owns live session state, `SummaryJobCenter` owns saved-session jobs, and `LLMService` is the only MLX integration point. That split is good. The main risks are all at boundaries: real-device-only APIs, cancellation while MLX generation is running, background/foreground transitions, large model setup, and absent automated CI in this checkout.

Facts are based on source review and commands listed in the evidence table. Hypotheses are called out explicitly.

## Target Map

- `Loqi`: iOS app target from `Loqi/`, with MLX, HuggingFace, Tokenizers, FluidAudio, sherpa-onnx xcframeworks, and embedded `LoqiWidgets` (`project.yml:41-110`).
- `LoqiMac`: macOS app sharing `Loqi/`, excluding `Intents` and `Pipeline/ASR/SherpaOnnx` (`project.yml:112-149`).
- `LoqiWidgets`: iOS widget extension with `LoqiWidgets`, `Loqi/Shared`, and `RecordingIntents.swift`; it defines `LOQI_WIDGET` and intentionally avoids heavy ML deps (`project.yml:151-174`).
- `LoqiTests`: iOS unit test bundle depending on `Loqi` (`project.yml:176-189`).
- `LoqiUITests`: separate UI-test scheme so normal `Loqi` tests do not run XCUITest (`project.yml:191-223`).

## Runtime Flow

1. App entry is `LoqiApp` -> `RootView`; a single `CaptionPipeline.shared` is passed to Record, Sessions, Vocabulary, and Settings (`Loqi/LoqiApp.swift`).
2. `CaptionPipeline` is `@MainActor @Observable` and serializes session transitions (`Loqi/Support/CaptionPipeline.swift:25-39`).
3. Live session flow: mic buffers from `AudioCaptureService` -> selected `SpeechEngine` -> `TranscriptSegmenter` -> `CaptionStore`; optional Translation framework drafts and MLX refinement update the display later.
4. Finalized entries feed `LiveChunker`; chunk notes go to `ChunkNoteQueue` during silence, and saved sessions are persisted by `SessionArchive`.
5. Saved-session work is separate: `SummaryJobCenter` runs summarize, import, and re-transcribe jobs, with activity/progress held per session.
6. Summary generation is map/reduce: `SummaryEngine.summarize` maps uncovered entries, then deterministic `SummaryRecordReducer.render` reduces records (`Loqi/Pipeline/Summary/SummaryEngine.swift:400-430`, `:495-563`).

## Boundaries

- `CaptionPipeline` is the live orchestrator and source of app-wide dependencies: `CaptionStore`, `TranslationCoordinator`, `ThermalMonitor`, `HotwordStore`, `VoiceprintService`, `SessionArchive`, `LLMService`, and `SummaryJobCenter` (`Loqi/Support/CaptionPipeline.swift:41-51`).
- `LLMService` contains MLX/MLXVLM imports and model loading/generation. Its comment states MLX needs a real Apple-silicon GPU and never runs in the simulator (`Loqi/Pipeline/Refinement/LLMService.swift:14-20`).
- `SessionArchive` owns local JSON records, recordings, and attachments under Application Support (`Loqi/Support/SessionArchive.swift:20-44`).
- App Intents are compiled into both app and widget, with app-only bodies fenced behind `!LOQI_WIDGET` (`Loqi/Intents/RecordingIntents.swift:1-10`).

## Model And Runtime Integration

- LLM models: `ModelCatalog` offers Qwen3.5 2B and 0.8B tiers, both marked vision-capable. Downloads can come from Hugging Face or ModelScope.
- LLM loading: `LLMService.load(policy: .requireDownloaded)` prevents silent multi-GB downloads (`Loqi/Pipeline/Refinement/LLMService.swift:61-89`).
- Live ASR: Apple SpeechAnalyzer is the fallback; SenseVoice uses sherpa-onnx only when runtime model files are installed.
- SenseVoice runtime weights: `SenseVoiceModelStore` checks `model.int8.onnx`, `tokens.txt`, and `silero_vad.onnx` size floors before marking installed (`Loqi/Pipeline/ASR/SenseVoiceModelStore.swift:56-97`).
- Qwen3-ASR runtime weights: `Qwen3ASRModelStore` checks the ONNX encoder/decoder/tokenizer files and its own VAD copy (`Loqi/Pipeline/ASR/Qwen3ASRModelStore.swift:44-116`).
- Speaker diarization: FluidAudio is a package dependency and its model download path is user-selected via `DiarizerSource`.
- Build-time sherpa frameworks: `Scripts/fetch-sherpa-onnx.sh` fetches prebuilt xcframeworks only if `ThirdParty/sherpa-onnx/{sherpa-onnx,onnxruntime}.xcframework` are missing (`Scripts/fetch-sherpa-onnx.sh:1-13`). In this checkout, those directories exist.

## Widgets, Intents, And Mac

- Widget shared state is a tiny Codable blob in app group `group.com.kunzhipeng.loqi` (`Loqi/Shared/RecordingSharedState.swift:3-33`).
- Control Center toggle reads that shared state through `RecordingControl.Provider.currentValue` (`LoqiWidgets/RecordingControl.swift:5-35`).
- Intents refuse first-run recording unless onboarding is complete and microphone permission is granted (`Loqi/Intents/RecordingIntents.swift:30-39`).
- `LoqiMac` shares most source but excludes app intents and sherpa-onnx wrapper code (`project.yml:112-149`). macOS also has its own sandbox/mic/user-selected-read-only entitlements.

## Persistence

- Session records are one JSON file per session. Recordings and attachments are separate files referenced by record fields (`Loqi/Support/SessionArchive.swift:4-17`).
- `SessionArchive.shouldArchive` keeps any session with at least one entry, or an audio-only session of at least 5 seconds (`Loqi/Support/SessionArchive.swift:85-97`).
- Orphan sweeps delete recording/attachment files no session references, after crash recovery has a chance to claim interrupted files (`Loqi/Support/SessionArchive.swift:50-56`, `:218-239`).
- Hypothesis: `SessionArchive.persist` should use atomic writes to reduce crash-corruption risk; it currently writes JSON directly (`Loqi/Support/SessionArchive.swift:264-272`).

## Privacy And Security

- `project.yml` declares microphone, speech recognition, and camera usage descriptions that say audio/images stay on device (`project.yml:64-67`, `:129-134`).
- `Loqi/PrivacyInfo.xcprivacy` parses and declares no tracking or collected data; accessed API types are UserDefaults and file timestamp.
- App entitlements include app group and increased memory limit. Widget has the same app group. macOS target is sandboxed with mic and read-only user-selected files.
- Runtime network use is for explicit model downloads and system translation/speech assets. No secrets or credentials were found by source search for obvious `secret`/`token` patterns beyond tokenizer/model terminology.

## Reliability Risks

1. Real-device surfaces remain high risk: mic/camera, Live Activity/Dynamic Island, Control Center toggle, on-device MLX, FluidAudio, and large downloads.
2. No CI config is present in this checkout (`find .github` returned `No such file or directory`); `docs/codex/manual-xcode-verification.md` is the current manual gate.
3. Generated project drift is confirmed. XcodeGen 2.45.4 can generate the project in a temp root, but the generated `project.pbxproj` differs from the checked-in one; sampled drift includes local `DEVELOPMENT_TEAM` signing metadata absent from `project.yml`.
4. Fixed in source during follow-up: LLM stream cancellation now throws via `collectGeneratedText`; import security-scope cleanup uses `defer`; session JSON writes use `.atomic`.

## Device Limits

- Simulator-safe: pure unit tests for reducers, catalog logic, parsing, downloader layout, archive decisions, search, subtitles, speaker math, and intent route resolution.
- Real device required: mic capture, camera capture, background audio, Live Activities/Dynamic Island, Control Center toggle, Action Button/Siri intents, MLX generation, FluidAudio CoreML/ANE behavior, real memory pressure, and model download performance.
- Full model downloads were not run.

## Ranked Follow-ups

1. Run a real-device smoke pass for mic, stop/archive, playback, Live Activity stop, Control Center toggle, camera attachment, LLM summarize, and thermal/memory behavior.
2. Run `LoqiTests`, `LoqiUITests`, and `LoqiMac` manually in Xcode using `docs/codex/manual-xcode-verification.md`.
3. Decide whether signing metadata belongs in `project.yml`, then intentionally run `xcodegen generate` when ready to refresh `Loqi.xcodeproj`.
4. Add CI when a known-good macOS/Xcode runner is available for the required SDK.

## Evidence Table

| Evidence | Result |
|---|---|
| `git status --short` before edits | Existing modified: `AGENTS.md`, 5 Swift files, `LoqiTests/SummaryEngineTests.swift`; untracked `build/` and `docs/superpowers/plans/2026-06-18-fix-map-summary-review.md`. |
| `sed -n '1,260p' project.yml` | Confirmed XcodeGen targets, packages, schemes, deployment targets, Info.plist generation. |
| `rg -n "@Test" LoqiTests \| wc -l` | 359 unit test declarations. |
| `rg -n "XCTest\|func test" LoqiUITests` | 3 UI tests in `OnboardingFlowUITests`. |
| `find ThirdParty/sherpa-onnx ...` | `sherpa-onnx.xcframework` and `onnxruntime.xcframework` directories exist, including simulator/device slices. |
| `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer`. |
| `xcrun --find xcodebuild` | `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild`. |
| `brew list xcodegen >/dev/null 2>&1 || brew install xcodegen` | Installed XcodeGen 2.45.4. |
| `xcodegen --version` | `Version: 2.45.4`. |
| Temp-root `xcodegen generate` then `diff -q Loqi.xcodeproj/project.pbxproj /tmp/loqi-xgenroot.218pRg/Loqi.xcodeproj/project.pbxproj` | Generation succeeded outside the repo; `project.pbxproj` drift is present. |
| `xcrun simctl list devices available` | iOS 26.5 simulator devices available, all Shutdown. |
| `plutil -lint Loqi/Info.plist LoqiMac/Info.plist LoqiWidgets/Info.plist Loqi/PrivacyInfo.xcprivacy Loqi/Loqi.entitlements LoqiMac/LoqiMac.entitlements LoqiWidgets/LoqiWidgets.entitlements` | All OK. |
