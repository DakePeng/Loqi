# Locally — TODO

Roadmap + completeness review. Review date: 2026-06-10; sprint completed same
day (build green, 64 tests in 8 suites).

## Roadmap (differentiation features)

- [x] **1. Saved sessions + export** — sessions auto-save on stop (JSON,
  on-device); Sessions tab with list/detail; Markdown export via ShareLink.
- [x] **2. On-device session summaries** — ✨ menu in session detail; summary
  written in the session's target language, cached, included in exports.
- [x] **3. TTS output** — speaker toggle in Conversation; system synthesizer;
  mic gated while the phone speaks (no self-transcription).
- [x] **4. Named speakers** — tap a speaker chip (live or saved) to rename;
  names persist into records and exports. Cross-session voiceprint
  auto-attribution stays under "Later" (biometric consent UX needed).
- [x] **5. Smart hotword suggestions** — LLM mines saved transcripts; one-tap
  Add; known terms filtered.
- [x] Korean as 4th language (runtime-validated like the others).
- [ ] Later: Live Activity / Dynamic Island captions (needs widget extension
  target) · iPad layout · KV-cache prompt reuse · cross-session voiceprints.

## Completeness review

### Robustness — all fixed
- [x] Audio interruptions (pause + auto-resume; route changes rebind mic)
- [x] Backgrounding (clean stop + message; model unload after 2 min)
- [x] CaptionStore pruning (600 → 500)
- [x] Draft-failure UI state (no more eternal spinner)
- [x] Memory warnings unload LLM + voiceprint models

### Incomplete features — resolved
- [x] Onboarding v1 (honest unsupported state, mic-denial guidance, skip/retry)
- [x] Conversation silence turn-release (2.5s VAD)
- [x] Diarization retroactive relabeling + live speaker-count changes
- [x] tok/s in Diagnostics
- [x] ~~Refinement "off-screen" skip rule~~ **deleted from design** — couples
  the queue to UI scroll state for negligible benefit; silence-gating already
  solved the contention it targeted.

### Mode separation / UX debt — resolved
- [x] Per-mode transcript isolation (SessionMode tag)
- [x] UI localization: zh-Hans + ja String Catalog (70 strings, all major UI)
- [x] Session affordances: elapsed timer + low-battery hint

### Ship checklist
- [x] App icon · privacy manifest · orientation · MLX deprecations · README
- [ ] **30-minute thermal soak + battery test — needs the physical iPhone.**
  Procedure: warm room, continuous 2-speaker captions with LLM on, 30 min.
  Expect: "Enhanced translation paused (device warm)" pill at `.serious`
  thermal state, captions never stop, no crash; battery drain noted.

### Test coverage — resolved
- [x] CaptionStore state machine
- [x] TranslationCoordinator pivot expansion (injectable checker)
- [x] ModelScopeDownloader manifest/pattern/tail logic
- [x] SessionRecord markdown/codable + suggestion parsing
