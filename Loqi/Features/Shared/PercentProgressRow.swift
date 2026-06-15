import SwiftUI

/// Determinate progress bar with a trailing percentage — the long-running
/// offline jobs (imports, re-transcription) read better with a number:
/// Qwen3-ASR decodes can sit on one segment for a minute, and a bare bar
/// over that stretch looks frozen.
struct PercentProgressRow: View {
    let label: LocalizedStringKey
    let fraction: Double
    /// Extra trailing context, e.g. "~4 min left".
    var detail: String?

    var body: some View {
        ProgressView(value: fraction) {
            HStack {
                Text(label)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
