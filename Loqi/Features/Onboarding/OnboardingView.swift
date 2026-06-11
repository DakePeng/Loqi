import SwiftUI

/// First-run flow: mic permission, then batch download of speech models
/// for all three languages. Translation packs and the LLM/speaker models
/// download on first use; Settings manages them afterwards.
struct OnboardingView: View {
    let onComplete: () -> Void

    private enum Step {
        case welcome
        case permission
        case assets
    }

    private enum AssetState: Equatable {
        case pending
        case downloading(Double)
        case done
        case unsupported
        case failed
    }

    @State private var step = Step.welcome
    @State private var assetStates: [AppLanguage: AssetState] = [:]
    @State private var assetError: String?
    @State private var micDenied = false
    private let assets = AssetManager()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Loqi")
                .font(.largeTitle.bold())
            Text("Private on-device voice notes, transcripts and summaries — with live translation.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Spacer()

            switch step {
            case .welcome:
                Button("Get Started") { step = .permission }
                    .buttonStyle(.borderedProminent)

            case .permission:
                VStack(spacing: 12) {
                    Text("Loqi needs the microphone to hear speech. Audio is processed entirely on-device.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                    if micDenied {
                        Text("Microphone access is off. Loqi cannot transcribe without it.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        Button("Continue anyway") {
                            advanceToAssets()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Allow Microphone") {
                            Task {
                                let granted = await AudioCaptureService.requestPermission()
                                if granted {
                                    advanceToAssets()
                                } else {
                                    micDenied = true
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

            case .assets:
                VStack(spacing: 12) {
                    ForEach(AppLanguage.allCases) { language in
                        HStack {
                            Text(language.displayName)
                            Spacer()
                            assetStatusView(assetStates[language] ?? .pending)
                        }
                        .padding(.horizontal, 48)
                    }
                    Text("Translation language packs and the enhanced-translation model download on first use. Manage them anytime in Settings.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    if let assetError {
                        Text(assetError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await downloadAssets() }
                        }
                        Button("Skip for now") {
                            onComplete()
                        }
                    }
                }
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func assetStatusView(_ state: AssetState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .downloading(let progress):
            ProgressView(value: progress).frame(width: 120)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .unsupported:
            Text("Not supported on this device")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func advanceToAssets() {
        step = .assets
        Task { await downloadAssets() }
    }

    private func downloadAssets() async {
        assetError = nil
        var anyFailure = false
        for language in AppLanguage.allCases {
            if assetStates[language] == .done || assetStates[language] == .unsupported {
                continue
            }
            let status = await assets.speechAssetStatus(for: language)
            guard status != .unsupported else {
                assetStates[language] = .unsupported
                continue
            }
            do {
                assetStates[language] = .downloading(0)
                try await assets.installSpeechAssets(for: language) { progress in
                    Task { @MainActor in
                        assetStates[language] = .downloading(progress)
                    }
                }
                assetStates[language] = .done
            } catch {
                assetStates[language] = .failed
                anyFailure = true
            }
        }
        if anyFailure {
            assetError = "Some downloads failed. Check your connection and retry."
        } else {
            onComplete()
        }
    }
}
