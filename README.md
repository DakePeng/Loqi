# Locally

Real-time speech translation that runs **entirely on your iPhone** — no servers, no internet needed after setup.

- **Two modes:** face-to-face Conversation (split screen, tap-to-talk per side) and one-way Live Captions (lectures, meetings, videos).
- **Languages (v1):** Chinese ↔ English ↔ Japanese.
- **How it works:** Apple's `SpeechAnalyzer` streams the transcript → the system Translation framework shows an instant draft → an on-device LLM (Qwen3.5-2B via MLX, ~1.3 GB) quietly upgrades the draft using conversation context (honorifics, register, pronouns).
- **Model downloads:** Hugging Face or ModelScope 魔搭 (pick in Settings — use ModelScope where huggingface.co is unreachable).
- **Hotwords:** user-defined names/jargon (Settings → Vocabulary) bias ASR recognition, get near-miss-corrected before translation (Levenshtein / pinyin matching), and steer the LLM toward consistent renderings per language.
- **VAD:** Apple's iOS 26 `SpeechDetector` runs in the same analyzer — LLM work yields to live speech, and utterance boundaries drive voiceprint classification.
- **Automatic turns (beta):** conversation mode can learn each speaker's voice from a few manual turns (FluidAudio speaker embeddings, on-device, ~50MB) and then switch the mic automatically. Profiles stay on the iPhone; reset anytime in Settings.
- **Speaker separation (captions):** tell the app how many people are talking (2–6) and the transcript groups into color-coded speaker blocks, clustered by voice on-device per session.
- **Model tiers:** Qwen3.5-2B (default) · Qwen3-1.7B (fallback) · Qwen3.5-0.8B (fastest, ~620MB) — pick in Settings.

**Requires:** iPhone 15 or newer, iOS 26+, Xcode 26. The LLM does **not** run in the simulator — you need a real device for the full pipeline.

## Getting started (first time on iOS? start here)

1. **Install Xcode 26** from the Mac App Store (it's big — ~10GB+). Launch it once so it installs its tools.
2. **Generate the Xcode project.** This repo uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) so the project file isn't committed:
   ```sh
   brew install xcodegen
   cd ~/Desktop/Locally
   xcodegen generate
   open Locally.xcodeproj
   ```
3. **Set up signing.** In Xcode: click the blue *Locally* project icon → *Signing & Capabilities* → check *Automatically manage signing* and pick your team (your Apple ID — add it under Xcode → Settings → Accounts). A free Apple ID works for development but re-signs every 7 days; a paid developer account ($99/yr) removes that and enables TestFlight.
4. **Prepare your iPhone.** Plug it in, tap *Trust* on the phone, and enable **Developer Mode** (Settings → Privacy & Security → Developer Mode, then reboot).
5. **Run.** Select your iPhone as the run destination (top bar) and press ⌘R.

First launch walks through mic permission and downloads the speech models for all three languages. The LLM (~1.3GB) downloads on first use or via Settings → "Download model now" — do that on Wi-Fi, and pick Hugging Face or ModelScope as the source there.

## Project layout

```
Locally/
├── LocallyApp.swift            App entry; mounts the translation host stack
├── Features/                   SwiftUI screens
│   ├── Captions/               One-way live captions mode
│   ├── Conversation/           Two-way split-screen mode
│   ├── Onboarding/             Permission + model download flow
│   └── Settings/               Model picker + diagnostics
├── Pipeline/
│   ├── Audio/                  AVAudioEngine mic capture → AsyncStream
│   ├── ASR/                    SpeechAnalyzer wrapper + segmentation logic
│   ├── Translation/            Tier-1: system Translation framework
│   └── Refinement/             Tier-2: MLX LLM queue + prompt builder
├── Models/                     CaptionEntry, AppLanguage, events
└── Support/                    CaptionPipeline (orchestrator), CaptionStore,
                                ThermalMonitor, ModelCatalog, AssetManager
LocallyTests/                   Pure-logic tests (run in the simulator)
```

### Architecture in one paragraph

`CaptionPipeline` wires everything: `AudioCaptureService` taps the mic and converts buffers to the analyzer's format; `TranscriptionEngine` (one per language) streams volatile/finalized text; `TranscriptSegmenter` decides what's worth translating and refining; `TranslationCoordinator` produces instant drafts (debounced for in-progress text) through hidden `.translationTask` host views; `RefinementQueue` feeds finalized sentences to `LLMService` (the only file that touches MLX) one at a time; everything lands in `CaptionStore`, the single observable source of truth the UI renders. Caption rows keep a stable `id` while ASR revises text, so SwiftUI updates rows in place without flicker. `ThermalMonitor` sheds load in order: LLM refinement first, the LLM itself second — never ASR or drafts.

## Build-up milestones

The codebase is complete, but if you're learning iOS, verify it in this order (each step is independently testable):

| # | What to verify | How |
|---|---|---|
| 0 | App builds & runs on your iPhone | ⌘R, see the onboarding screen |
| 1 | Mic + level meter | Start a captions session; the level bar moves when you speak |
| 2 | Live transcript | Speak English; words appear in ~300ms and self-correct. Then try 中文 and 日本語 |
| 3 | Draft translation | EN→ZH captions update live. **Also check whether ZH↔JA translates directly** — if the pair is unsupported the app pivots through English automatically |
| 4 | Captions endurance | Play a 10-min lecture; watch Xcode's memory gauge stay flat |
| 5 | LLM loads | Settings → Download model now; "Model state: Ready"; note tok/s feel |
| 6 | Refinement | Speak a long polite Japanese sentence: instant draft, ✨-marked upgrade seconds later |
| 7 | Conversation mode | Two people, 10-turn zh↔ja chat; tap your side's mic to talk |
| 8 | Thermal soak | 30-min session in a warm spot; app should drop to drafts, not die |

## Honest status

The app builds clean (Xcode 26.6, Swift 6 strict concurrency), the unit suite passes, and the core pipeline — streaming ASR, draft translation, LLM refinement, model downloads from both sources — is verified working on a real iPhone, fully offline. Remaining open items live in [todo.md](todo.md); the headline ones: diarization clustering thresholds need real multi-speaker calibration, the app's own UI is not yet localized, and the M8 thermal/battery soak hasn't been run.

## Not in v1 (by design)

Text-to-speech output · automatic spoken-language detection (turn-taking is manual) · background listening · languages beyond zh/en/ja. The seams for all four exist — see `AppLanguage` and the direction-resolution step in `CaptionPipeline.handle`.
