import SwiftUI

/// One status surface for both modes: every pipeline subsystem message
/// (interruption, thermal, memory, LLM, diarizer) plus the last error.
/// Conversation previously rendered none of these — a paused mic was
/// invisible exactly where it mattered most.
struct PipelineStatusBar: View {
    let pipeline: CaptionPipeline

    var body: some View {
        VStack(spacing: 6) {
            ForEach(pipeline.statusBanner, id: \.self) { status in
                pill(status, icon: "info.circle", isError: false)
            }
            if let error = pipeline.lastError {
                pill(error, icon: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }

    private func pill(_ text: String, icon: String, isError: Bool) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(isError ? .red : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .multilineTextAlignment(.center)
    }
}

/// Mic button wrapper that reads pipeline.level inside its OWN body, so the
/// ~10Hz level changes invalidate only this leaf view — not the entire
/// transcript (which previously re-filtered and regrouped hundreds of
/// entries at audio rate).
struct LiveLevelMicButton: View {
    let pipeline: CaptionPipeline
    var isLive: Bool
    var size: CGFloat = 72
    let action: () -> Void

    var body: some View {
        MicButton(
            isLive: isLive,
            level: isLive ? pipeline.level : 0,
            size: size,
            action: action)
    }
}
