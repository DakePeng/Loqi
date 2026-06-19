# Auto Post-Process New Recordings Design

## Overview

Add a Settings toggle that lets Loqi automatically improve new recordings before
their first summary. When enabled, stopping a recording saves the session, then
uses any already-downloaded post-processing models to improve the transcript and
speaker labels before running the normal summarizer.

This feature applies only to newly recorded sessions. It does not change manual
Summarize, Re-summarize, style or length changes, older saved sessions, imports,
or the explicit Re-transcribe & summarize action.

The feature never starts an ASR or diarizer model download. Missing
post-process models are skipped quietly and the session still summarizes with
the best available local data. The existing LLM download/consent gate remains
unchanged for the final summary step.

## Goals

- Improve first summaries for new recordings by giving the summarizer cleaner
  transcript text and better speaker boundaries.
- Prefer the highest-quality downloaded ASR post-process model available:
  Qwen3-ASR first, then SenseVoice.
- Run file-based diarization when the offline diarizer is already downloaded and
  the recording used speaker separation.
- Preserve the current fast/manual paths for older sessions and re-summarization.
- Degrade gracefully: any failed enhancement phase falls back to the saved live
  session data and still attempts summary generation.

## Non-Goals

- Do not auto-process older archived sessions.
- Do not download Qwen3-ASR, SenseVoice, or the diarizer from this toggle.
- Do not make manual Summarize/Re-summarize route through post-processing.
- Do not change import behavior.
- Do not change the existing LLM availability behavior for summarization.
- Do not enable Qwen3-ASR hotword priming; the current code keeps it disabled
  because the prompt format still needs device verification.

## User Experience

Add a persisted setting under the high-accuracy transcription area in Settings
with this copy:

- Toggle: `Auto post-process new recordings`
- Footer: `After recording, Loqi can re-transcribe and identify speakers before
  summarizing. Uses downloaded models only, so missing models are skipped.`

When the toggle is on, the user should see normal background job progress after
stopping a recording. The flow may take longer than instant summarization, but
it should not block navigation because SummaryJobCenter already owns post-hoc
session jobs.

Missing post-process models are not user-facing errors. The job simply uses the
live transcript and any live speaker labels that already exist.

## Architecture

Keep the feature centered in the existing post-hoc job system:

1. `SessionDetailView` remains the post-stop auto-summary trigger.
2. When `autoSummarizeStyle` starts and the setting is enabled, route through a
   new SummaryJobCenter entry point named
   `postProcessAndSummarizeNewSession`.
3. Manual summarize actions continue to call the existing `summarize` or
   `retranscribeAndSummarize` entry points.
4. SummaryJobCenter computes a best-available post-process plan and executes it
   before the normal `runSummarize` path.

The plan should be represented by a small pure policy helper so model-selection
behavior is easy to test without loading device-only frameworks.

Suggested policy output:

```swift
struct NewRecordingPostProcessPlan: Equatable {
    enum ASR: Equatable {
        case qwen3ASR
        case senseVoice
        case none
    }

    var asr: ASR
    var runDiarization: Bool
}
```

Policy inputs:

- `enabled`: persisted setting value.
- `qwen3Downloaded`: `Qwen3ASRModelStore.isInstalled`.
- `senseVoiceDownloaded`: `SenseVoiceModelStore.isInstalled`.
- `offlineDiarizerDownloaded`: `VoiceprintService.isOfflineDiarizerDownloaded`.
- `speakerSeparationEnabledForRecording`: true when the saved recording had a
  speaker-count setting that maps to a diarization cap. If the current archive
  record does not persist this directly, the save path should store a
  lightweight per-session flag for new recordings rather than inferring intent
  from whether live speaker labels happened to be produced.

ASR ranking:

1. Qwen3-ASR when downloaded.
2. SenseVoice when Qwen3-ASR is not downloaded and SenseVoice is downloaded.
3. No ASR post-process when neither is downloaded.

Diarization runs only when the offline diarizer is downloaded and speaker
separation was enabled for the recording.

## Data Flow

The normal new-session save path continues to archive the live transcript, audio
file name, live notes, and speaker names first.

