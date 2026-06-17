import SwiftUI

/// First-run flow: mic permission, then a guided model setup — pick a
/// download region, choose models (recommended: SenseVoice + speaker model
/// + Qwen3.5 2B + translation packs, with Qwen3-ASR optional), and watch
/// them install. Apple speech assets ride along as the always-included
/// fallback live engine. Every download is skippable; models remain in
/// Settings and system packs can prompt again on first use.
struct OnboardingView: View {
    let pipeline: CaptionPipeline
    let onComplete: () -> Void

    private enum Step {
        case welcome
        case permission
        case region
        case models
        case download
    }

    @State private var step = Step.welcome
    @State private var micDenied = false
    @State private var region = DownloadRegion.suggested(for: Locale.current.region)
    @State private var selection = OnboardingItemKind.defaultSelection
    @State private var downloads: OnboardingDownloadModel

    init(pipeline: CaptionPipeline, onComplete: @escaping () -> Void) {
        self.pipeline = pipeline
        self.onComplete = onComplete
        _downloads = State(initialValue: OnboardingDownloadModel(pipeline: pipeline))
    }

    var body: some View {
        switch step {
        case .welcome, .permission:
            hero
        case .region:
            OnboardingRegionStep(selected: $region, onContinue: confirmRegion)
        case .models:
            OnboardingModelStep(
                selection: $selection,
                onDownload: startDownloads,
                onSkip: onComplete)
        case .download:
            OnboardingDownloadStep(model: downloads, onFinish: onComplete)
        }
    }

    /// The logo screen shared by the first two steps; the later steps need
    /// the full height for their lists.
    private var hero: some View {
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

            if step == .welcome {
                Button("Get Started") { step = .permission }
                    .buttonStyle(.borderedProminent)
            } else {
                permissionControls
            }
            Spacer()
        }
        .padding()
    }

    private var permissionControls: some View {
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
                    SystemSettings.openMicrophonePrivacy()
                }
                Button("Continue anyway") { step = .region }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Allow Microphone") {
                    Task {
                        let granted = await AudioCaptureService.requestPermission()
                        if granted {
                            step = .region
                        } else {
                            micDenied = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// One write covers all three source settings, plus an in-memory sync:
    /// the shared pipeline captured "model.source" at construction, before
    /// these keys existed.
    private func confirmRegion() {
        region.persistSources()
        let llm = pipeline.llm
        let source = region.llmSource
        Task { await llm.setSource(source) }
        step = .models
    }

    private func startDownloads() {
        step = .download
        downloads.start(selection: selection, region: region)
    }
}
