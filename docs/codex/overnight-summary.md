# Loqi Overnight Summary

Date: 2026-06-18

## Reports

- `docs/codex/architecture-audit.md`
- `docs/codex/test-completion-report.md`
- `docs/codex/issue-review.md`
- `docs/codex/overnight-summary.md`
- `docs/codex/manual-xcode-verification.md`

## Initial Git Status

Captured before repo edits with `git status --short`:

```text
 M AGENTS.md
 M Loqi/Features/Captions/LiveCaptionsView.swift
 M Loqi/Pipeline/Summary/SummaryEngine.swift
 M Loqi/Pipeline/Summary/SummaryJobCenter.swift
 M Loqi/Support/CaptionPipeline.swift
 M LoqiTests/SummaryEngineTests.swift
?? build/
?? docs/superpowers/plans/2026-06-18-fix-map-summary-review.md
```

Those initial changes were treated as user-owned.

## Changes Made In This Pass

- Created `docs/codex/`.
- Added the four requested reports.
- Updated `LoqiTests/LLMServiceTests.swift` with one simulator-safe assertion covering background suspension for `.summarizing`.
- Updated `LoqiUITests/OnboardingFlowUITests.swift` so the real-network SenseVoice download test is skipped unless `LOQI_RUN_NETWORK_UI_TESTS=1`.
- Added `GenerationCollectionTests` and changed `LLMService` generation collection to throw on cancellation instead of returning partial text.
- Moved security-scoped import cleanup into `defer`.
- Made session JSON writes atomic.
- Installed XcodeGen 2.45.4 with Homebrew.
- Verified XcodeGen can generate in a temp root and confirmed checked-in `Loqi.xcodeproj/project.pbxproj` drift.
- Added `docs/codex/manual-xcode-verification.md`.

## Verification

Run:

```sh
plutil -lint Loqi/Info.plist LoqiMac/Info.plist LoqiWidgets/Info.plist Loqi/PrivacyInfo.xcprivacy Loqi/Loqi.entitlements LoqiMac/LoqiMac.entitlements LoqiWidgets/LoqiWidgets.entitlements
```

Output:

```text
Loqi/Info.plist: OK
LoqiMac/Info.plist: OK
LoqiWidgets/Info.plist: OK
Loqi/PrivacyInfo.xcprivacy: OK
Loqi/Loqi.entitlements: OK
LoqiMac/LoqiMac.entitlements: OK
LoqiWidgets/LoqiWidgets.entitlements: OK
```

Also run:

- `xcode-select -p` -> `/Applications/Xcode.app/Contents/Developer`
- `xcrun --find xcodebuild` -> `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild`
- `xcrun simctl list devices available` -> iOS 26.5 simulator devices available, all Shutdown.
- `brew list xcodegen >/dev/null 2>&1 || brew install xcodegen` -> installed XcodeGen 2.45.4.
- `xcodegen --version` -> `Version: 2.45.4`.
- Temp-root `xcodegen generate` -> created `/tmp/loqi-xgenroot.218pRg/Loqi.xcodeproj`.
- `diff -q Loqi.xcodeproj/project.pbxproj /tmp/loqi-xgenroot.218pRg/Loqi.xcodeproj/project.pbxproj` -> files differ.
- `git diff --check` -> exit 0, no output.

Not run by rule:

- No `xcodebuild build`.
- No `xcodebuild test`.
- No `xcodebuild install`.
- No model downloads.
- No `Scripts/fetch-sherpa-onnx.sh`.
- No real-repo `xcodegen generate`; avoided overwriting local generated-project signing/settings.

## Manual Build/Test Steps

1. Open `Loqi.xcodeproj` in Xcode.
2. Select a real iPhone and build/run `Loqi`.
3. Run `LoqiTests` from the `Loqi` scheme.
4. Run `LoqiUITests` only when appropriate. Leave `LOQI_RUN_NETWORK_UI_TESTS` unset for a simulator-safe run. Set it to `1` only when intentionally testing the SenseVoice download.
5. Build `LoqiMac`.
6. On device, verify mic capture, recording stop/archive, playback, camera attachment, summarize, Live Activity stop, Control Center toggle, and background/foreground behavior.

If terminal verification is later allowed, use the constrained command from `AGENTS.md`:

```sh
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1
```

## Blockers

- Terminal Xcode build/test was not allowed.
- Real-device-only APIs were source-reviewed only.
- XcodeGen is now installed and temp generation succeeds, but real project regeneration was not run. Drift is present and includes local signing metadata absent from `project.yml`.

## Completion Audit

| Requirement | Evidence | Status |
|---|---|---|
| Four requested reports exist | `find docs/codex -maxdepth 1 -type f -print` lists the four reports plus the manual checklist. | Done |
| Small clear source issues addressed | `issue-review.md` marks LLM cancellation, security-scoped cleanup, UI network-test gating, session atomic writes, and summarize suspension coverage fixed or mitigated. | Done pending Xcode compile/test |
| Safe non-Xcode checks run | `plutil -lint ...`, `git diff --check`, Xcode CLI discovery, simulator list, XcodeGen install/version, and temp-root XcodeGen generation were run. | Done |
| Simulator-safe tests complete | New/updated tests are present, but `LoqiTests` and `LoqiUITests` were not run because terminal Xcode tests are disallowed. | Blocked |
| Real-device checks complete | Manual Xcode/device checklist exists, but mic/camera/Live Activity/Control Center/LLM runtime checks were not run. | Blocked |
| Generated project refreshed | Temp-root generation proves drift; real `xcodegen generate` was not run to avoid overwriting local signing/project settings. | Blocked until intentional regeneration |

## Device Notes

- Treat mic/camera, Live Activities/Dynamic Island, Control Center toggle, on-device LLM runtime, FluidAudio/CoreML diarization, and full model downloads as real-device-only unless a fake exists.
- Simulator-safe checks should stay pure and deterministic.

## Final Git Status

Captured after report writes with `git status --short`:

```text
 M AGENTS.md
 M Loqi/Features/Captions/LiveCaptionsView.swift
 M Loqi/Pipeline/Import/FileImportEngine.swift
 M Loqi/Pipeline/Refinement/LLMService.swift
 M Loqi/Pipeline/Summary/SummaryEngine.swift
 M Loqi/Pipeline/Summary/SummaryJobCenter.swift
 M Loqi/Support/CaptionPipeline.swift
 M Loqi/Support/SessionArchive.swift
 M LoqiTests/LLMServiceTests.swift
 M LoqiTests/SummaryEngineTests.swift
 M LoqiUITests/OnboardingFlowUITests.swift
?? build/
?? docs/codex/
?? docs/superpowers/plans/2026-06-18-fix-map-summary-review.md
```