When auto post-processing is enabled:

1. SummaryJobCenter validates that the session is a fresh auto-summary request
   with saved audio.
2. It computes the plan.
3. If the plan has an ASR phase, the saved audio is transcribed with the chosen
   backend and replaces the session entries. Summary and chunk-note caches are
   cleared because their entry IDs and text no longer match.
4. If ASR is skipped, the live transcript remains in place.
5. If the plan has a diarization phase, the saved audio is diarized and speaker
   segments are mapped onto the current entries' audio offsets.
6. If diarization is skipped, existing live speaker labels remain.
7. The normal summarize path runs over the resulting record.

If a fresh session has no saved audio because audio recording is disabled or the
file is missing, ASR and file diarization are skipped and the normal summarize
path runs over the live transcript.

For same-language sessions, no translation work is needed. For translated
sessions, post-ASR entries need the same tier-1 translation regeneration that
the current re-transcription path performs before summarization.

## Speaker Names

Fresh post-stop sessions normally have default speaker labels only. In that
case, file diarization may freely assign dense `Speaker 1`, `Speaker 2`, and so
on.

If speaker names already exist on the record, keep the names dictionary rather
than deleting user data. This case should be rare for brand-new auto-summary
jobs. The UI should not promise that renamed speakers are perfectly remapped
after fresh file diarization.

## Error Handling

Enhancement phases are best-effort:

- If ASR post-processing fails, keep the archived live transcript and continue.
- If diarization fails, keep existing speaker labels and continue.
- If translation regeneration for post-ASR entries partially fails, keep nil
  translations for failed entries and continue.
- If summarization fails, surface the existing summary error, because summary is
  the final user-visible result.

Cancellation should behave like other SummaryJobCenter jobs: user cancellation
stops the job and avoids writing partial final state after cancellation is
observed.

## Progress

Reuse existing activity states where possible:

- ASR phase: existing retranscribing/transcribing progress.
- Diarization phase: extend the retranscribing phase model with
  `identifyingSpeakers(Double)` so the job can stay under the existing
  `.retranscribing` activity family.
- Summary phase: existing summarizing progress.

Progress should describe the current work without exposing skipped phases.

## Testing

Add pure unit tests for the post-process policy:

- Qwen3-ASR wins when both Qwen3-ASR and SenseVoice are downloaded.
- SenseVoice is selected when Qwen3-ASR is missing and SenseVoice is downloaded.
- ASR is skipped when neither ASR model is downloaded.
- Diarization runs only when the offline diarizer is downloaded and speaker
  separation was enabled for the recording.
- Disabled setting always returns no ASR and no diarization.
- No post-process policy path requests an ASR or diarizer download.

Add job-routing coverage where practical:

- New-session auto-summary uses the post-process entry point only when the
  setting is enabled.
- Manual summarize and re-summarize do not auto post-process.
- ASR failure falls back to summarizing the live transcript.
- Diarization failure still summarizes.

Manual device verification:

- Record a short multilingual meeting with Qwen3-ASR downloaded and speaker
  separation enabled. Confirm transcript quality, speaker labels, summary, and
  progress.
- Repeat with only SenseVoice downloaded and confirm it is used as the fallback
  post-ASR backend.
- Repeat with no post-ASR model downloaded and confirm the app summarizes the
  live transcript without errors or download prompts.
- Repeat with the offline diarizer missing and confirm speaker post-processing
  is skipped without prompting for a download.

## Implementation Notes

The current `SessionRetranscriber` only inherits old speaker labels by time
overlap. This feature should either extend that component to optionally run
file diarization or add a small sibling service that composes the existing
offline ASR and file-diarization utilities.

The current re-transcribe backend selector always prefers Qwen3-ASR when
installed, then falls back to the live ASR engine choice. The new auto
post-process policy should be explicit instead: Qwen3-ASR when downloaded,
else SenseVoice when downloaded, else no ASR post-process. That makes the
feature independent of the live engine picker while still using downloaded
models only.

The implementation should not rely on cached live chunk notes after replacing
the transcript. Those notes anchor to old entry IDs and old text, so they must
be cleared before the final summarize.
