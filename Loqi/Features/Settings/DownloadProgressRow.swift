import SwiftUI

/// Turns a stream of fraction-complete updates into a smoothed download speed
/// and a human-readable "done / total · speed" readout. Shared by every model
/// download in Settings (LLM, SenseVoice, speaker model) so they all show the
/// same progress detail. Speed is estimated: most downloaders report only a
/// completion fraction, so we scale it by the model's known total size.
@MainActor
@Observable
final class DownloadSpeedometer {
    private(set) var fraction: Double = 0
    /// Smoothed bytes/second, or nil until there are two samples.
    private(set) var speed: Double?
    private(set) var totalBytes: Int64 = 0
    private var lastSample: (time: Date, fraction: Double)?

    /// Begin a fresh download of a known total size.
    func start(totalBytes: Int64) {
        self.totalBytes = totalBytes
        fraction = 0
        speed = nil
        lastSample = nil
    }

    /// Feed the latest completion fraction (0…1).
    func update(_ f: Double) {
        let now = Date()
        if let last = lastSample {
            let dt = now.timeIntervalSince(last.time)
            // Sample at ≥0.5s intervals so the rate doesn't jitter.
            if dt >= 0.5 {
                let instant = max(0, f - last.fraction) * Double(totalBytes) / dt
                speed = speed.map { $0 * 0.6 + instant * 0.4 } ?? instant
                lastSample = (now, f)
            }
        } else {
            lastSample = (now, f)
        }
        fraction = f
    }

    /// "612 MB / 1.3 GB · 4.2 MB/s"
    var detail: String {
        let done = Int64(Double(totalBytes) * fraction)
        var text = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
            + " / " + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        if let speed, speed > 0 {
            text += " · " + ByteCountFormatter.string(
                fromByteCount: Int64(speed), countStyle: .file) + "/s"
        }
        return text
    }
}

/// Progress bar + "done / total · speed" line, with an optional Stop button.
struct DownloadProgressRow: View {
    let speedometer: DownloadSpeedometer
    var onStop: (() -> Void)?

    var body: some View {
        ProgressView(value: speedometer.fraction)
        HStack {
            Text(speedometer.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let onStop {
                Spacer()
                Button("Stop", role: .destructive, action: onStop)
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
    }
}
