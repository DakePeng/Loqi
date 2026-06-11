import Foundation

/// Events emitted by TranscriptionEngine, consumed by TranscriptSegmenter.
enum TranscriptionEvent: Sendable {
    /// In-progress hypothesis for the current utterance; replaces the
    /// previous volatile text entirely.
    case volatile(String)
    /// The current utterance's text will not change anymore.
    case finalized(String)
    /// The engine stopped (end of session or error).
    case ended(Error?)
    /// Voice activity changed (from the SpeechDetector VAD module).
    case speechActivity(Bool)
}
