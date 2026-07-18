# AGENTS.md — Loqi

Guidance for AI coding agents working in this repository. Assumes no prior knowledge of the project.

## Tooling rules (gstack)

- Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools.
- For code search, use `rg` first.

## Project overview

Loqi is an **iOS-first, fully on-device** voice capture app: record → live transcript (with speaker separation) → instant on-device summary → searchable archive, with optional live translation as a "lens" when source ≠ target language. No servers; nothing leaves the device after the one-time model downloads. Languages: Chinese ↔ English ↔ Japanese (+ Korean).

- **Stack:** Swift 6 (strict concurrency `complete`), SwiftUI, Xcode 26, iOS 26+ deployment target, iPhone 15 or newer. Swift 6 / Xcode 26 / iOS 26 are hard requirements — the LLM does not run in the Simulator.
- **App entry:** `Loqi/LoqiApp.swift` (tabs + translation host stack).
- **Orchestrator:** `Loqi/Support/CaptionPipeline.swift` wires mic capture → ASR → diarization → translation → recording → live notes → crash recovery → archive writes. `CaptionStore` is the observable source of truth the UI renders; `SessionArchive` persists sessions on stop; `SummaryJobCenter` owns post-hoc import / re-transcribe / summarize jobs so navigation cannot double-run them.
- **Targets** (declared in `project.yml`):
  - `Loqi` — the iOS app (the product).
  - `LoqiWidgets` — widget extension: Live Activity / Dynamic Island + Control Center / Lock Screen toggle. Deliberately lean: no packages, no bridging header, no ML deps; `LOQI_WIDGET` compilation flag fences intent bodies.
  - `LoqiMac` — buildable macOS target sharing the `Loqi/` sources (excludes `Intents` and `Pipeline/ASR/SherpaOnnx`); **not a shipped v1 surface**.
  - `LoqiTests` — Swift Testing logic suite. `LoqiUITests` — onboarding XCUITest smoke test on its own scheme.

## Build

`project.yml` (XcodeGen) is **canonical**; `Loqi.xcodeproj` is committed convenience output. Regenerate after any target/package/build-setting/entitlement change:

```sh
brew install xcodegen
Scripts/fetch-sherpa-onnx.sh   # only if ThirdParty/sherpa-onnx is missing/stale (~360MB, gitignored)
xcodegen generate
open Loqi.xcodeproj
```

- **Prefer manual Xcode builds/runs.** Runtime verification requires a real iPhone (Developer Mode on, your own signing team set on both `Loqi` and `LoqiWidgets`); do not run simulator tests/runs as a substitute. Free Apple ID signing works but builds expire after 7 days and may fail to provision the shared app group (core app still works; the Control Center toggle may show stale state).
- Avoid `xcodebuild install` unless explicitly asked. If a CLI build is needed, use a constrained build:
  `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1`
