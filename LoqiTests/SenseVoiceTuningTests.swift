import Foundation
import Testing

@testable import Loqi

struct SenseVoiceTuningTests {
    /// sherpa-onnx SenseVoice reports the detected language as its raw
    /// token ("<|zh|>"), not a bare code — the mapper must accept both or
    /// Auto-mode language detection silently dies (every utterance falls
    /// back to the device language and translation never triggers).
    @Test func detectedLanguageTokenParses() {
        #expect(AppLanguage(speechRecognitionCode: "<|en|>") == .english)
        #expect(AppLanguage(speechRecognitionCode: "<|zh|>") == .chinese)
        #expect(AppLanguage(speechRecognitionCode: "<|yue|>") == .chinese)
        #expect(AppLanguage(speechRecognitionCode: "<|ja|>") == .japanese)
        #expect(AppLanguage(speechRecognitionCode: "<|ko|>") == .korean)
        // Bare codes keep working; junk stays nil.
        #expect(AppLanguage(speechRecognitionCode: "en") == .english)
        #expect(AppLanguage(speechRecognitionCode: "<|nospeech|>") == nil)
        #expect(AppLanguage(speechRecognitionCode: "") == nil)
    }

    @Test func micSensitivityDefaultsToFarWhenUnset() {
        let old = UserDefaults.standard.string(forKey: MicSensitivity.defaultsKey)
        defer {
            if let old {
                UserDefaults.standard.set(old, forKey: MicSensitivity.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: MicSensitivity.defaultsKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: MicSensitivity.defaultsKey)
        #expect(MicSensitivity.current == .far)
    }

    @Test func partialIntervalSlowsUnderReduceHeat() {
        // Default cadence is 0.7s @ 16kHz = 11_200 samples.
        #expect(SenseVoiceTuning.partialInterval(reduceHeat: false) == 11_200)
        // Reduced: ~1.6s, far fewer whole-utterance re-decodes per sentence.
        #expect(SenseVoiceTuning.partialInterval(reduceHeat: true) == 25_600)
        #expect(SenseVoiceTuning.partialInterval(reduceHeat: true)
            > SenseVoiceTuning.partialInterval(reduceHeat: false))
    }

    @Test func decoderThreadsDropUnderReduceHeat() {
        #expect(SenseVoiceTuning.decoderThreads(reduceHeat: false) == 2)
        #expect(SenseVoiceTuning.decoderThreads(reduceHeat: true) == 1)
    }
}
