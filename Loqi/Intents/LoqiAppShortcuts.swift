import AppIntents

/// Zero-setup Siri phrases + Shortcuts presence (app target only — the
/// provider must exist in exactly one bundle). Phrases must interpolate
/// \(.applicationName); non-English phrase variants come later via an
/// AppShortcuts.xcstrings catalog.
struct LoqiAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Start a \(.applicationName) session",
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic")
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording with \(.applicationName)",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle")
    }
}
