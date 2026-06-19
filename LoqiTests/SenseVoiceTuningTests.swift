import Foundation
import Testing

@testable import Loqi

struct SenseVoiceTuningTests {
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
