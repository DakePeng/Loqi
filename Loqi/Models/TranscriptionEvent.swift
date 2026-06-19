import Foundation

/// A timestamped run of finalized text — the smallest piece carrying its own
/// audio time range, so the diarizer can attribute it to a speaker. Engines
/// that can't produce per-run timings (SenseVoice, Qwen3) emit `runs: nil`
/// and the utterance stays a single speaker-attributed entry.
struct TimedRun: Sendable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Events emitted by TranscriptionEngine, consumed by TranscriptSegmenter.
enum TranscriptionEvent: Sendable {
    /// In-progress hypothesis for the current utterance; replaces the
    /// previous volatile text entirely.
    case volatile(String, language: AppLanguage?)
    /// The current utterance's text will not change anymore. `runs` carries
    /// per-word audio time ranges when the engine provides them (Apple),
    /// enabling a mid-utterance speaker split; nil otherwise.
    case finalized(String, runs: [TimedRun]?, language: AppLanguage?)
    /// The engine stopped (end of session or error).
    case ended(Error?)
    /// Voice activity changed (from the SpeechDetector VAD module).
    case speechActivity(Bool)
}
