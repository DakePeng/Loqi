# Loqi

Private voice notes, transcripts and summaries that run **entirely on your iPhone** — no servers, no internet needed after setup. Live translation included as an optional lens.

- **Main line:** Record → live transcript (with speakers) → instant summary → searchable archive. Pick the same language for both sides and the app is a pure recorder/transcriber; pick different ones and live translation appears alongside.
- **Languages (v1):** Chinese ↔ English ↔ Japanese (+ Korean).
- **How it works:** speech is transcribed live → an on-device LLM (Qwen3.5-2B via MLX, ~1.3 GB) polishes lines, maps the conversation into outline notes as you speak, and writes the summary the moment you stop. When translating, the system Translation framework shows an instant draft that the LLM quietly upgrades using context.
- **Two recognition engines** (Settings → Speech recognition): Apple `SpeechAnalyzer` (instant, word-by-word, zero download) or **SenseVoice-small** via sherpa-onnx (~230 MB, much higher zh/ja/ko/en accuracy, captions update in ~1s pulses). Model downloads from ModelScope 魔搭 (default) or Hugging Face. SenseVoice frameworks: run `Scripts/fetch-sherpa-onnx.sh` once before generating the project.
- **Audio recording:** each session's audio is kept (AAC, ~14 MB/hour) and playable from the session detail — toggle off in Settings.
- **Live summary mapping:** chunk notes generate during silences while you record, so "Summarize" after a long meeting is near-instant, and a "Summary so far" digest is available mid-session.
- **Speaker separation:** tell the app how many people are talking (2–6) and the transcript groups into color-coded speaker blocks, clustered by voice on-device per session (FluidAudio embeddings, ~50MB). Rename speakers any time.
- **Import:** share a recording from Voice Memos (or any audio file) and get the same transcript/speakers/summary treatment.
- **Hotwords:** user-defined names/jargon (Settings → Vocabulary) bias ASR recognition, get near-miss-corrected (Levenshtein / pinyin matching), and steer the LLM toward consistent renderings.
- **Model downloads:** Hugging Face or ModelScope 魔搭 (pick in Settings — use ModelScope where huggingface.co is unreachable). Model tiers: Qwen3.5-2B (default) · Qwen3-1.7B (fallback) · Qwen3.5-0.8B (fastest, ~620MB).

**Requires:** iPhone 15 or newer, iOS 26+, Xcode 26. The LLM does **not** run in the simulator — you need a real device for the full pipeline.

## Getting started (first time on iOS? start here)

1. **Install Xcode 26** from the Mac App Store (it's big — ~10GB+). Launch it once so it installs its tools.
2. **Generate the Xcode project.** This repo uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) so the project file isn't committed:
   ```sh
   brew install xcodegen
   cd ~/Desktop/Locally
   xcodegen generate
   open Loqi.xcodeproj
   ```
3. **Set up signing.** In Xcode: click the blue *Loqi* project icon → *Signing & Capabilities* → check *Automatically manage signing* and pick your team (your Apple ID — add it under Xcode → Settings → Accounts). A free Apple ID works for development but re-signs every 7 days; a paid developer account ($99/yr) removes that and enables TestFlight.
4. **Prepare your iPhone.** Plug it in, tap *Trust* on the phone, and enable **Developer Mode** (Settings → Privacy & Security → Developer Mode, then reboot).
5. **Run.** Select your iPhone as the run destination (top bar) and press ⌘R.

First launch walks through mic permission and downloads the speech models. The LLM (~1.3GB) downloads on first use or via Settings → "Download model now" — do that on Wi-Fi, and pick Hugging Face or ModelScope as the source there.

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
├── Pipeline/
│   ├── Audio/                  Mic capture → AsyncStream; session recorder
│   ├── ASR/                    SpeechAnalyzer wrapper + segmentation logic
│   ├── Translation/            Tier-1: system Translation framework
│   ├── Refinement/             Tier-2: MLX LLM queue + prompt builder
│   ├── Summary/                Map-reduce summaries; live chunker + note queue
│   ├── Speaker/                Diarization (FluidAudio embeddings + clustering)
│   └── Import/                 Audio-file transcription (Voice Memos share)
├── Models/                     CaptionEntry, SessionRecord, AppLanguage
└── Support/                    CaptionPipeline (orchestrator), CaptionStore,
                                SessionArchive, ThermalMonitor, ModelCatalog
LoqiTests/                   Pure-logic tests (run in the simulator)
```

### Architecture in one paragraph

`CaptionPipeline` wires everything: `AudioCaptureService` taps the mic and fans buffers out to the `TranscriptionEngine` (one per language), the diarization tee, and the `SessionRecorder` (AAC file). `TranscriptSegmenter` decides what's worth keeping; `LiveChunker` groups finalized lines into chunks whose notes `ChunkNoteQueue` generates during silences; `RefinementQueue` polishes lines (and translates them when source ≠ target, upgrading `TranslationCoordinator`'s instant drafts) — `LLMService` is the only file that touches MLX, and all LLM consumers yield to live speech. Everything lands in `CaptionStore`, the single observable source of truth the UI renders; on stop, `SessionArchive` persists the transcript, audio file name, and live notes as one record. `ThermalMonitor` sheds load in order: LLM work first, the LLM itself second — never ASR.

## Build-up milestones

The codebase is complete, but if you're learning iOS, verify it in this order (each step is independently testable):

| # | What to verify | How |
|---|---|---|
| 0 | App builds & runs on your iPhone | ⌘R, see the onboarding screen |
| 1 | Mic + level meter | Start a session; the level bar moves when you speak |
| 2 | Live transcript | Speak English; words appear in ~300ms and self-correct. Then try 中文 and 日本語 |
| 3 | Same-language session | 中文→中文: transcript only, ✎-polish improves lines, no translation UI |
| 4 | Translation lens | EN→ZH captions update live; ZH↔JA may pivot through English automatically |
| 5 | LLM loads | Settings → Download model now; "Model state: Ready"; note tok/s feel |
| 6 | Stop → archive | Session appears in Sessions with a playable recording; Summarize is near-instant after a long session |
| 7 | Speakers | 2-person session with speaker count set: color-coded blocks; rename works |
| 8 | Thermal soak | 30-min session in a warm spot; app should shed LLM work, not die |

## Honest status

The app builds clean (Xcode 26.6, Swift 6 strict concurrency), the unit suite passes (95 tests), and the core pipeline — streaming ASR, polish/translation, summaries, model downloads from both sources — is verified working on a real iPhone, fully offline. The capture-first restructure (session audio recording, live summary mapping) is new and needs a device pass. Remaining open items live in [todo.md](todo.md); headline ones: AAC recording path needs real-device verification, diarization thresholds benefit from more multi-speaker calibration, and the thermal/battery soak hasn't been run.

## Not in v1 (by design)

Two-way interpreter mode and TTS output (removed in the capture-first pivot — Apple ships live translation at the OS level) · automatic spoken-language detection · background listening · languages beyond zh/en/ja/ko. The seams exist — see `AppLanguage` and the direction-resolution step in `CaptionPipeline.handle`.
