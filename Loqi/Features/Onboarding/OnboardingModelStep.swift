import SwiftUI

/// Onboarding step: choose which models to install. The recommended set
/// (translation packs + SenseVoice + speaker model + Qwen3.5 2B) comes
/// pre-checked, Qwen3-ASR is an unchecked extra, and Apple speech assets
/// are locked on. Skipping is always allowed — Settings offers models
/// later, while system packs prompt again on first use.
struct OnboardingModelStep: View {
    @Binding var selection: Set<OnboardingItemKind>
    let onDownload: () -> Void
    let onSkip: () -> Void

    /// Snapshotted once: a force-quit mid-flow re-enters here, and rows
    /// already on disk show as downloaded instead of re-fetching.
    private let installed = OnboardingItemKind.installedNow

    private var totalBytes: Int64 {
        OnboardingItemKind.totalBytes(for: selection, installed: installed)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("Choose what to download")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Everything runs on this device. The recommended set gives you accurate live captions, speaker separation and AI summaries.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                VStack(spacing: 12) {
                    ForEach(OnboardingItemKind.allCases) { kind in
                        itemRow(kind)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if totalBytes > 0 {
                    Text("Total download: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Download", action: onDownload)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Skip for now", action: onSkip)
                    .buttonStyle(.borderless)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.bar)
        }
    }

    private func itemRow(_ kind: OnboardingItemKind) -> some View {
        let isInstalled = installed.contains(kind)
        let isChecked = kind.alwaysIncluded || isInstalled || selection.contains(kind)
        let locked = kind.alwaysIncluded || isInstalled

        return Button {
            if selection.contains(kind) {
                selection.remove(kind)
            } else {
                selection.insert(kind)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(checkboxStyle(installed: isInstalled, checked: isChecked))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kind.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if kind.isRecommended && !isInstalled {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(kind.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                trailingCaption(kind, installed: isInstalled)
            }
            .padding(14)
            .background(
                Color.loqiSecondarySystemBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    private func checkboxStyle(installed: Bool, checked: Bool) -> AnyShapeStyle {
        if installed { return AnyShapeStyle(.green) }
        return checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
    }

    @ViewBuilder
    private func trailingCaption(_ kind: OnboardingItemKind, installed: Bool) -> some View {
        Group {
            if installed {
                Text("Downloaded")
            } else if kind.alwaysIncluded {
                Text("Included")
            } else if kind == .translationPacks {
                Text("System")
            } else if let bytes = kind.downloadBytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
