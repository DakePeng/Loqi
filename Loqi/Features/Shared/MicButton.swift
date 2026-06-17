import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The app's primary control: a circular mic button whose ring visualizes
/// live input level, doubling as the stop button while running.
struct MicButton: View {
    var isLive: Bool
    /// Mic RMS in [0, 1]; drives the ring while live.
    var level: Float
    var size: CGFloat = 72
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(isLive ? Color.red : Color.accentColor)

                if isLive {
                    // Level ring: quiet = thin ring, loud = full circle.
                    Circle()
                        .stroke(.quaternary, lineWidth: 4)
                        .padding(-8)
                    Circle()
                        .trim(from: 0, to: max(0.04, CGFloat(level)))
                        .stroke(
                            Color.red.opacity(0.8),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-8)
                        // Reduce Motion: the ring still shows the level, it
                        // just snaps instead of smoothly tracking.
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: level)
                }

                Image(systemName: isLive ? "stop.fill" : "mic.fill")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLive ? "Stop listening" : "Start listening")
    }
}

/// Small warning shown during long sessions when the battery runs low —
/// continuous ASR (+ LLM) is a sustained drain.
struct BatteryHint: View {
    @State private var level: Float = 1

    var body: some View {
        Group {
            if level >= 0, level < 0.2 {
                Label("Low battery", systemImage: "battery.25percent")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            #if os(iOS)
            UIDevice.current.isBatteryMonitoringEnabled = true
            level = UIDevice.current.batteryLevel
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryLevelDidChangeNotification)
        ) { _ in
            level = UIDevice.current.batteryLevel
        }
        #endif
    }
}

enum Haptics {
    @MainActor
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    @MainActor
    static func turnSwitch() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }
}
