import Foundation
import Testing
@testable import Locally

struct ImportEngineTests {
    @Test func senseVoiceUsedOnlyWhenChosenAndInstalled() {
        #expect(FileImportEngine.effectiveUseSenseVoice(choice: "sensevoice", installed: true))
        // Chosen but not downloaded → fall back to Apple.
        #expect(!FileImportEngine.effectiveUseSenseVoice(choice: "sensevoice", installed: false))
        // Apple chosen → never SenseVoice, even if installed.
        #expect(!FileImportEngine.effectiveUseSenseVoice(choice: "apple", installed: true))
        #expect(!FileImportEngine.effectiveUseSenseVoice(choice: "", installed: true))
    }

    @Test func segmentTimeRangeMapsSamplesToSeconds() {
        // 16 kHz: sample 8000 = 0.5s; 24000 samples long = 1.5s window.
        let range = SenseVoiceFileTranscriber.timeRange(
            start: 8_000, n: 24_000, sampleRate: 16_000)
        #expect(abs(range.start - 0.5) < 1e-9)
        #expect(abs(range.end - 2.0) < 1e-9)
    }

    @Test func timeRangeGuardsZeroSampleRate() {
        let range = SenseVoiceFileTranscriber.timeRange(start: 100, n: 100, sampleRate: 0)
        #expect(range.start == 100)   // divides by 1, never crashes
        #expect(range.end == 200)
    }
}
