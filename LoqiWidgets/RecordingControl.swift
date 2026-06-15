import AppIntents
import SwiftUI
import WidgetKit

/// One toggle, three surfaces: Control Center, the Lock Screen controls
/// row, and the Action Button (assigned in Settings → Action Button).
/// State comes from the app group; the app reloads this control on every
/// session start/stop.
struct RecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: RecordingSharedState.controlKind,
            provider: Provider()
        ) { isRunning in
            ControlWidgetToggle(
                "Loqi",
                isOn: isRunning,
                action: ToggleRecordingIntent()
            ) { on in
                Label(
                    on ? "Recording" : "Record",
                    systemImage: on ? "waveform" : "mic")
            }
            .tint(.red)
        }
        .displayName("Loqi Recording")
        .description("Start or stop a transcription session.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            RecordingSharedState.read().isRunning
        }
    }
}