- Schemes: `Loqi` (app + unit test action), `LoqiMac`, `LoqiUITests` (own scheme so UI tests don't slow every `xcodebuild test`).

## Dependencies

SPM packages (see `project.yml` for exact pins):

- `MLX` → **fork** `DakePeng/mlx-swift`, branch `loqi/0.31.4-poison-events` — a transitive-dependency override so background GPU aborts surface as catchable `MLXError` instead of killing the process. Drop when mlx-swift vendors mlx ≥ a025496c.
- `MLXLM` → `ml-explore/mlx-swift-lm` exact 3.31.3, plus `swift-huggingface` and `swift-transformers`. A repetition-penalty/TokenRing bug in 3.31.3 (2-D prompts from the VLM factory crash every generation) is patched locally via `FlattenedPromptProcessor` in `LLMService` — remove the wrapper when the dependency moves past 3.31.3.
- sherpa-onnx (SenseVoice + Dolphin ASR, and the pyannote/CAM++ speaker diarizer): static xcframeworks under `ThirdParty/sherpa-onnx/` (fetched by the script, never committed), bridged via `Loqi/Pipeline/ASR/SherpaOnnx/SherpaOnnx-Bridging-Header.h`.

## Code layout

```
Loqi/
├── LoqiApp.swift          App entry; tabs + translation host stack
├── Features/              SwiftUI screens
│   ├── Captions/          Record tab: live transcript + controls
│   ├── Sessions/          Archive: detail, playback, summaries, import, chat
│   ├── Vocabulary/        Hotword management
│   ├── Onboarding/        Permission + model download flow
│   ├── Settings/          Model pickers, recording toggle, diagnostics
│   └── Shared/            Status bar, mic button, caption rows
├── Intents/               Siri, Shortcuts, Action Button, widget intents
├── Pipeline/
│   ├── Audio/             Mic capture → AsyncStream; CAF/AAC recorder
│   ├── ASR/               Apple SpeechAnalyzer, SenseVoice, Dolphin (+ SherpaOnnx bridge)
│   ├── Translation/       System Translation framework coordinator
│   ├── Refinement/        MLX LLM queue, prompt builder, downloaders
│   ├── Summary/           Map-reduce summaries; live chunker + note queue; re-transcriber
│   ├── Speaker/           Diarization (sherpa-onnx pyannote segmentation + 3D-Speaker CAM++)
│   ├── Vision/            Vision OCR + image descriptions
│   ├── Chat/              ChatEngine (ask a saved session questions)
│   └── Import/            Audio-file transcription (Voice Memos share sheet)
├── Models/                CaptionEntry, SessionRecord, AppLanguage, SummaryStyle, …
├── Shared/                Live Activity attributes + app-group state (shared with widget)
└── Support/               CaptionPipeline, CaptionStore, SessionArchive, SessionJournal,
                           HotwordStore, ModelCatalog, ThermalMonitor, export/search helpers
LoqiWidgets/               Live Activity UI + Control Center / Lock Screen toggle
LoqiTests/                 Swift Testing logic suite (46 files, ~536 @Test cases)
LoqiUITests/               Onboarding smoke tests
docs/superpowers/          Design specs and implementation plans (dated)
ThirdParty/sherpa-onnx/    Vendored ASR frameworks (gitignored, fetched)
```

Architectural invariants worth knowing before editing:

- **`LLMService.swift` is the only file that touches MLX.** Live transcript cleanup is locked to **LFM2.5-230M** (`ModelCatalog.liveRefineModel`); summary/chat/title/vocabulary/photo-description work uses the selected summary tier (`ModelCatalog.qwen35_2b` default, or Bonsai 8B). The Qwen3.5-0.8B tier survives only as a vision-only fallback for photo back-fill, not the live refiner. Apple's Translation framework — not the LLM — does all translation. All LLM consumers yield to live speech; all LLM work pauses in the background (Metal-in-background kills).
- **The transcript is only ever LLM-*cleaned*, never freely rewritten, and the raw text is always kept.** Live: deterministic Levenshtein/pinyin hotword fixup, then fidelity-gated LFM2.5 sentence cleanup. Offline (imports + re-transcribe): `OfflineTranscriptPolisher` runs the same fixup → LFM2.5 cleanup → second fixup. Every LLM pass is fidelity-gated (a failed gate keeps the raw sentence) and the untouched ASR output is preserved in `SessionRecord.Entry.rawSourceText`. Do not add an LLM step that rewrites transcript text without a fidelity gate and a raw-text preserve.
- `ThermalMonitor` sheds load in order: LLM work first, the LLM itself second — never ASR.
- Crash resilience: `SessionJournal` snapshots the live session on every finalized utterance; recordings write AAC-in-CAF so a mid-write kill stays playable; recovery happens at launch before the orphan sweep.
- Backgrounding while recording unloads the LLM (~1.7GB jetsam target); foreground return reloads and queues catch up.

## Testing

- Framework: **Swift Testing** (`import Testing`, `@Test`, `#expect`; suites are structs, `@MainActor` where UI-bound). Logic suite in `LoqiTests/` runs on the `Loqi` scheme; `LoqiUITests/` is the onboarding smoke test.
- Simulator unit tests are useful for narrow logic checks, but they **do not prove runtime behavior**. Real verification means a physical iPhone — see the "Device verification queue" in `todo.md` for what still needs device passes.
- **Do not claim "builds", "tests pass", or "works on device" unless you ran the relevant command/device pass in the current turn and read the output.**
- Check `ISSUES.md` and `todo.md` (open risk trackers) before claiming a behavior is already verified. Keep README status lines dated when they mention verification evidence.

## Code style and conventions

- Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete` — keep new code warning-free under complete concurrency checking; use `nonisolated(unsafe)` only with a documenting comment (see the `AVAudioPCMBuffer` conversion closures).
- Logging: `os.Logger` with subsystem `com.kunzhipeng.loqi` and a short per-component category (`asr`, `llm`, `refine`, `recorder`, `describe`, …).
- Comments explain **why**, not what; the codebase carries dated decision notes (see `todo.md` style). Match the surrounding file's comment density and idioms.
- Localization: English is the source language; `Loqi/Localizable.xcstrings` (and the widget's own catalog) cover **en, zh-Hans, ja** (~400 strings). Localize all new user-facing strings in all three.
- Keep edits scoped — this codebase has many moving parts. No opportunistic refactors, reformatting, or renaming outside the task.

## Security and privacy

- The product's core promise is **fully on-device processing**: no servers, no accounts, audio/photos never leave the device. The only network traffic is model downloads (Hugging Face or ModelScope 魔搭, user-selected). Preserve this invariant in any change.
- `Loqi/PrivacyInfo.xcprivacy` is the privacy manifest — update it if data collection/required-reason API usage changes.
- Entitlements (`Loqi/Loqi.entitlements`): increased memory limit (needed for the on-device LLM) and app group `group.com.kunzhipeng.loqi` (shared with the widget for recording state). Background mode: `audio`.
- Usage-description strings (mic, speech recognition, camera) live in `project.yml`'s Info.plist properties, not in a hand-edited plist.
- Secrets: none in repo; signing team is per-developer (`DEVELOPMENT_TEAM` in Xcode or `project.yml`, currently unset).

## Distribution

Source-only developer preview: no TestFlight/App Store build. GitHub Releases are source tags + changelogs only — do not attach an `.ipa` unless it is an ad hoc build for known registered devices. License: **PolyForm Noncommercial 1.0.0** (`LICENSE`) — commercial use requires a separate license.

## Available skills

/office-hours, /plan-ceo-review, /plan-eng-review, /plan-design-review, /design-consultation, /design-shotgun, /design-html, /review, /ship, /land-and-deploy, /canary, /benchmark, /browse, /connect-chrome, /qa, /qa-only, /design-review, /setup-browser-cookies, /setup-deploy, /setup-gbrain, /retro, /investigate, /document-release, /document-generate, /codex, /cso, /autoplan, /plan-devex-review, /devex-review, /careful, /freeze, /guard, /unfreeze, /gstack-upgrade, /learn
