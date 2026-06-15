import Foundation

/// Hard ceiling on one continuous VAD speech run. sherpa-onnx's
/// `max_speech_duration` doesn't force a segment closed — it only tightens
/// the gate (threshold 0.9, hangover 0.1s) and waits for a dip. In steady
/// noise or music no dip ever comes: the segment stays open, the VAD's
/// circular buffer grows past capacity ("Overflow!" + resize), every
/// 512-sample window re-copies the whole run, and the eventual decode gets
/// minutes of audio at once — enough memory churn to take the app down.
/// Callers tick this per fed chunk and force `vad.flush()` when it fires;
/// flush closes the segment at the current tail, which is the hard split
/// the config option never does.
struct SpeechRunLimiter {
    /// Longest tolerated single run, in samples.
    let limit: Int
    private(set) var run = 0

    /// Returns true when the open run just hit the ceiling; the caller
    /// must flush the VAD. The counter restarts so the next run is fresh.
    mutating func shouldSplit(isSpeech: Bool, samples: Int) -> Bool {
        guard isSpeech else {
            run = 0
            return false
        }
        run += samples
        guard run >= limit else { return false }
        run = 0
        return true
    }
}
