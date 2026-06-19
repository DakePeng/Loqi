import Foundation

/// SenseVoice live-decode knobs. The recognizer is non-streaming and
/// re-decodes the *entire growing utterance* every partial interval, so
/// raising the interval and dropping decode threads are the two cheapest
/// during-speech heat cuts. ponytail: two constants, gated by one toggle.
enum SenseVoiceTuning {
    /// Samples between volatile partial re-decodes (16kHz). 0.7s default;
    /// ~1.6s under reduce-heat — captions pulse a little slower, the final
    /// decode at the pause is unchanged.
    static func partialInterval(reduceHeat: Bool) -> Int {
        reduceHeat ? 25_600 : 11_200
    }

    /// ONNX decode threads for the live engine. Fewer = lower peak CPU/heat
    /// at slightly slower partials.
    static func decoderThreads(reduceHeat: Bool) -> Int {
        reduceHeat ? 1 : 2
    }
}
