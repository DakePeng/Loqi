import Foundation

/// User-tunable speech pickup: how hard the capture chain and the VADs
/// reach for faint speech. One choice maps onto every stage — the
/// capture-side boost ceiling, silero threshold/hangover (SenseVoice),
/// and SpeechDetector sensitivity (Apple) — and is switchable mid-session
/// from the Record chips (the pipeline restarts its turn to rebind).
enum MicSensitivity: String, CaseIterable, Identifiable, Sendable {
    /// Strict and unboosted: only voices right at the phone, for noisy
    /// places where background talkers must NOT land in the transcript.
    case near
    /// Middle-ground tuning.
    case balanced
    /// Reach across a meeting room: max boost, permissive VAD.
    case far

    var id: String { rawValue }

    static let defaultsKey = "capture.sensitivity"

    /// Persisted choice; absence of the key = .far.
    static var current: MicSensitivity {
        MicSensitivity(
            rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        ) ?? .far
    }

    var displayName: String {
        switch self {
        case .near: String(localized: "Close-up")
        case .balanced: String(localized: "Balanced")
        case .far: String(localized: "Meeting room")
        }
    }

    /// Fits the slim recording bar.
    var shortName: String {
        switch self {
        case .near: String(localized: "Close")
        case .balanced: String(localized: "Balanced")
        case .far: String(localized: "Room")
        }
    }

    var symbolName: String {
        switch self {
        case .near: "person.wave.2"
        case .balanced: "mic.and.signal.meter"
        case .far: "wave.3.right"
        }
    }

    /// Ceiling for the capture-side FarFieldGain boost (1 = off).
    var maxBoost: Float {
        switch self {
        case .near: 1
        case .balanced: 8
        case .far: 12
        }
    }

    /// Silero speech-probability threshold (SenseVoice VAD). Far-field
    /// speech is reverb-smeared and hovers mid-probability; close-up
    /// wants strict gating so background voices stay out. Upstream's
    /// "lazy" default is 0.5; one step more sensitive across the board
    /// because faint speech dropping out hurt more than noise getting in
    /// (sherpa exits speech at threshold − 0.15, so the tail loosens
    /// with it; SpeechRunLimiter caps the runaway-segment risk).
    var sileroThreshold: Float {
        switch self {
        case .near: 0.4
        case .balanced: 0.3
        case .far: 0.2
        }
    }

    /// Trailing silence before silero closes a segment: distant speech
    /// has soft tails that a short hangover chops mid-word.
    var sileroMinSilence: Float {
        switch self {
        case .near: 0.5
        case .balanced: 0.5
        case .far: 0.7
        }
    }
}
