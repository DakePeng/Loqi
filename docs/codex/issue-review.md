# Loqi Issue Review

Date: 2026-06-18

## Findings

### P1 - Cancelled MLX generation can return partial text

- Path: `Loqi/Pipeline/Refinement/LLMService.swift:337-343`, `:453-459`.
- Initial evidence: `generate` and `describeImage` checked `Task.isCancelled`, `break`, and returned the accumulated text. `ChunkNoteQueue` expects `CancellationError` to requeue on speech/background pause, and `AttachmentDescribeQueue` expects cancellation to retry/drop safely.
- Impact: A background transition or speech-resume cancellation can be treated as a successful partial generation. That can produce fallback/partial notes, stale photo descriptions, or a job that continues through a path intended to stop.
- Fix: Throw `CancellationError` after cancellation inside both token loops, then add a fake generator seam or narrow unit test around queue cancellation.
- Fixed: Yes in source. `LLMService.collectGeneratedText` now checks cancellation and is used by both text and image generation (`Loqi/Pipeline/Refinement/LLMService.swift:336-341`, `:386-398`, `:463-470`). `GenerationCollectionTests` covers cancellation and concatenation (`LoqiTests/LLMServiceTests.swift:68-101`). Xcode tests still need a manual run.

### P2 - Security-scoped import resource is not released if copy fails

- Path: `Loqi/Pipeline/Import/FileImportEngine.swift:52-57`.
- Initial evidence: `startAccessingSecurityScopedResource()` was called, then `copyItem` could throw before `stopAccessingSecurityScopedResource()` ran.
- Impact: Failed imports from Files/Voice Memos can leak a scoped resource for the process lifetime.
- Fix: Put the stop call in a `defer` immediately after `startAccessingSecurityScopedResource()`.
- Fixed: Yes in source. The scoped resource release is now in `defer` (`Loqi/Pipeline/Import/FileImportEngine.swift:52-58`).

### P2 - UI test could download model weights during normal simulator runs

- Path: `LoqiUITests/OnboardingFlowUITests.swift:93-100`.
- Evidence: `testSenseVoiceOnlyDownloadCompletes` documents a real ~240 MB SenseVoice download and previously ran without a guard.
- Impact: Accidental UI test runs could download model weights, violate simulator-safe audit rules, and make tests slow/flaky.
- Fix: Gate the test behind `LOQI_RUN_NETWORK_UI_TESTS=1`.
- Fixed: Yes, in this pass.

### P2 - XcodeGen is not installed locally

- Path: `project.yml`, generated `Loqi.xcodeproj`.
- Initial evidence: `xcodegen --version` returned `zsh:1: command not found: xcodegen`; `project.yml` is tracked while `Loqi.xcodeproj` is generated/untracked.
- Impact: Cannot regenerate the project or prove generated project parity with the manifest on this machine.
- Fix: Install XcodeGen (`brew install xcodegen`) and run `xcodegen generate` only when ready to refresh the generated project.
- Fixed: Partially. Homebrew installed XcodeGen 2.45.4; `xcodegen --version` now reports `Version: 2.45.4`. A temp-root generation succeeded at `/tmp/loqi-xgenroot.218pRg`, and `diff -q Loqi.xcodeproj/project.pbxproj /tmp/loqi-xgenroot.218pRg/Loqi.xcodeproj/project.pbxproj` reported drift. The sampled diff includes `DEVELOPMENT_TEAM = K2WK8HQC4L` in the current generated project while `project.yml` only has a commented example. The real `Loqi.xcodeproj` was not regenerated to avoid overwriting local signing/settings.

### P2 - No CI workflow is present in this checkout

- Path: repository root.
- Evidence: `find .github -maxdepth 3 -type f -print` returned `find: .github: No such file or directory`.
- Impact: Build/test regressions depend on manual Xcode runs.
- Fix: Add a CI workflow or a checked manual verification checklist with required Xcode schemes.
- Fixed: Mitigated. Added `docs/codex/manual-xcode-verification.md` with required simulator-safe and real-device Xcode checks. No CI workflow was added.

### P3 - Session JSON writes are not atomic

- Path: `Loqi/Support/SessionArchive.swift:264-272`.
- Initial evidence: `persist(_:)` wrote encoded JSON with `data.write(to:)` and no `.atomic` option.
- Impact: A crash or power loss during write can corrupt or truncate a session file.
- Fix: Use `data.write(to: ..., options: .atomic)` and consider surfacing encode/write failures in diagnostics.
- Fixed: Yes in source. `persist(_:)` now writes with `.atomic` (`Loqi/Support/SessionArchive.swift:264-272`).

### P3 - Working-tree summary action dedupe fix looks correct but needs Xcode verification

- Path: `Loqi/Pipeline/Summary/SummaryEngine.swift:631-653`, `:679-680`; `LoqiTests/SummaryEngineTests.swift`.
- Evidence: The working tree changes dedupe action records by rendered action text, including owner/deadline, and add a test for same-task different-owner actions.
- Impact: Prevents dropping distinct action items that share the same task text.
- Fix: Already present in the pre-existing working tree diff.
- Fixed: Yes in working tree, but not freshly run due no terminal Xcode tests.

### P3 - Background summarize suspension predicate needed direct coverage

- Path: `Loqi/Pipeline/Summary/SummaryJobCenter.swift:208-215`; `LoqiTests/LLMServiceTests.swift:138-148`.
- Evidence: Predicate includes `.summarizing`, but the existing test covered downloading/retranscribing/import only.
- Impact: A future edit could accidentally stop suspending summarize jobs in background.
- Fix: Added direct `.summarizing(done:total:)` assertion.
- Fixed: Yes, in this pass.

## Non-findings

- Third-party sherpa frameworks are present under `ThirdParty/sherpa-onnx`; `Scripts/fetch-sherpa-onnx.sh` was not needed.
- Plist, privacy manifest, and entitlement files linted clean.
- Xcode CLI selection is not broken: `xcode-select -p` returned `/Applications/Xcode.app/Contents/Developer`.

## Review Scope

Reviewed `project.yml`, target/scheme layout, app entry points, `CaptionPipeline`, `SummaryJobCenter`, `SummaryEngine`, `LLMService`, import/download/model stores, widgets/intents/shared state, persistence, privacy/entitlements, tests, and current working-tree diff. Terminal Xcode builds/tests were intentionally not run.
