import SwiftUI

/// Onboarding step: pick where model downloads come from. One choice fans
/// out into all three per-model source settings (LLM, ASR, diarizer), with
/// the locale-appropriate option pre-selected and badged.
struct OnboardingRegionStep: View {
    @Binding var selected: DownloadRegion
    let onContinue: () -> Void

    private let suggested = DownloadRegion.suggested(for: Locale.current.region)

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("Where should models download from?")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Loqi downloads its speech and AI models once, then runs fully on this iPhone. Pick the source that works best on your network.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                VStack(spacing: 12) {
                    ForEach(DownloadRegion.allCases) { region in
                        regionCard(region)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("You can change download sources anytime in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.bar)
        }
    }

    private func regionCard(_ region: DownloadRegion) -> some View {
        Button {
            selected = region
        } label: {
            HStack(spacing: 12) {
                Image(systemName: region.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(region.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(region.sourceSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected == region ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        selected == region ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(14)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if selected == region {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if region == suggested {
                    Text("Suggested")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.tint, in: Capsule())
                        .offset(x: -6, y: -7)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
