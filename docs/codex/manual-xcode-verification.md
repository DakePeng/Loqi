# Manual Xcode Verification Checklist

Date: 2026-06-18

Use this when terminal Xcode builds/tests are not allowed.

## Setup

- [ ] Open `Loqi.xcodeproj`.
- [ ] Confirm signing for `Loqi` and `LoqiWidgets`, including app group `group.com.kunzhipeng.loqi`.
- [ ] Select a real iPhone for real-device checks.
- [ ] Leave `LOQI_RUN_NETWORK_UI_TESTS` unset unless intentionally testing the SenseVoice download.

## Simulator-safe

- [ ] Run `LoqiTests` from the `Loqi` scheme.
- [ ] Run `LoqiUITests` from the `LoqiUITests` scheme with `LOQI_RUN_NETWORK_UI_TESTS` unset.
- [ ] Build `LoqiMac` from the `LoqiMac` scheme.

## Real-device

- [ ] Build and run `Loqi`.
- [ ] Complete onboarding and grant microphone permission.
- [ ] Start recording; verify mic level and transcript updates.
- [ ] Stop recording; verify session archive and playback.
- [ ] Attach a camera photo; verify OCR/attachment persistence.
- [ ] Trigger summarize only after the LLM is already downloaded or after explicit consent.
- [ ] Start/stop from Live Activity.
- [ ] Start/stop from Control Center toggle.
- [ ] Lock screen during recording; verify recording continues and AI work resumes on foreground.

## Optional Network

- [ ] Set `LOQI_RUN_NETWORK_UI_TESTS=1`.
- [ ] Run `testSenseVoiceOnlyDownloadCompletes`.
- [ ] Verify `asr.engine` becomes `sensevoice`.
