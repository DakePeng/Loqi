import SwiftUI

@main
struct LocallyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var pipeline = CaptionPipeline()
    @Environment(\.scenePhase) private var scenePhase
    @State private var sharedAudioURL: URL?

    var body: some View {
        Group {
            if onboardingComplete {
                TabView {
                    Tab("Record", systemImage: "mic") {
                        LiveCaptionsView(pipeline: pipeline)
                    }
                    Tab("Sessions", systemImage: "clock") {
                        SessionsView(pipeline: pipeline)
                    }
                    Tab("Settings", systemImage: "gearshape") {
                        SettingsView(pipeline: pipeline)
                    }
                }
            } else {
                OnboardingView {
                    onboardingComplete = true
                }
            }
        }
        // Translation sessions only exist while their host views are
        // attached, so the stack lives at the root for the app's lifetime.
        .background(TranslationHostStack(coordinator: pipeline.translator))
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification)
        ) { _ in
            pipeline.handleMemoryWarning()
        }
        .onOpenURL { url in
            sharedAudioURL = url
        }
        .sheet(item: $sharedAudioURL) { url in
            ImportAudioSheet(url: url, pipeline: pipeline)
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background: pipeline.handleBackground()
            case .active: pipeline.handleForeground()
            default: break
            }
        }
    }
}
