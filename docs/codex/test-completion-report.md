# Loqi Test Completion Report

Date: 2026-06-18

## Baseline

- Terminal Xcode builds/tests were not run because project instructions forbid terminal Xcode builds/tests unless explicitly allowed.
- Source review found 359 `@Test` declarations across `LoqiTests` and 3 UI tests in `LoqiUITests`.
- `Loqi` scheme tests only `LoqiTests`; `LoqiUITests` has its own scheme (`project.yml:205-223`).
- README claims an older real-device / Xcode 26.6 baseline of 279 passing unit tests, but that is historical text, not fresh verification (`README.md:87-89`).
- No `.github` directory exists in this checkout, so no CI workflow was available to inspect.

## Changes Made

- Added one simulator-safe assertion in `LoqiTests/LLMServiceTests.swift:138-148`: `SummaryJobCenter.shouldSuspendForBackground(.summarizing(...))` is now covered next to downloading and retranscribing.
- Gated the real-network SenseVoice UI test behind `LOQI_RUN_NETWORK_UI_TESTS=1` in `LoqiUITests/OnboardingFlowUITests.swift:97-100`, so normal UI test runs do not download ~240 MB of model weights.
- Added `GenerationCollectionTests` in `LoqiTests/LLMServiceTests.swift:68-101` for LLM stream cancellation and chunk concatenation.
- Fixed security-scoped import cleanup with `defer` in `Loqi/Pipeline/Import/FileImportEngine.swift:52-58`.
- Made session JSON persistence atomic in `Loqi/Support/SessionArchive.swift:264-272`.
- Added `docs/codex/manual-xcode-verification.md` as the checked manual verification artifact while CI is absent.

## Existing Coverage By Source Review

- Pipeline/resource decisions: `LLMServiceTests`, `ProcessingETATests`, `LiveChunkerTests`, `ChunkNoteQueueTests`.
- Summary logic: `SummaryEngineTests`, `SummaryAccuracyTests`, `SummaryDiffTests`, `SummaryLengthTests`, `SummaryStyleTests`, `PromptBuilderTests`.
- Persistence/export/search: `SessionRecordTests`, `SessionJournalTests`, `CaptionStoreTests`, `SubtitleExporterTests`, `SessionSearchTests`.
- Import/download logic: `ImportEngineTests`, `SegmentedDownloaderTests`, `ModelScopeDownloaderTests`, `ModelCatalogTests`, `OnboardingCatalogTests`.
- Speech/speaker support logic: `TranscriptSegmenterTests`, `SpeechRunLimiterTests`, `VoiceprintMathTests`, `SpeakerAttributionTests`, `FarFieldGainTests`.
- Intents/widgets helpers: `RecordingIntentsTests`, shared-state coverage through pure decode helpers.
- UI onboarding smoke tests: `OnboardingFlowUITests`.

## Gaps

- No fresh Xcode compile/test result was produced in this run.
- No real-device mic/camera/Live Activity/Control Center/Action Button test was run.
- No MLX, FluidAudio, Apple SpeechAnalyzer, TranslationSession, or model-download integration test was run.
- `SummaryJobCenter` background resume behavior has pure predicate coverage, but not a full async lifecycle test.
- `FileImportEngine` security-scoped resource failure path is fixed in source but not directly unit-tested; the useful behavior is the `defer` placement itself.
- `LoqiMac` was inspected by manifest/source review only; no macOS build was run.

## Commands Run

| Command | Output / Use |
|---|---|
| `git status --short` | Captured initial dirty tree before edits. |
| `rg -n "@Test" LoqiTests \| wc -l` | `359`. |
| `rg -c "@Test" LoqiTests \| sort` | Per-file unit-test counts captured. |
| `rg -n "XCTest\|func test" LoqiUITests` | Found 3 UI tests. |
| `plutil -lint ...` | All plist/privacy/entitlement files reported `OK`. |
| `xcrun simctl list devices available` | iOS 26.5 simulators available; all Shutdown. |
| `brew list xcodegen >/dev/null 2>&1 || brew install xcodegen` | Installed XcodeGen 2.45.4. |
| `xcodegen --version` | `Version: 2.45.4`. |
| Temp-root `xcodegen generate` + `diff -q` | Generation succeeded outside the repo; `project.pbxproj` drift is present. |
| `git diff --check` | Exit 0, no output. |

## Manual Xcode Verification

Do these in Xcode, not terminal, per `AGENTS.md`:

1. Open `Loqi.xcodeproj`.
2. Select a real iPhone for `Loqi`; build and run.
3. Complete onboarding or reset it with the UI-test argument only inside the UI test scheme.
4. Run `LoqiTests` from the `Loqi` scheme.
5. Run `LoqiUITests` only when appropriate. Leave `LOQI_RUN_NETWORK_UI_TESTS` unset for a simulator-safe run. Set `LOQI_RUN_NETWORK_UI_TESTS=1` only when intentionally downloading SenseVoice.
6. Build `LoqiMac` with the `LoqiMac` scheme.
7. On a real device, verify mic capture, stop/archive, playback, speaker setting, camera attachment, summarize, Live Activity stop, Control Center toggle, and background/foreground behavior.

If terminal verification is later allowed, the constrained build command from repo instructions is:

```sh
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1
```

No `xcodebuild install` was run.

## Blockers

- Terminal Xcode test/build was not allowed.
- Real-device-only features require hardware and signing/provisioning.
- Real `xcodegen generate` was not run. A temp-root generation shows `Loqi.xcodeproj/project.pbxproj` drift, including local signing metadata absent from `project.yml`.
