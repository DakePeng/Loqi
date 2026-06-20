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
- [x] **7. Summary styles + post-recording card** — 5 styles (meeting /
  memo / lecture / brainstorm / journal) picked at summarize time, spec-driven
  reduce prompts (map phase untouched, so style switching is reduce-only);
  post-stop card on Record tab: Summarize (style dialog) or Discard audio
  (file-only delete, transcript/summary kept; also in detail header).
## Next (2026-06-11 brainstorm — competitive review)

Context: the on-device category is no longer empty (Basil AI: on-device
diarization + summaries; Inscribe: offline summaries / action items / Q&A)
and Apple keeps absorbing the baseline (Voice Memos live transcription,
call recording + summaries in Notes). Still uniquely ours: CJK-first +
China-operable stack (SenseVoice, pinyin hotwords, ModelScope/HF-Mirror,
no account), live summary mapping, the integrated live pipeline. Gaps vs.
table stakes: search, Q&A, action-item export, sync, capture friction.

Top three (convert demo → daily tool):

- [x] **8. Chat with a session** — chat sheet on session detail (bubble
  icon): ChatEngine grounds answers in chunk notes (outline + token-matched
  bullets) + keyword-matched transcript lines, transcript fallback for
  unmapped sessions; answer language follows the question
  (NLLanguageRecognizer, named explicitly in the prompt); history persists
  on the record (capped 40); send disabled while recording (LLM
  contention).
- [x] **9. Capture friction** — staged: (a) background continuation —
  `audio` background mode; lock-screen/backgrounded sessions keep ASR +
  AAC + diarization, ALL LLM work pauses (Metal-in-background kills) and
  catches up on return; chunk jobs are HELD (new `ChunkNoteQueue.setPaused`),
  backgrounded chunks enqueue blind so `liveMappingStopped` never trips on
  lock. (b) Live Activity / Dynamic Island — timer is anchored text (zero
  updates), stop button via LiveActivityIntent, stale-activity sweep at
  launch. (c) App Intents — Start (AudioRecordingIntent: background mic
  start), Stop (LiveActivityIntent: no foregrounding), Toggle; Siri
  phrases via AppShortcutsProvider; `CaptionPipeline.shared` singleton so
  intents drive the UI's pipeline. (d) Control Center / Lock Screen /
  Action Button toggle (one ControlWidget) reading app-group state. New
  `LoqiWidgets` extension target (no ML deps, `LOQI_WIDGET` fences intent
  bodies).
- [x] **10. Search across sessions** — `.searchable` on Sessions; matches
  transcript (source + translation), summary, chunk notes, speaker names;
  CJK-safe substring matching with lowercased-blob cache
  (`SessionSearch`); rows show snippet + match count; tap jumps to the
  first matching transcript block (existing scroll+flash machinery).
  Semantic embeddings still later.

Table-stakes + flagship batch (2026-06-12):

