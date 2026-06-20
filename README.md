# Loqi

Private voice notes, transcripts and summaries that run **entirely on your iPhone** — no servers, no internet needed after setup. Live translation included as an optional lens.

- **Main line:** Record → live transcript (with speakers) → instant summary → searchable archive. Pick the same language for both sides and the app is a pure recorder/transcriber; pick different ones and live translation appears alongside.
- **Languages (v1):** Chinese ↔ English ↔ Japanese (+ Korean).
- **How it works:** speech is transcribed live → an on-device LLM (Qwen3.5-2B via MLX, ~1.75 GB) maps the conversation into outline notes as you speak and writes the summary the moment you stop. The transcript itself is never LLM-rewritten — only the deterministic hotword fixup (plus a strictly-scoped vocabulary restore at summarize time) touches it. When translating, the system Translation framework shows an instant draft that the LLM quietly upgrades using context.
- **Two recognition engines** (Settings → Speech recognition): Apple `SpeechAnalyzer` (instant, word-by-word, zero download) or **SenseVoice-small** via sherpa-onnx (~230 MB, much higher zh/ja/ko/en accuracy, captions update in ~1s pulses). Model downloads from ModelScope 魔搭 (default) or Hugging Face. SenseVoice frameworks: run `Scripts/fetch-sherpa-onnx.sh` once before generating the project.
- **High-accuracy second pass (optional):** download **Qwen3-ASR-0.6B** (Settings → High-accuracy re-transcription, ~990 MB, HF or ModelScope) and "Re-transcribe & summarize" plus imports use it automatically — a Speech-LLM (Whisper-style encoder → Qwen3 decoder, 52 languages) that's slower than live recognition but noticeably more accurate, primed with your vocabulary hotwords (which SenseVoice can't do). Live captions stay on the fast engines.
- **Audio recording:** each session's audio is kept (AAC in a crash-tolerant CAF container, ~14 MB/hour) and playable from the session detail — toggle off in Settings. If the app is ever killed mid-recording (crash, memory pressure), the next launch recovers the session — transcript, notes, and audio up to the kill — and says so.
- **Live summary mapping:** chunk notes generate during silences while you record, so "Summarize" after a long meeting is near-instant, and a "Summary so far" digest is available mid-session.
- **Speaker separation:** tell the app how many people are talking (2–6, or Auto to detect the count) and the transcript groups into color-coded speaker blocks, clustered by voice on-device per session (FluidAudio embeddings, ~50MB). Rename speakers any time.
- **Mic pickup presets:** Close-up / Balanced / Meeting room tune the capture boost and both engines' voice-activity detection for the situation — switchable mid-recording from the Record bar. Meeting room reaches for talkers across the table; Close-up keeps background voices out of the transcript.
- **Import:** share a recording from Voice Memos (or any audio file) and get the same transcript/speakers/summary treatment.
- **Photo attachments:** snap slides/whiteboards mid-recording (camera button on the recording bar — a capture path that can't interrupt the mic) or add photos to a saved session. On-device Vision OCR (zh/ja/ko/en) feeds the extracted text into the summary, chat answers, and search; thumbnails sit inline in the transcript. Qwen3.5 is natively multimodal, so photos additionally get an LLM description (diagrams, not just text) from the default model — no separate vision tier.
- **Search:** the Sessions tab searches every transcript, summary, speaker name, session title, and photo text (CJK-safe); results jump to the matching line.
- **Tap to replay:** tap any transcript line in a saved session to hear that moment (offsets stay accurate across interruptions).
- **Titles + subtitle export:** sessions auto-title themselves after summarizing (rename anytime); export Markdown, SRT (mono or bilingual), or WebVTT.
- **Chat with a session:** ask a saved session questions ("what were the action items?") — answered on-device from its notes and transcript, in the language you ask in.
- **Frictionless capture:** recording keeps going with the screen locked (LLM work pauses and catches up); a Live Activity / Dynamic Island shows elapsed time with a stop button; start/stop from Siri ("Start recording with Loqi"), the Action Button, or a Control Center toggle.
- **Hotwords:** user-defined names/jargon (Settings → Vocabulary) bias ASR recognition, get near-miss-corrected (Levenshtein / pinyin matching), and steer the LLM toward consistent renderings.
- **Model downloads:** Hugging Face or ModelScope 魔搭 (pick in Settings — use ModelScope where huggingface.co is unreachable). Model tiers: Qwen3.5-2B (default, ~1.75GB) · Qwen3.5-0.8B (fastest, ~650MB) — both natively multimodal (text + photos), so the old Qwen3 text/VL tiers are gone. A repetition-penalty bug in mlx-swift-lm 3.31.3 that crashed every generation routed through the VLM factory (2-D prompts corrupt its TokenRing) is patched locally in `LLMService` — remove the wrapper when the dependency moves past 3.31.3.

**Requires:** a Mac with Xcode 26, iPhone 15 or newer, iOS 26+, and Developer Mode on the phone. The LLM does **not** run in the simulator — you need a real device for the full pipeline.

## Developer preview

Loqi is currently a **source-only developer preview**. There is no TestFlight/App Store build yet, and GitHub does not host an installable iPhone app. The supported install path is: clone the repo, generate/open the Xcode project, set your own signing team, and run on a physical iPhone.

A free Apple ID can sign local development builds, but installed builds may expire after 7 days. The widget and Control Center toggle use an app group; if a free team cannot provision that entitlement, the core app still runs but those surfaces may show stale state. TestFlight/App Store distribution requires a paid Apple Developer Program membership and is not part of this preview.

## Getting started (first time on iOS? start here)

1. **Install Xcode 26** from the Mac App Store (it's big — ~10GB+). Launch it once so it installs its tools.
2. **Refresh the Xcode project if needed.** This repo uses [XcodeGen](https://github.com/yonaskolb/XcodeGen): `project.yml` is the source of truth, and `Loqi.xcodeproj` is committed for convenience. Regenerate after changing targets, packages, build settings, or entitlements. The sherpa-onnx frameworks are vendored under `ThirdParty/`; run the fetch script only if they are missing or stale.
   ```sh
   brew install xcodegen
   cd ~/Desktop/Loqi
   Scripts/fetch-sherpa-onnx.sh   # only if ThirdParty/sherpa-onnx is missing/stale
   xcodegen generate
   open Loqi.xcodeproj
   ```
3. **Set up signing.** In Xcode: click the blue *Loqi* project icon → *Signing & Capabilities* → check *Automatically manage signing* and pick your team (your Apple ID — add it under Xcode → Settings → Accounts) — do the same for the *LoqiWidgets* target. A free Apple ID works for local development signing, but installed builds may expire after 7 days. Note: free teams sometimes fail to provision the app group both targets share — everything still works except the Control Center toggle showing stale state.
4. **Prepare your iPhone.** Plug it in, tap *Trust* on the phone, and enable **Developer Mode** (Settings → Privacy & Security → Developer Mode, then reboot).
5. **Run.** Select your iPhone as the run destination (top bar) and press ⌘R.

First launch walks through mic permission and downloads the speech models. The LLM (~1.75GB) downloads **only when you ask**: via Settings → "Download model now", or from the consent prompt the first AI feature (summarize, chat, suggestions) shows — do that on Wi-Fi, and pick Hugging Face or ModelScope as the source. Until it's downloaded the app transcribes and records normally, with a status pill pointing to Settings.

## Releases

GitHub Releases are source tags and changelogs for now, not signed `.ipa` downloads. Do not attach an `.ipa` unless it is an ad hoc build for known registered devices.

## Project layout

```
Loqi/
├── LoqiApp.swift            App entry; tabs + translation host stack
├── Features/                   SwiftUI screens
│   ├── Captions/               Record tab: live transcript + controls
│   ├── Sessions/               Archive: detail, playback, summaries, import
│   ├── Onboarding/             Permission + model download flow
│   ├── Settings/               Model pickers, recording toggle, diagnostics
│   └── Shared/                 Status bar, mic button, caption rows
├── Intents/                    Siri, Shortcuts, Action Button, widget intents
├── Pipeline/
│   ├── Audio/                  Mic capture → AsyncStream; CAF/AAC recorder
│   ├── ASR/                    Apple SpeechAnalyzer, SenseVoice, Qwen3-ASR
│   ├── Translation/            Tier-1: system Translation framework
│   ├── Refinement/             Tier-2: MLX LLM queue + prompt builder
│   ├── Summary/                Map-reduce summaries; live chunker + note queue
│   ├── Speaker/                Diarization (FluidAudio embeddings + clustering)
│   ├── Vision/                 Vision OCR + Qwen3.5 image descriptions
│   └── Import/                 Audio-file transcription (Voice Memos share)
├── Models/                     CaptionEntry, SessionRecord, AppLanguage
├── Shared/                     Live Activity attributes + app-group state
└── Support/                    CaptionPipeline, CaptionStore, SessionArchive,
                                HotwordStore, ModelCatalog, export/search helpers
LoqiWidgets/                 Live Activity UI + Control Center / Lock Screen toggle
LoqiTests/                   Swift Testing logic suite
LoqiUITests/                 Onboarding smoke tests
LoqiMac/                     Buildable Mac target, not a v1 shipped surface
project.yml                  XcodeGen manifest; edit this before regenerating
```

### Architecture in one paragraph

`CaptionPipeline` wires everything: `AudioCaptureService` taps the mic and fans buffers out to the chosen live ASR engine (Apple `SpeechAnalyzer` or SenseVoice), streaming diarization, and `SessionRecorder` (AAC-in-CAF for crash tolerance). `TranscriptSegmenter` decides what's worth keeping; `LiveChunker` groups finalized lines into chunks whose notes `ChunkNoteQueue` generates during silences; `RefinementQueue` upgrades `TranslationCoordinator`'s instant draft translations when source ≠ target (transcript text itself is never LLM-rewritten). `SummaryJobCenter` owns post-hoc imports, Qwen3-ASR re-transcription, and summarize jobs so navigation cannot double-run them. `LLMService` is the only file that touches MLX; live work uses the fixed 0.8B tier, summary/chat/title/vocabulary work uses the selected summary tier, and all LLM consumers yield to live speech. Everything lands in `CaptionStore`, the observable source of truth the UI renders; on stop, `SessionArchive` persists transcript, audio file name, attachments, chat history, and live notes as one record. `ThermalMonitor` sheds load in order: LLM work first, the LLM itself second — never ASR.

## Build-up milestones

The codebase is complete, but if you're learning iOS, verify it in this order (each step is independently testable):

| # | What to verify | How |
|---|---|---|
| 0 | App builds & runs on your iPhone | ⌘R, see the onboarding screen |
| 1 | Mic + level meter | Start a session; the level bar moves when you speak |
| 2 | Live transcript | Speak English; words appear in ~300ms and self-correct. Then try 中文 and 日本語 |
| 3 | Same-language session | 中文→中文: transcript only, no translation UI |
| 4 | Translation lens | EN→ZH captions update live; ZH↔JA may pivot through English automatically |
| 5 | LLM loads | Settings → Download model now; "Model state: Ready"; note tok/s feel |
| 6 | Stop → archive | Session appears in Sessions with a playable recording; Summarize is near-instant after a long session |
| 7 | Speakers | 2-person session with speaker count set: color-coded blocks; rename works |
| 8 | Thermal soak | 30-min session in a warm spot; app should shed LLM work, not die |

## Honest status

Latest docs scan: 2026-06-20. The repo is an iOS-first Swift 6 / XcodeGen app with a widget extension, a buildable-but-unshipped Mac target, a broad Swift Testing logic suite, and onboarding UI smoke tests. This README refresh did not run a fresh Xcode build or real-device pass; older green-build notes in [todo.md](todo.md) are historical evidence, not current proof. Remaining open items live in [ISSUES.md](ISSUES.md) and [todo.md](todo.md): large imports and photo processing can still hitch the UI, Swift concurrency / plist warning cleanup remains, and the multimodal Qwen3.5 default plus crash-recovery / thermal behavior still deserve a real-iPhone verification pass.

## Not in v1 (by design)

Two-way interpreter mode and TTS output (removed in the capture-first pivot — Apple ships live translation at the OS level) · a supported Mac / desktop app (the iPhone app is the v1 focus; the existing Mac target is not a shipped surface) · automatic spoken-language detection · always-on ambient listening (an explicitly started session does continue in the background) · languages beyond zh/en/ja/ko. The seams exist — see `AppLanguage` and the direction-resolution step in `CaptionPipeline.handle`.
