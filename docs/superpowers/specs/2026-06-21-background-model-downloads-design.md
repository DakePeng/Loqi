# Background Model Downloads Design

## Goal

Model downloads should keep transferring when Loqi backgrounds or the screen locks. This scope is downloads only: recording, live transcription, re-transcription, summaries, photo descriptions, and other ML work keep their current background behavior.

Success means a user can start a SenseVoice, Qwen3-ASR, diarizer, or LLM model download, leave Loqi, and later return to progress that continued instead of simply freezing with the process.

## Non-Goals

- Do not run MLX, sherpa-onnx, diarization, summaries, or imports indefinitely in the background.
- Do not add a BGTask scheduler for downloads.
- Do not redesign Settings or onboarding download UI.
- Do not change model consent rules: multi-GB LLM downloads still require explicit user consent.

## Approach

Use iOS background `URLSession` download tasks for model file transfers. Keep the existing model stores as the source of install state, progress, cancellation, and final file placement. Replace only the transfer primitive used by large model downloads.

The current `SegmentedDownloader` is good for foreground speed, but it is process-bound. When iOS suspends the app, those tasks stop. Background `URLSession` is the native path that allows the system to continue transfers and wake the app to finish delegate work.

The lazy rule: use background `URLSession` for model files; keep foreground segmented downloads only if needed for platforms or paths where background transfer is unavailable.

## Components

### BackgroundModelDownloader

A small iOS-only helper that wraps a background `URLSession`.

Responsibilities:

- Start one file download for a source URL and destination URL.
- Write into the same model-store destination after the system provides the temporary downloaded file.
- Publish coarse progress callbacks when the process is alive.
- Reconnect to in-flight tasks after app relaunch or delegate wake.
- Cancel a specific download.

It should not know about model catalogs, model tiers, onboarding, Settings rows, or summaries.

### Existing Model Stores

`SenseVoiceModelStore`, `Qwen3ASRModelStore`, diarizer download code, and `ModelScopeDownloader`/LLM model download call sites remain the public API for UI and features.

They choose the source, destination, expected size, checksum when available, and progress aggregation. Their state stays the thing views observe.

### App Delegate Bridge

SwiftUI `App` needs a tiny UIKit app delegate bridge so iOS can deliver background URLSession completion events. The bridge should call the downloader's stored completion handler, then return control to the system.

## Data Flow

1. User consents to a model download from Settings, onboarding, or an AI feature prompt.
2. The existing store builds the list of model files and destinations.
3. For each file, the store starts `BackgroundModelDownloader`.
4. While foregrounded, progress callbacks update existing rows.
5. If Loqi backgrounds, iOS continues the download when conditions allow.
6. When Loqi returns or iOS wakes it, the downloader moves the temporary file into place, validates checksum if the caller supplied one, and tells the store to continue or mark installed.
7. Existing install-state checks decide whether the model is ready.

## Error Handling

- Cancellation keeps the existing partial-download behavior where practical; otherwise the next attempt restarts that file.
- Failed HTTP status, missing temp files, file move errors, or checksum mismatches surface through existing error rows.
- If iOS delays or pauses background networking, Loqi must not claim active progress; it should simply catch up when callbacks resume.
- If the app is force-quit by the user, iOS may cancel or defer background transfers. The UI should treat this as best effort, not guaranteed completion.

## Testing

Add one small logic test for the policy that selects background download for model files on iOS.

Manual verification requires a real iPhone:

- Start a small SenseVoice or diarizer download, lock the screen for several minutes, return, and confirm progress advanced.
- Start an LLM model download with explicit consent, background Loqi, return, and confirm progress catches up or the model installs.
- Cancel a background-capable download and confirm it stops cleanly.

Do not claim this works from simulator-only tests.

## Implementation Notes

- Keep the first implementation single-file where possible.
- Avoid adding BGProcessingTask unless real-device testing proves background `URLSession` alone is insufficient for the transfer step.
- Preserve current consent and source selection behavior.
- Prefer correctness over segmented speed for background transfers; a slower download that continues is better than a faster one that suspends.
