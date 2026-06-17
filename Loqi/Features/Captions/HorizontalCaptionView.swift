import SwiftUI

/// Landscape caption mode: rotate the phone and the transcript becomes a
/// full-screen teleprompter — dark background, the line being spoken in
/// large type, one line of context above it, nothing else. Made for
/// propping the phone up across a table or under a screen.
struct HorizontalCaptionView: View {
    @Bindable var pipeline: CaptionPipeline
    let entries: [CaptionEntry]
    let toggle: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Spacer(minLength: 0)

                if let latest = entries.last {
                    if let previous = entries.dropLast().last {
                        Text(line(for: previous))
                            .font(.title3.weight(.medium))
                            .foregroundStyle(Color(white: 0.45))
                            .lineLimit(2)
                    }
                    if let secondary = secondaryLine(for: latest) {
                        Text(secondary)
                            .font(.title3)
                            .foregroundStyle(Color(white: 0.55))
                            .lineLimit(1)
                    }
                    Text(line(for: latest))
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(latest.state == .volatile
                            ? Color(white: 0.8) : .white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(4)
                        .contentTransition(.opacity)
                } else {
                    Text("Ready to listen")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(Color(white: 0.45))
                }

                Spacer(minLength: 0)
                    .frame(maxHeight: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .animation(.easeInOut(duration: 0.2), value: entries.last?.id)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 14) {
                if pipeline.isPaused {
                    // The wall-clock timer keeps ticking through an
                    // interruption; over a dead mic that reads as "still
                    // recording" — show the truth instead.
                    Label("Paused", systemImage: "pause.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                } else if pipeline.isRunning, let startedAt = pipeline.sessionStartedAt {
                    Text(startedAt, style: .timer)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Color(white: 0.5))
                }
                #if os(iOS)
                Button {
                    LiveCaptionsView.rotate(to: .portrait)
                } label: {
                    Image(systemName: "iphone")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(white: 0.7))
                        .frame(width: 44, height: 44)
                        .background(Color(white: 0.16), in: Circle())
                }
                .accessibilityLabel("Portrait")
                #endif
                Button(action: toggle) {
                    Image(systemName: pipeline.isRunning ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(pipeline.isRunning ? .red : .white)
                        .frame(width: 44, height: 44)
                        .background(Color(white: 0.16), in: Circle())
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 16)
        }
        // The teleprompter is exactly where a silently paused mic matters
        // most: surface the same pipeline status portrait shows.
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                PipelineStatusBar(pipeline: pipeline)
                if !pipeline.isRunning, pipeline.lastFinishedSessionID != nil {
                    Label("Saved — rotate to portrait to review",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color(white: 0.16), in: Capsule())
                }
            }
            .padding(.top, 12)
        }
#if os(iOS)
        .statusBarHidden()
#endif
        .persistentSystemOverlays(.hidden)
    }

    /// The text worth reading big: the translation when translating (source
    /// stands in while it's pending), the transcript itself otherwise.
    private func line(for entry: CaptionEntry) -> String {
        let text = entry.direction.source == entry.direction.target
            ? entry.sourceText
            : entry.displayTranslation ?? entry.sourceText
        if let slot = entry.speaker {
            let name = pipeline.speakerNames[slot] ?? "\(slot + 1)"
            return "\(name): \(text)"
        }
        return text
    }

    /// When translating, keep the spoken-language original visible small.
    private func secondaryLine(for entry: CaptionEntry) -> String? {
        guard entry.direction.source != entry.direction.target,
              entry.displayTranslation != nil else { return nil }
        return entry.sourceText
    }
}
