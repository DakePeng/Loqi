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

    /// SenseVoice tokenizes ja/zh output with literal spaces ("黒川 さん の
    /// ボス" in a 2026-07-07 session export); the decoder must collapse them
    /// without touching languages where spaces carry meaning.
    @Test func decoderCollapsesIntraCJKTokenSpaces() {
        #expect(SenseVoiceDecoder.collapsedCJKTokenSpaces(
            "黒川 さん の ボス の ボス、アピ 本部 長 の 大野 さん")
            == "黒川さんのボスのボス、アピ本部長の大野さん")
        // Double spaces collapse too.
        #expect(SenseVoiceDecoder.collapsedCJKTokenSpaces("話 が  大野 さん")
            == "話が大野さん")
        // Latin, digit, and Korean boundaries keep their spaces.
        #expect(SenseVoiceDecoder.collapsedCJKTokenSpaces("Wi-Fi ルーター と 3 キロ")
            == "Wi-Fi ルーターと 3 キロ")
        #expect(SenseVoiceDecoder.collapsedCJKTokenSpaces("we meet tomorrow")
            == "we meet tomorrow")
        #expect(SenseVoiceDecoder.collapsedCJKTokenSpaces("안녕하세요 만나서 반갑습니다")
            == "안녕하세요 만나서 반갑습니다")
    }
}