- [x] **11. Image attachments** — camera/library button on the Record bar
  (custom AVCaptureSession sheet, `automaticallyConfiguresApplicationAudioSession
  = false` so a photo can't interrupt the mic) + post-hoc "Add photo" in
  detail. Vision OCR (zh/ja/ko/en, on-device, no download) → text flows
  into summary/chat/search as DERIVED pseudo-notes (`AttachmentNotes`,
  merged at consumption time, never cached — protects the
  `liveNotesEndEntryID` resume invariant). Thumbnails interleave the live
  transcript and detail blocks; full-screen viewer with extracted text,
  caption, delete. Files in Attachments/ with orphan sweep. Phase B: 4th
  model tier `Qwen3-VL-2B-Instruct-4bit` (verified on HF + ModelScope,
  ~1.8GB) via MLXVLM — `LLMService.describeImage`, descriptions generated
  by `AttachmentDescribeQueue` (ChunkNoteQueue yielding contract);
  `AttachmentNotes` prefers the description when OCR is thin.
- [x] **12. Tap transcript line → seek playback** — entries now carry
  `audioOffset` stamped via `AudioTimeline` (one anchor per turn start, so
  interruption gaps don't skew); detail view owns the playback controller,
  tap seeks, playhead highlights the current entry. Imports get exact
  offsets free.
- [x] **13. Auto-titled sessions** — `titleText` generated (~16 tokens)
  right after summarize while the model is hot; fallback chain title →
  first note headline → transcript prefix; rename in detail (titleEdited
  wins); searchable.
- [x] **14. SRT/WebVTT export** — Export menu in detail (Markdown / SRT /
  bilingual SRT / VTT), cue ends at next start capped at 4s, wall-clock
  fallback for legacy records.

## UX orchestration pass (2026-06-12 review → fixed same day)

A screen-level review found the UX hadn't caught up with the capture-first
pivot. All twelve findings fixed (build green, 279 tests in 36 suites):

- [x] **Model-download consent** — `LLMService.load(policy:)`:
  `.requireDownloaded` everywhere by default; only Settings and explicit
  consent prompts (detail summarize dialog, chat Download button) pass
  `.downloadIfNeeded`. Pipeline warm loads never download; a status pill
  points to Settings. `isDownloaded` = completion marker + ModelScope
  manifest + HF snapshot heuristic.
- [x] **Record tab can't be bricked** — scenario page self-heals (clears
  `lastFinishedSessionID`) when its session was deleted from Sessions.
- [x] **Store cleared at session start** — no previous/discarded transcript
  leading the next recording or bleeding into refinement history.
- [x] **Mid-recording "Clear" removed** — it silently destroyed the
  archive-bound transcript while audio kept rolling.
- [x] **Short recordings survive** — `SessionArchive.shouldArchive`: any
  finalized entry saves; audio-only sessions ≥5s save (no scenario card,
  notice instead); true junk gets a transient "wasn't saved" notice.
- [x] **Playback lifecycle** — stop moved off the PlaybackBar row (lazy
  List rows "disappear" on scroll, killing audio mid-listen) onto the
  detail view.
- [x] **Post-stop page** — content preview (note headlines / first+last
  lines), neutral "View session" path, Discard demoted to a quiet
  destructive link (it deletes the WHOLE session — supersedes the old
  "Discard audio" card copy), landscape stop shows a "Saved" pill.
- [x] **LLM toggle now means one thing** — off = no model loads anywhere
  (summarize/chat/retranscribe/suggestions explain instead of bypassing);
  Settings section renamed "On-device AI" with honest scope copy; status
  pills/thermal labels de-translation-era'd.
- [x] **Paused state visible** — recording bar and landscape swap the
  pulsing dot/ticking timer for an orange Paused indicator; landscape
  renders PipelineStatusBar + lastError.
- [x] **SummaryJobCenter** — summarize/re-transcribe live on the pipeline,
  not in view @State: progress survives navigation, double-runs impossible,
  auto-suggested vocabulary lands in the badged inbox.
- [x] **Import** — cancellable (cooperative checks down to the SenseVoice
  decode loop), SenseVoice-fallback notice, lands on the imported session.
- [x] Polish: mic alert gets Open Settings; session rows show duration +
  audio/summary icons (not entry counts); Settings diagnostics auto-refresh
  + SenseVoice Stop button + diarizer download row hides once installed;
  seek-while-recording explains itself; localization for all new strings
  (zh-Hans + ja).

## Root cause: TokenRing crash on the VL tier (2026-06-12, corrected)

The "app dies mid-recording" crash
(`Fatal error: [broadcast_shapes] Shapes (64) and (566)`) was FIRST blamed
on Qwen3.5's gated-delta-net layers (64 matched `linearNumValueHeads`) and
the Qwen3.5 tiers were retired. **That diagnosis was wrong** — disproved by
the field evidence ("worked before; Locally AI runs it fine"): text-model
prompts are 1-D and never crash. The real bug, confirmed against upstream
issues #220/#170: the repetition-penalty **TokenRing reads `dim(0)` as the
prompt length**, so the **Qwen3-VL tier's 2-D `[1, N]` prompts** corrupt
its 64-slot ring (64 = OUR `repetitionContextSize`) into `[N+63]`, and the
first sampled token aborts — uncatchable from Swift. With the VL tier
selected, EVERY generation crashed (564 = 503-token prompt + 63). Upstream
merged the fix ("flatten prompt in TokenRing.loadPrompt", PR #170) after
the pinned 3.31.3 release.

- [x] **Real fix, applied locally** — `FlattenedPromptProcessor` in
  LLMService wraps the parameters' logit processor and flattens the prompt
  before the ring sees it (exactly upstream's merged fix); generation goes
  through an explicitly built `TokenIterator` + `generateTask`. Delete the
  wrapper when the dependency moves past 3.31.3 (re-check upstream
  #191/#220 closed).
- [x] **Qwen3.5 is natively multimodal → catalog is all-3.5 now** —
  verified (2026-06-12): both `mlx-community/Qwen3.5-2B-4bit` and
  `…-0.8B-4bit` carry `model_type "qwen3_5"` + vision_config + processor
  configs, byte-identical on HF and ModelScope. They load through the
  MLXVLM factory (tried before MLXLLM), whose Qwen3VLProcessor emits 2-D
  prompts even for text — which is what met our repetition penalty. (Best
  theory for "worked for weeks, then crashed": the repos gained their
  vision files in an upstream update, flipping which factory wins; Locally
  AI runs the same model fine because it doesn't use a repetition
  penalty.) Catalog now: Qwen3.5-2B (default, ~1.75GB, vision) ·
  Qwen3.5-0.8B (fastest, ~650MB, vision); Qwen3-1.7B and Qwen3-VL-2B
  removed; `normalizeStoredSelection` snaps stale ids to the default.
  Stale text-era snapshots are detected (downloaded marker → v2; vision
  files required by `isDownloaded`; ModelScope manifest invalidated) so
  the consent flow tops them up to the vision-bearing revision instead of
  silently loading a text-only container.
- [ ] **Device-verify the multimodal default** — record with photos on
  Qwen3.5-2B: descriptions generate, text refinements unchanged, and the
  TokenRing fix holds (no broadcast abort). Memory: weights grew 1.3 →
  1.72GB; check the 2.2GB headroom admits on a 6GB device alongside
  SenseVoice (expect the tight-cache path more often; 0.8B is the
  escape hatch). Existing installs: first AI use re-prompts for the
  ~1.75GB download (marker v2 + stale-snapshot top-up) — confirm the
  consent dialog appears and the old snapshot upgrades.

## Crash resilience (2026-06-12 — field report: app died mid-recording)

Report: after recording+transcribing a while the app exits to home (Live
Activity keeps showing "recording" — it outlives the process); reopening
didn't resume and the session was gone. Two failure layers fixed:

- [x] **Session survives the crash** — `SessionJournal` snapshots the live
  session (archive-shape record, atomic JSON) on every finalized
  utterance/note/photo and on interruption pauses; clean stop deletes it.
  Recordings now write **CAF** (AAC-in-CAF, same bitrate): unlike m4a, a
  CAF killed mid-write stays playable to the last chunk. At launch a
  leftover journal is recovered BEFORE the orphan sweep (which previously
  deleted the crashed audio!): the session lands in the archive with its
  audio, the Record tab opens on the post-stop page in "Recording was
  interrupted" framing (orange bolt; entry-less recoveries get a notice
  instead), and the app-group state resets so the Control Center toggle
  stops claiming "recording". Duplicate-guard for crashes that race the
  clean shutdown.
- [x] **Likely killers mitigated** — (1) backgrounding WHILE recording now
  unloads the LLM (it was 1.3GB of dead weight — all LLM work is paused
  back there — and the top jetsam target on locked-screen sessions);
  foreground return reloads + queues catch up. (2) A
  `DispatchSourceMemoryPressure(.critical)` shed runs in background too
  (UIKit's memory warning is foreground-only). (3) The debug `assert` on
  leaked `<think>` tags in LLM output is now a strip+log — one leaked
  token after an hour of refinements crashed debug builds.
- [ ] True mid-session **resume** (append a second audio segment to the
  recovered session) — not built; recovery + one tap to a fresh recording
  is the current answer. Needs multi-segment audio per record.

## Qwen3-ASR post-processing pass (2026-06-12)

- [x] **Larger ASR for post-processing** — Qwen3-ASR-0.6B (Speech-LLM,
  52 languages, Apache 2.0) via the already-vendored sherpa-onnx v1.13.2
  bindings (`sherpaOnnxOfflineQwen3ASRModelConfig` — zero new runtimes).
  `Qwen3ASRModelStore` downloads ~990 MB per-file (HF mirror of the
  official int8 package / ModelScope `zengshuishui/Qwen3-ASR-onnx`,
  byte-identical, both verified live); own silero copy so it doesn't
  depend on SenseVoice. Shared `VADSegmentedTranscriber` extracted from
  the SenseVoice file path; `OfflineTranscriber.Backend` (apple /
  senseVoice / qwen3ASR) with `effectiveBackend` — **Qwen3 wins whenever
  installed** (installing = opt-in) for BOTH "Re-transcribe & summarize"
  and imports; live captions untouched. Hotwords prime the decoder
  (comma-separated bias strings — SenseVoice has no biasing). Memory: the
  retranscriber already unloads the LLM; imports now unload it too when
  the Qwen3 backend runs (~940 MB decoder + resident LLM won't coexist
  on 6 GB). Settings section "High-accuracy re-transcription" with the
  standard download/stop/progress rows.
- [ ] **Device verification** — download via ModelScope (China path) and
  HF; re-transcribe a real zh session: decode completes, RTF acceptable
  (AR decode is slower; progress bar covers it), memory peak OK with the
  LLM unloaded ("qwen3asr"/"retranscribe" log categories); import a long
  file and cancel mid-decode (must abort within ~a second); A/B accuracy
  vs SenseVoice re-transcribe on names/numbers and a taught hotword;
  confirm the 10s VAD cap keeps segments inside the 512-token budget
  (watch for truncated long sentences and "empty decode … retrying
  halves" log warnings).
- [x] **Hotword priming is ON** (`Qwen3ASRFileTranscriber
  .hotwordPrimingEnabled = true`) — Qwen3-ASR expects comma-separated
  hotwords (`c-api.h:1018`), now locked by `Qwen3ASRHotwordFormatTests`.

## Field fixes (2026-06-13, first device run of the 1.72GB-model era)

- [x] **Memory shed thrash** — the critical memory-pressure dispatch
  source reports SYSTEM-wide pressure, chronic on 6GB devices now that
  the default model is 1.72GB; every event unloaded the LLM ("AI 功能已暂停
  (内存不足)" pill within seconds of recording) and the silence-gap reload
  re-triggered it. Now sheds only when `os_proc_available_memory()` <
  400MB at the event.
- [x] **"Summarize failed: AI 模型未加载"** — a shed mid-summarize nilled
  the container between chunk generations. `LLMService.generate` /
  `describeImage` now self-heal: container nil → reload with
  `.requireDownloaded` (never a surprise download) and continue.
- [x] **Re-transcribe losing content** — two defenses: hotword priming
  disabled until format-verified (above), and `VADSegmentedTranscriber`
  retries a suspicious empty decode (segment ≥ 2s) on the segment's two
  halves instead of silently dropping the text.
- [x] **Live transcript stopped following + stuck "回到实时" pill** — the
  live-edge flag flipped off whenever a big block append put the new
  bottom beyond the 120pt slack (zh + large-type translation blocks are
  300–600pt), so follow disengaged on its own content. Disengage is now
  user-only (`onScrollPhaseChange`: drag/decelerate), reaching bottom
  always re-engages.
- [ ] Device re-check: record zh→en for several minutes — captions follow
  continuously, pill only after a deliberate scroll-up, AI pill appears
  only under real pressure; Summarize completes on the 2B model (if the
  6GB device still struggles, the 0.8B tier is the fallback default).

## Transcript polish removed (2026-06-13)

- [x] **LLM transcript rewriting removed as unhelpful** — the tier-2
  "polish" (cleanSource in refinement jobs, the transcribe-only polish
  path, the `transcript.polish` toggle, ✎ marks + copy-original menu, and
  `CaptionStore.applyCleanedSource`) is gone: the transcript is the record
  of what was said. What REMAINS for hotwords: the deterministic
  Levenshtein/pinyin `fixup` (live, tier-0), glossary-steered translation
  refinement, and a new strictly-scoped **hotword restore** in
  `hygienePass` (vocabulary-targeted prompt may only swap misrecognized
  terms, fidelity-gated by `isAcceptableHotwordRestore`, capped at 20) —
  so LLM hotword replacement still works without free-form rewriting.
  Legacy records keep decoding (`rawSourceText` field retained; restore
  writes it for idempotency).

Cheap wins (pieces already exist):

- [ ] **Turn real-device checks into a proof pack** — one repeatable
  zh/en/ja demo set with accuracy, latency, battery, memory, crash
  recovery, and long-session results; builds trust better than another
  speculative feature.
- [ ] **CJK accuracy benchmark vs. competitors** — measure WER on a fixed
  zh/ja/ko test set against Apple SpeechAnalyzer and Notta/Otter (cloud).
  Validates the moat claim and becomes marketing material. SenseVoice vs.
  Apple comparison is the most actionable first cut.
- [ ] **Burn down the current issue backlog** — imported-audio archival,
  large-import UI blocking, photo-processing hitches, live attachment
  journaling, and stale search cache live in `ISSUES.md`.
- [ ] **Speaker analytics** — talk-time per speaker, per-speaker action
  items; falls out of stored diarization data.
- [ ] **Ask/search across all sessions** — reuse saved summaries, chunk
  notes, attachments, and existing CJK-safe search before adding semantic
  embeddings.
- [ ] **Highlight marker during recording** — one tap to mark an important
  moment, then surface those anchors in summary/chat/export.
- [ ] **Custom summary styles** — `SummaryStyle.Spec` is already
  data-driven; user-defined styles + auto-suggest style from content.
- [ ] **Bilingual transcript export** — side-by-side source/translation
  from the lens data (cross-border teams, language learners). *Bilingual
  SRT shipped with #14; side-by-side markdown remains.*
- [ ] **PDF + share-card export** — MD/SRT/VTT ship (#14); a clean PDF and
  a shareable summary card cover the work/social sharing gap.
- [ ] **Inline transcript edits** that feed hotwords ("teach the app"
  loop). *Partially done 2026-06-11:* Vocabulary tab (hotwords moved out
  of Settings) with alias support; speaker renames silently add hotwords;
  summary edits diff → LLM-mine → confirmable suggestions (tab badge).
  Transcript-edit capture remains (seek done — #12).
- [ ] **Action items → Reminders/Calendar** (EventKit export).

Trust + durability:

- [ ] **Encrypted backup / E2E iCloud sync** — a single-device archive
  contradicts the data-ownership pitch.
- [ ] **App lock (Face ID / passcode)** — biometric gate on app open +
  sensitive sessions; obvious fit for the privacy brand, none today.
- [ ] **"Provably offline" UX** — post-download network kill-switch +
  zero-bytes-sent privacy screen; make the architecture visible.

Moat extensions:

- [ ] **zh↔en code-switching as flagship** — SenseVoice handles 中英夹杂
  natively where rivals collapse; add tests + a demo clip, market it
  deliberately.
- [ ] **Accessibility mode** — full-screen high-contrast live captions
  for deaf/HoH in-person use; HorizontalCaptionView is most of it.
- [ ] **Weekly journal digest** — one reduce pass over the week's saved
  journal summaries.
- ~~**Mac app / desktop surface**~~ — **not a v1 surface.** The iPhone app
  is the product focus; decide later whether to delete or revive the
  existing `LoqiMac` target.
- [x] **Developer preview distribution** — current release path is GitHub
  source tags/changelogs only. README now says there is no installable
  GitHub `.ipa`, no TestFlight/App Store build yet, and technical users
  run from source with their own signing team.
- [ ] **Deferred App Store ship path** — iPhone 15+/iOS 26/dev signing
  remain adoption blockers. When public-user install matters enough to
  pay for it, use a paid developer account ($99/yr), TestFlight beta,
  then public App Store submission.
- [ ] Later: iPad layout · KV-cache prompt reuse · cross-session
  voiceprints (biometric consent UX needed) · Apple Watch quick-capture
  (start/stop/flag) · Contacts → hotword import (seed names).

## Device verification queue (needs the physical iPhone)

- [ ] **Crash recovery (2026-06-12)** — reproduce the field report: long
  recording+transcription until the app dies (or simulate: `kill -9` the
  app from Xcode mid-recording). Reopen: post-stop page shows "Recording
  was interrupted", the session has the transcript up to the last
  utterance, and the CAF audio plays to within seconds of the kill; the
  Control Center toggle shows idle; no orphan sweep ate the file. Then the
  memory side: 30+ min locked-screen recording with the LLM previously
  loaded — memory gauge should drop ~1.3GB on lock (model unloads), notes
  catch up on unlock. Grab the actual .ips from the original crash
  (Settings → Privacy & Security → Analytics Data, or Xcode → Devices →
  device logs): JetsamEvent-*.ips = memory (check largest process
  footprint), Loqi-*.ips with SIGABRT in LLMService = the old assert.
- [ ] **UX pass flows (2026-06-12)** — fresh install, no LLM: record →
  stop → scenario page shows preview + no "Detecting…"; pick a style →
  download-consent dialog → progress in the Summary section and wand;
  decline → error explains. Chat sheet shows the Download banner. AI
  toggle off → Summarize/chat/suggest explain instead of loading; model
  stays unloaded (Diagnostics). One-utterance memo saves; <5s silent tap
  shows "wasn't saved" notice and archives nothing. Playback keeps
  playing while scrolling a long transcript and survives the follow-along
  highlight. Import a long file → Cancel mid-transcribe aborts within ~a
  second (SenseVoice) and the sheet stays usable; successful import lands
  on the session. Interrupt with a call: recording bar + landscape show
  Paused (no ticking timer), portrait pill still explains.

- [ ] **Far-field meeting capture (2026-06-12)** — phone flat on a real
  meeting table: talkers 3–5m away must come through whole, not in
  fragments. Changed: capture session is now `.record` with NO Bluetooth
  input (AirPods can no longer silently steal the mic — verify with
  AirPods connected that captions still come from the phone's mic), omni
  polar pattern + max input gain on the built-in mic, adaptive
  `FarFieldGain` boost in the tap (watch the level meter respond to far
  speech), silero VAD threshold 0.5→0.4 on both SenseVoice paths. Watch
  for regressions: room noise boosted into phantom captions during long
  silences, near speech briefly loud right after a far talker, louder
  noise floor in the saved m4a. Also exercise the new **mic pickup
  presets** (chip on idle home, icon menu on the recording bar):
  Close-up (strict VAD, boost off — background voices must stay out),
  Balanced, Meeting room (silero 0.3 + 0.7s hangover, boost ×12, Apple
  detector high) — switching MID-SESSION must restart the turn cleanly
  (in-flight sentence finalizes, captions resume within ~a second), and
  Meeting room must not hallucinate captions from HVAC/keyboard noise.
  And **Auto speakers** (Record chip + import sheet): a 3-person meeting
  should settle on 3 slots without overcounting on short interjections;
  re-check a 2-person session doesn't split one voice in two.
- [ ] **Summary accuracy A/B (2026-06-12)** — one fixed zh meeting
  recording with known names/numbers, three summaries: (1) baseline from
  a pre-change build, (2) post prompt/grounding work (vocabulary-primed
  chunk notes, grounded reduce, hygiene pass), (3) after "Re-transcribe
  & summarize". Score each on wrong facts, hallucinated items, and named
  entities preserved. Also watch the LLM unload → SenseVoice → LLM reload
  handoff during re-transcribe ("retranscribe"/"sensevoice" log
  categories) for memory pressure on a 6GB device, and confirm speaker
  names survive re-transcription (overlap inheritance).
- [ ] **Seek accuracy after interruption (2026-06-12)** — record, force an
  interruption (incoming call/Siri) mid-session, resume, then tap late
  transcript entries in detail: playback must land on the words (offsets
  use AudioTimeline anchors, not wall clock).
- [ ] **Camera during live recording (2026-06-12)** — snap a photo from
  the Record bar mid-session: captions/AAC must not hiccup (the custom
  capture sheet must leave the audio session alone). If the session
  pauses, the AVCaptureSession route needs `usesApplicationAudioSession`
  tuning before shipping.
- [ ] **OCR quality on CJK slides/whiteboards (2026-06-12)** — photograph
  a 中文 slide + an English whiteboard; check extracted text in the
  viewer, the summary after re-summarize, and search hits on slide words.
- [ ] **VLM tier (2026-06-12)** — Settings → Qwen3-VL 2B: download
  (~1.8GB, both sources), load on a 6GB device (expect the tight-cache
  path; `.insufficientMemory` is the known risk mid-session), photo
  description latency, and captions never stuttering while a description
  generates (speech-active cancellation). A/B zh→en refinement quality vs
  Qwen3.5-2B before recommending it as a daily driver — its text tower is
  a generation older.
- [ ] **SRT timing (2026-06-12)** — export SRT for a real session, open
  beside the shared m4a in IINA/QuickTime; cues should track speech.
- [ ] **Auto-titles (2026-06-12)** — summarize zh and en sessions: list
  rows show specific titles (not transcript prefixes); rename survives
  re-summarize.

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
  2-speaker session with LLM on. Expect: thermal pill only once `.serious`
  has persisted 60s (transient spikes no longer pause refinement), live
  mapping stops gracefully, captions never stop, no crash.
- [ ] **SenseVoice + 2B memory headroom** — with SenseVoice active, confirm
  the 2B model loads via the tight-cache path instead of failing with "not
  enough free memory" (load admission now re-polls ~4s and accepts a 64MB
  MLX cache when free memory sits in the 1.6–1.8GB band). Watch tok/s in
  the debug readout for the tight-cache cost.
- [ ] **Summary styles** — one real session through all 5 styles (wand-menu
  picker): style switch is reduce-only (near-instant), headings match style +
  device language, meeting output reads unchanged vs. pre-style builds;
  lecture on jargon-heavy audio fills Terms (terms now reach reduce). Watch
  journal Feelings / brainstorm Standouts for thin or junk sections — tune
  caps/hints in `SummaryStyle.spec`.
- [ ] **Post-recording card** — stop a real recording: card shows duration +
  audio size; Summarize → style dialog → near-instant via live notes, result
  sheet renders; Discard audio frees the file (detail loses its Recording
  section, orphan sweep clean on relaunch); no card for trivial sessions.
  (Backgrounding no longer stops the session — superseded by background
  continuation below.)
- [ ] **Vocabulary capture loop** — live session: rename a speaker mid-
  recording and confirm the rest of the session recognizes the name better
  (contextual strings re-push). Edit a saved summary inserting a name →
  suggestion appears in the Vocabulary tab via the on-device LLM (simulator
  always takes the raw-diff fallback; only the device exercises the mining
  prompt). Alias check: add a nickname alias, mishear it on purpose, and
  confirm the transcript shows the alias spelling, not the canonical term.
- [ ] **Background continuation soak (2026-06-11 build)** — start, lock
  10+ min with intermittent speech: transcript continuous on unlock, ZERO
  LLM activity while locked (console), chunk notes catch up in silence
  gaps, `liveMappingStopped` never tripped, AAC plays back. Then: phone
  call while locked → Live Activity shows Paused → resumes after; heavy
  game while background-recording (memory-warning banner on return, no
  kill); 30-min locked thermal soak. If jetsam shows up, the knob is
  unloading the LLM in `handleBackground()` while running.
- [ ] **Live Activity + Dynamic Island** — lock screen + DI render; Stop
  works from the lock screen and from another app (no foregrounding);
  "Saved" state shows ~5s then dismisses; force-quit mid-recording →
  relaunch sweeps the zombie activity; SpeechAnalyzer asset eviction on
  hours-long locked sessions (watch for silent caption stalls).
- [ ] **Intent capture surfaces** — cold (app not running) start from the
  Control Center toggle, Action Button, and "Start recording with Loqi"
  via Siri: AudioRecordingIntent must start the mic WITHOUT foregrounding
  (fallback if unreliable: `openAppWhenRun = true` on
  StartRecordingIntent). Mic-permission-missing → "Open Loqi once to
  finish setup." Toggle state stays in sync (app group). Personal (free)
  signing teams may fail app-group provisioning — the control then shows
  stale state; everything else works. Check Shortcuts app for doubled
  intent entries (types exist in both bundles).
- [ ] **Chat on a real session** — 30–60 min session: first-token latency
  acceptable (~5–10s prefill), answers follow the question's language
  (zh/en/ja), no-answer-in-notes says so, degenerate output → "Couldn't
  answer" error; history survives reopening the sheet; Clear chat works.

## Completeness review — resolved earlier

- [x] Audio interruptions / route changes / backgrounding / memory warnings
- [x] Onboarding v1 · diarization retroactive relabeling · tok/s diagnostics
- [x] Per-mode transcript isolation · localization (zh-Hans + ja) · timers
- [x] App icon · privacy manifest · orientation · README
- [x] Test coverage: store, translation pivot, downloader, records, prompts,
  voiceprint math, summary chunking, live chunker streaming equivalence,
  archive artifacts, orphan sweep
