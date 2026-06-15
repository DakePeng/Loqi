import SwiftUI

/// Onboarding step: the selected models download one after another with a
/// row per item. Failures don't block the queue — each failed row offers
/// Retry, "Skip remaining" settles everything, and the finish button only
/// appears once every row has landed somewhere.
struct OnboardingDownloadStep: View {
    let model: OnboardingDownloadModel
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("Downloading models")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                VStack(spacing: 12) {
                    ForEach(model.items) { item in
                        itemRow(item)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { footer }
        // Mirror SettingsView's wiring: these stores publish a fraction, the
        // speedometer turns it into a size/speed readout.
        .onChange(of: model.senseVoiceStore.progress) { _, fraction in
            model.item(for: .senseVoice)?.speedometer.update(fraction)
        }
        .onChange(of: model.qwen3Store.progress) { _, fraction in
            model.item(for: .qwen3ASR)?.speedometer.update(fraction)
        }
    }

    private func itemRow(_ item: OnboardingDownloadModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.kind.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                statusView(item.status)
            }

            switch item.status {
            case .downloading:
                if item.kind == .appleSpeech {
                    ProgressView(value: item.assetFraction)
                    if let language = item.assetCaption {
                        Text("Downloading \(language)…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    DownloadProgressRow(speedometer: item.speedometer)
                }
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Retry") {
                    model.retry(item.kind)
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            default:
                EmptyView()
            }
        }
        .padding(14)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func statusView(_ status: OnboardingDownloadModel.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tertiary)
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Text("Skipped")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.allSettled {
                if model.anyUnfinished {
                    Text("Some downloads didn’t finish. You can get them anytime in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Start Using Loqi", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Text("Keep Loqi open while models download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Skip remaining") {
                    model.skipRemaining()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }
}
