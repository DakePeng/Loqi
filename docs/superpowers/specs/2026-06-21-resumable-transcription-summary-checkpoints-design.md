# Resumable Transcription And Summary Checkpoints Design

Date: 2026-06-21

## Goal

Make long post-hoc work survive interruption:

- Starting a new recording during uploaded-file transcription pauses that import and resumes it after recording ends.
- Killing or relaunching the app during import or summary resumes from saved progress instead of restarting from zero.
- Qwen3-ASR is removed from the app; SenseVoice remains the only high-accuracy offline ASR path, with Apple Speech as fallback.

## Non-Goals

- No simulator claim of runtime correctness. Background, kill, and ASR behavior must be verified on a physical iPhone.
- No backend-generic checkpoint framework. Segment checkpoints are for SenseVoice's VAD-backed import and re-transcription path.
- No true Apple Speech offset resume. Apple import can restart and de-dupe final results by time range.

## Architecture

Keep `SummaryJobCenter` as the owner of post-hoc work. Do not add a second job database. The existing `SessionRecord` remains the source of truth and gains enough resumable job state to rebuild imports and summaries after relaunch.

Remove Qwen3-ASR from app surfaces and routing:

- Delete the Qwen3-ASR model store and file transcriber.
- Remove the `OfflineTranscriber.Backend.qwen3ASR` case and all Qwen3-ASR selection logic.
- Remove Qwen3-ASR rows from Settings and onboarding.
- Remove Qwen3-ASR from import choices, tests, and localized user-facing strings.
- Keep Qwen3.5 LLM model catalog entries; those are summary/chat/title models, not Qwen3-ASR.

## Components

`SessionRecord` import checkpoint:

- Stores the copied audio filename immediately.
- Stores import options needed to resume: language pair, speaker count, engine, sensitivity.
- Stores completed SenseVoice segment results keyed by stable time range.
- Keeps `importing == true` until the import has a complete transcript.

`SessionRecord` summary checkpoint:

- Stores the active summary request while a summary is running: style, length, and whether vocabulary suggestions should be mined.
- Uses persisted `chunkNotes` and `liveNotesEndEntryID` as map-phase progress.
- Clears the active summary request when reduce finishes, the user cancels, or the session is deleted.

`VADSegmentedTranscriber`:

- Adds a completed-segment callback.
- Lets callers skip segments whose time range is already checkpointed.
- Persists each segment result in chronological order even when SenseVoice decoder pool tasks finish out of order.

`SummaryJobCenter`:

- On launch or foreground, scans archive sessions for unfinished imports or summaries and re-enqueues them when no recording is active.
- `yieldToRecording()` pauses import work instead of cancelling and deleting the placeholder.
- `resumeAfterRecording()` restarts paused imports from checkpoints.
- Summary map progress persists completed chunk notes after each chunk.

`SessionArchive`:

- Stops treating every `importing == true` record as a tombstone.
- Keeps resumable importing records that have a copied audio file and checkpoint options.
- Still sweeps invalid importing records that cannot resume.

## Data Flow

Import starts by copying the picked audio file into `SessionArchive.recordingsDirectory` using the session ID. The placeholder is persisted immediately, so the session row and audio reference survive process death.

For SenseVoice imports, VAD produces stable speech segments. After each segment decode finishes, the job writes the segment result into the record checkpoint and persists the record. If the process dies, only the active segment is lost.

Resume rebuilds VAD segments from the saved audio file, skips completed time ranges, decodes missing ranges, then builds `SessionRecord.Entry` values. Diarization and translation run after transcription. When all transcript entries are ready, the job clears `importing`, keeps the saved audio for playback, marks the session unseen, and starts auto-summary when allowed.

Summary resume uses the persisted summary request plus existing `chunkNotes` coverage. Each finished map chunk is appended to the record and `liveNotesEndEntryID` advances to the last covered entry. If backgrounding or relaunch interrupts summary mapping, the next run maps only uncovered entries. Reduce still reruns as one final generation because partial reduce output is not useful or stable.

## Error Handling

Recording preemption is a pause, not a failure. Summary work pauses on background because Metal-backed generation is unsafe there. Import work may continue during its existing background grace window; if iOS suspends or kills it, relaunch resumes from checkpoints. The UI should keep showing the session as processing.

Explicit import cancellation deletes the unfinished placeholder, copied audio, and checkpoint state. Session deletion also cancels any queued or running work.

Import failure keeps the partial session and error text so the user can retry. Retry resumes from the saved audio and segment checkpoints.

If a resumable import record points to missing audio or invalid options, the archive may sweep it as an abandoned placeholder.

## Testing

Add small logic tests for:

- `OfflineTranscriber` backend selection after Qwen3-ASR removal.
- SenseVoice segment checkpoint de-dupe by time range.
- `SessionArchive.loadIfNeeded()` keeps resumable importing records and sweeps only invalid importing records.
- `SummaryJobCenter.yieldToRecording()` pauses imports instead of deleting them.
- Summary chunk-note persistence resumes from cached coverage.

Manual real-device verification:

- Import a long file with SenseVoice, start a new recording mid-import, stop recording, and confirm the import resumes.
- Kill and relaunch mid-import; confirm completed segments remain and the import resumes.
- Kill and relaunch mid-summary; confirm progress resumes from persisted chunk notes instead of zero.
