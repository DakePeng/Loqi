# Issues

## Medium Priority

- [x] Large imports can block the UI. *(Fixed 2026-07-16: `decodeMono16k`
  is nonisolated + URL-based, `OfflineTranscriber.transcribe` takes a URL,
  and FileImportEngine's copies hop off main.)*

- [x] Photo attachment processing can hitch live capture. *(Fixed
  2026-07-16: both `attachImage` variants encode/write off-main and
  re-validate the session on completion; the macOS downscale switched to
  CoreGraphics — `lockFocus` is main-thread-only.)*

## Build Cleanup

- [x] Resolve Swift concurrency warnings around `AVAudioPCMBuffer`
  conversion closures. *(Fixed 2026-07-16: `nonisolated(unsafe)` bindings
  document that the convert input block runs synchronously on the calling
  thread. The VoiceprintService warning disappeared with the sherpa
  diarization rework.)*

- [ ] Decide Info.plist document/full-screen warnings.
  - Evidence: build warns that document opening does not declare in-place support and `UIRequiresFullScreen` is deprecated on iOS 26.
