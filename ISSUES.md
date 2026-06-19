# Issues

## High Priority

- [ ] Imported audio is not archived, so imported sessions cannot use playback, tap-to-replay, or re-transcription.
  - Evidence: `Loqi/Pipeline/Import/FileImportEngine.swift` returns a `SessionRecord` without `audioFileName`; playback/retranscribe paths require one.
  - Fix: copy or keep imported audio in the archive recordings directory and set `SessionRecord.audioFileName`.

## Medium Priority

- [ ] Large imports can block the UI.
  - Evidence: `FileImportEngine` and `OfflineTranscriber` are `@MainActor`; file copy/open and full-file audio decode happen synchronously.
  - Fix: move copy/open/decode work off the main actor.

- [ ] Photo attachment processing can hitch live capture.
  - Evidence: `CaptionPipeline.attachImage` calls synchronous image downscale/JPEG encode/write before returning.
  - Fix: compress and write the image off-main, then append/update the attachment on the main actor.

- [ ] Live attachment OCR/VLM updates are not journaled.
  - Evidence: `CaptionPipeline.updateAttachment` mutates `liveAttachments` but does not call `writeJournal()`.
  - Fix: call `writeJournal()` after live attachment mutation.

## Low Priority

- [ ] Session search cache can go stale after transcript text changes with the same entry count.
  - Evidence: `SessionSearch.fingerprint` tracks `entries.count` but not source/translation text content.
  - Fix: add a cheap aggregate of entry source/translation text counts to the fingerprint.

- [ ] Speaker separation first-run defaults differ between live recording and import.
  - Evidence: live recording defaults `captions.speakerCount` to `0`, while import defaults the same key to `-1`.
  - Fix: align the defaults or make the import-specific behavior explicit.

- [ ] Hotword JSON writes are not atomic.
  - Evidence: `HotwordStore.persist` and `persistPending` call `data.write(to:)` without `.atomic`.
  - Fix: use `data.write(to: url, options: .atomic)`.

## Build Cleanup

- [ ] Resolve Swift concurrency warnings around `AVAudioPCMBuffer` conversion closures.
  - Evidence: warnings in `AudioCaptureService.swift` and `VoiceprintService.swift` for captured mutable state and non-Sendable buffers.

- [ ] Replace deprecated `AVAssetExportSession.export()` usage.
  - Evidence: iOS 18 deprecation warnings in `FileImportEngine.extractAudioIfNeeded`.

- [ ] Decide Info.plist document/full-screen warnings.
  - Evidence: build warns that document opening does not declare in-place support and `UIRequiresFullScreen` is deprecated on iOS 26.
