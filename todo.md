# Loqi — TODO

Roadmap + completeness review. Review date: 2026-06-11; capture-first
transformation completed same day (build green, 95 tests in 14 suites).

## Product direction (2026-06-11 pivot)

Record → Transcript (speakers) → Summary → Archive is the main line;
translation is an optional lens (set source ≠ target). Conversation mode and
TTS were **deleted** — Apple commoditizes live interpretation at the OS level;
private capture + summarization is the differentiated product.

## Roadmap (differentiation features)

- [x] **1. Saved sessions + export** — auto-save on stop; Sessions tab;
  Markdown export.
- [x] **2. On-device summaries** — map-reduce sized for small models; chunk
  notes power an outline with tap-to-scroll anchors.
- [x] **3. Session audio recording** — AAC ~14 MB/h teed off the capture
  stream; playback bar in detail; deleted with the session; orphan sweep;
  Settings kill-switch.
- [x] **4. Live summary mapping** — chunk notes generate during silences
  (cancel-on-speech, contiguous-prefix coverage); "Summarize" after stop is
  reduce-only (near-instant); "Summary so far" sheet mid-session.
- [x] **5. Named speakers** — tap to rename, live or saved.
- [x] **6. Smart hotword suggestions** — LLM mines saved transcripts.
- [x] Voice Memos / audio file import with the same treatment.
- [x] Korean as 4th language.
- [ ] Later: Live Activity / Dynamic Island · iPad layout · KV-cache prompt
  reuse · cross-session voiceprints (biometric consent UX needed) · search
  across sessions.

## Device verification queue (needs the physical iPhone)

- [ ] **SenseVoice accuracy spike** — Settings → Speech recognition →
  SenseVoice → download (~230 MB, HF-Mirror if needed) → record the same
  speech with both engines and compare. Watch: decode latency per pulse
  (console "sensevoice" category), thermal behavior alongside the LLM, and
  whether 0.5s minSilence segments feel right. If accuracy disappoints on
  real audio, the WhisperKit fallback plan applies.
- [x] **SenseVoice + import** — imports now honor the `asr.engine`
  setting (offline VAD+decode via SenseVoiceFileTranscriber) and accept
  video files (audio extracted via AVAssetExportSession). Device check:
  import the same clip on both engines + an mp4/mov.

- [ ] **AAC recording path** — analyzer-format buffers → AVAudioFile encode is
  simulator-unverifiable. Record 2 min, stop, play back from detail; toggle
  the Settings kill-switch and confirm no Recording section.
- [ ] **Live mapping under load** — long session with LLM on: console shows
  note generations in silences; Summarize is near-instant; "Summary so far"
  appears after ~2 chunks.
- [ ] **30-minute thermal soak + battery test.** Warm room, continuous
  2-speaker session with LLM on. Expect: thermal pill at `.serious`, live
  mapping stops gracefully, captions never stop, no crash.

## Completeness review — resolved earlier

- [x] Audio interruptions / route changes / backgrounding / memory warnings
- [x] Onboarding v1 · diarization retroactive relabeling · tok/s diagnostics
- [x] Per-mode transcript isolation · localization (zh-Hans + ja) · timers
- [x] App icon · privacy manifest · orientation · README
- [x] Test coverage: store, translation pivot, downloader, records, prompts,
  voiceprint math, summary chunking, live chunker streaming equivalence,
  archive artifacts, orphan sweep
