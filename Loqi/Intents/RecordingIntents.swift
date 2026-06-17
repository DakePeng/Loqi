import AppIntents
#if !LOQI_WIDGET
import AVFAudio
#endif

/// Recording intents, compiled into BOTH the app and the widget extension:
/// the widget needs the types for Button(intent:) and the Control Center
/// toggle, but the system executes them in the APP process — so the
/// app-only bodies (CaptionPipeline and friends) are fenced behind
/// !LOQI_WIDGET and the widget copies never run.

/// Start a session from Siri, Shortcuts, the Action Button, or the Control
/// Center toggle. AudioRecordingIntent launches the app IN THE BACKGROUND
/// to record (mic + audio background mode + Live Activity) — the app never
/// has to come to the foreground.
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts a Loqi transcription session.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !LOQI_WIDGET
        try await Self.startSession()
        #endif
        return .result()
    }

    #if !LOQI_WIDGET
    @MainActor
    static func startSession() async throws {
        // First run must happen in the app: onboarding walks through the
        // mic permission and model downloads — an intent can do neither.
        guard UserDefaults.standard.bool(forKey: "onboardingComplete"),
              AVAudioApplication.shared.recordPermission == .granted else {
            throw RecordingIntentError.setupNeeded
        }
        let pipeline = CaptionPipeline.shared
        guard !pipeline.isRunning else { return }
        try await pipeline.start(route: storedRoute())
    }

    /// Last-used languages — the same defaults the Record tab would use.
    @MainActor
    static func storedRoute() -> RecognitionRoute {
        resolveRoute(
            sourceRaw: UserDefaults.standard.string(forKey: "captions.source"),
            translationRaw: UserDefaults.standard.string(forKey: "captions.translation"))
    }

    /// Last-used languages, collapsed to a concrete direction for legacy
    /// callers/tests that cannot represent Auto.
    @MainActor
    static func storedDirection() -> LanguagePair {
        storedRoute().fallbackDirection
    }

    /// Pure + testable. Raw values follow LiveCaptionsView's @AppStorage
    /// conventions: source is an AppLanguage rawValue (missing/garbage →
    /// English); an empty or unknown translation means transcribe-only
    /// (target == source).
    static func resolveDirection(
        sourceRaw: String?, translationRaw: String?
    ) -> LanguagePair {
        resolveRoute(sourceRaw: sourceRaw, translationRaw: translationRaw).fallbackDirection
    }

    static func resolveRoute(
        sourceRaw: String?, translationRaw: String?
    ) -> RecognitionRoute {
        let source = RecognitionLanguageSelection(rawValue: sourceRaw)
        return RecognitionRoute(
            source: source,
            target: translationRaw.flatMap(AppLanguage.init(rawValue:)))
    }
    #endif
}

/// Stop the current session. LiveActivityIntent runs in the app process
/// WITHOUT foregrounding it — the Live Activity's stop button works from
/// the lock screen.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the current Loqi session and saves it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !LOQI_WIDGET
        await CaptionPipeline.shared.stop()
        #endif
        return .result()
    }
}

/// Backs the Control Center / Lock Screen / Action Button toggle.
struct ToggleRecordingIntent: SetValueIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Toggle Recording"

    @Parameter(title: "Recording")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !LOQI_WIDGET
        if value {
            try await StartRecordingIntent.startSession()
        } else {
            await CaptionPipeline.shared.stop()
        }
        #endif
        return .result()
    }
}

enum RecordingIntentError: Error, CustomLocalizedStringResourceConvertible {
    case setupNeeded

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .setupNeeded: "Open Loqi once to finish setup."
        }
    }
}
