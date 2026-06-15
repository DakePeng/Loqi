import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock screen + Dynamic Island UI for a recording session. The elapsed
/// timer is anchored text (zero updates); the status label arrives
/// pre-localized from the app. Stop runs StopRecordingIntent in the app
/// process without foregrounding it.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                statusIcon(context)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.statusLabel)
                        .font(.headline)
                    Text(context.attributes.sessionTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                timer(context)
                    .font(.title3.monospacedDigit())
                    .frame(maxWidth: 64)
                stopButton
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusIcon(context)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.statusLabel)
                            .font(.headline)
                        Text(context.attributes.sessionTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(context)
                        .font(.title3.monospacedDigit())
                        .frame(maxWidth: 64)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    stopButton
                }
            } compactLeading: {
                statusIcon(context)
            } compactTrailing: {
                timer(context)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                statusIcon(context)
            }
        }
    }

    private func statusIcon(
        _ context: ActivityViewContext<RecordingActivityAttributes>
    ) -> some View {
        Image(systemName: context.state.isPaused ? "pause.circle.fill" : "waveform")
            .foregroundStyle(
                context.state.isPaused
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
    }

    private func timer(
        _ context: ActivityViewContext<RecordingActivityAttributes>
    ) -> some View {
        Text(
            timerInterval: context.attributes.startedAt...Date.distantFuture,
            countsDown: false)
    }

    private var stopButton: some View {
        Button(intent: StopRecordingIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }
}
