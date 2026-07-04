import SwiftUI

#if os(iOS)
final class LoqiAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        BackgroundModelDownloader.shared.setCompletionHandler(
            completionHandler,
            for: identifier)
    }
}
#endif

@main
struct LoqiApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(LoqiAppDelegate.self) private var appDelegate
    #endif

    init() {
        #if DEBUG
        // UI tests re-enter onboarding by deleting the gate: an argument-
        // domain override ("-onboardingComplete NO") would also shadow the
        // completion write, so the test could never observe the app after
        // onboarding finishes.
        if CommandLine.arguments.contains("--uitest-reset-onboarding") {
            UserDefaults.standard.removeObject(forKey: "onboardingComplete")
        }
        #endif
        // A force-quit/jetsam mid-recording leaves a zombie "Recording"
        // Live Activity on the lock screen. Sweep before anything (an App
        // Intent included) can start a new session.
        #if os(iOS)
        Task { await RecordingActivityController.endAllStale() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage(AppUILanguage.defaultsKey) private var appLanguageRaw = AppUILanguage.system.rawValue
    /// The shared instance: App Intents drive the same pipeline (plain
    /// `let` is fine — @Observable tracking doesn't need @State).
    private let pipeline = CaptionPipeline.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var sharedAudioURL: URL?
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if onboardingComplete {
                TabView(selection: $selectedTab) {
                    Tab("Record", systemImage: "mic", value: 0) {
                        LiveCaptionsView(
                            pipeline: pipeline,
                            switchToSessions: { selectedTab = 1 })
                    }
                    Tab("Sessions", systemImage: "clock", value: 1) {
                        SessionsView(pipeline: pipeline)
                    }
                    Tab("Vocabulary", systemImage: "character.book.closed", value: 2) {
                        VocabularyView(store: pipeline.hotwords)
                    }
                    .badge(pipeline.hotwords.pending.count)
                    Tab("Settings", systemImage: "gearshape", value: 3) {
                        SettingsView(pipeline: pipeline)
                    }
                }
            } else {
                OnboardingView(pipeline: pipeline) {
                    onboardingComplete = true
                }
            }
        }
        .environment(\.locale, appUILanguage.locale)
        // Translation sessions only exist while their host views are
        // attached, so the stack lives at the root for the app's lifetime.
        .background(TranslationHostStack(coordinator: pipeline.translator))
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification)
        ) { _ in
            pipeline.handleMemoryWarning()
        }
        #endif
        .onOpenURL { url in
            sharedAudioURL = url
        }
        .sheet(item: $sharedAudioURL) { url in
            ImportAudioSheet(url: url, pipeline: pipeline)
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .inactive: pipeline.handleInactive()
            case .background: pipeline.handleBackground()
            case .active: pipeline.handleForeground()
            @unknown default: break
            }
        }
    }

    private var appUILanguage: AppUILanguage {
        AppUILanguage(rawValue: appLanguageRaw) ?? .system
    }
}
