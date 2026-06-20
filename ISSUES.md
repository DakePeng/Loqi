# Issues

## Medium Priority

- [ ] Large imports can block the UI.
  - Evidence: `FileImportEngine` and `OfflineTranscriber` are `@MainActor`; file copy/open and full-file audio decode happen synchronously.
  - Fix: move copy/open/decode work off the main actor.

- [ ] Photo attachment processing can hitch live capture.
  - Evidence: `CaptionPipeline.attachImage` calls synchronous image downscale/JPEG encode/write before returning.
  - Fix: compress and write the image off-main, then append/update the attachment on the main actor.

## Build Cleanup

- [ ] Resolve Swift concurrency warnings around `AVAudioPCMBuffer` conversion closures.
  - Evidence: warnings in `AudioCaptureService.swift` and `VoiceprintService.swift` for captured mutable state and non-Sendable buffers.

- [ ] Decide Info.plist document/full-screen warnings.
  - Evidence: build warns that document opening does not declare in-place support and `UIRequiresFullScreen` is deprecated on iOS 26.
