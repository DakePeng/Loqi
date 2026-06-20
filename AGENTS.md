# gstack

Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools.

Prefer manual Xcode builds/runs for this project. It requires a real iPhone for runtime verification; do not run simulator tests/runs as a substitute. Avoid `xcodebuild install` unless explicitly asked; if a CLI build is needed, use a constrained build such as `xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1`.

## Repo map

- Loqi is an iOS-first Swift 6 / Xcode 26 app. `project.yml` is canonical; `Loqi.xcodeproj` is committed convenience output and should be regenerated with `xcodegen generate` after target/package/build-setting changes.
- Main surfaces: `Loqi/Features/Captions` (Record), `Loqi/Features/Sessions` (archive/import/playback/chat), `Loqi/Features/Vocabulary`, `Loqi/Features/Settings`, `LoqiWidgets` (Live Activity + Control Center / Lock Screen toggle).
- Main pipeline: `Loqi/Support/CaptionPipeline.swift` orchestrates mic capture, ASR, diarization, translation, recording, live notes, crash recovery, and archive writes. `SummaryJobCenter` owns post-hoc import / re-transcribe / summarize jobs.
- ASR options live in `Loqi/Pipeline/ASR`: Apple `SpeechAnalyzer`, SenseVoice via sherpa-onnx, and optional Qwen3-ASR second pass. The sherpa frameworks live under `ThirdParty/sherpa-onnx`; use `Scripts/fetch-sherpa-onnx.sh` only when those frameworks are missing or stale.
- MLX usage is isolated in `Loqi/Pipeline/Refinement/LLMService.swift`. The app uses Qwen3.5 0.8B for live work and the selected summary tier for post-session summaries/chat/title/vocabulary/photo description.
- Open risk trackers are `ISSUES.md` and `todo.md`; check them before claiming a behavior is already verified.

## Working rules

- For code search, use `rg` first. Keep edits scoped; this codebase already has plenty of moving parts.
- Simulator unit tests can be useful for narrow logic checks, but they do not prove runtime behavior. Real verification means a physical iPhone.
- Do not claim "builds", "tests pass", or "works on device" unless you ran the relevant command/device pass in the current turn and read the output.
- Keep README status lines dated when they mention verification evidence.

Available skills:
/office-hours, /plan-ceo-review, /plan-eng-review, /plan-design-review, /design-consultation, /design-shotgun, /design-html, /review, /ship, /land-and-deploy, /canary, /benchmark, /browse, /connect-chrome, /qa, /qa-only, /design-review, /setup-browser-cookies, /setup-deploy, /setup-gbrain, /retro, /investigate, /document-release, /document-generate, /codex, /cso, /autoplan, /plan-devex-review, /devex-review, /careful, /freeze, /guard, /unfreeze, /gstack-upgrade, /learn
