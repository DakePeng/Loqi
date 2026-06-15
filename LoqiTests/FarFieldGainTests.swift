import AVFoundation
import Testing

@testable import Loqi

/// FarFieldGain contract: distant (quiet) speech is lifted toward the
/// target level, near speech and steady room noise are left alone, and
/// no amount of boost may clip.
struct FarFieldGainTests {
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    /// One ~43ms capture chunk of a 220 Hz sine (RMS ≈ amplitude / √2).
    private func chunk(amplitude: Float, frames: AVAudioFrameCount = 683) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            data[i] = amplitude * sin(Float(i) * 2 * .pi * 220 / 16_000)
        }
        return buffer
    }

    private func peak(of buffer: AVAudioPCMBuffer) -> Float {
        let data = buffer.floatChannelData![0]
        return (0..<Int(buffer.frameLength)).reduce(0) { max($0, abs(data[$1])) }
    }

    @Test func distantSpeechRisesTowardTarget() {
        var gain = FarFieldGain()
        var rms: Float = 0
        for _ in 0..<60 {
            rms = gain.apply(to: chunk(amplitude: 0.014))  // RMS ≈ 0.01
        }
        #expect(rms > 0.05, "far speech should approach the ~0.08 target")
    }

    @Test func nearSpeechIsUntouched() {
        var gain = FarFieldGain()
        for _ in 0..<20 {
            let buffer = chunk(amplitude: 0.3)  // RMS ≈ 0.21, above target
            _ = gain.apply(to: buffer)
            #expect(peak(of: buffer) <= 0.301)
        }
    }

    @Test func silenceStaysSilent() {
        var gain = FarFieldGain()
        let silent = chunk(amplitude: 0)
        for _ in 0..<20 {
            #expect(gain.apply(to: silent) == 0)
        }
        #expect(peak(of: silent) == 0)
    }

    @Test func steadyRoomNoiseIsNotBoosted() {
        var gain = FarFieldGain()
        var rms: Float = 0
        for _ in 0..<100 {
            rms = gain.apply(to: chunk(amplitude: 0.003))  // RMS ≈ 0.0021
        }
        // The noise floor tracks a constant hum, so the speech gate never
        // opens and the hum is never dragged up to speech level.
        #expect(rms < 0.004)
    }

    @Test func steadyLoudNoiseAboveTargetIsNeverBoosted() {
        // A loud room (RMS ≈ 0.085, above the ~0.08 target): the desired gain
        // clamps to ≥1, so steady noise at or above speech level is passed
        // through, never dragged higher.
        var gain = FarFieldGain()
        var rms: Float = 0
        for _ in 0..<200 {
            let buffer = chunk(amplitude: 0.12)  // RMS ≈ 0.085
            rms = gain.apply(to: buffer)
            #expect(peak(of: buffer) <= 0.121)  // unamplified
        }
        #expect(rms <= 0.086, "loud steady noise must not be lifted above its own level")
    }

    @Test func boostNeverClips() {
        var gain = FarFieldGain()
        for _ in 0..<60 {
            _ = gain.apply(to: chunk(amplitude: 0.014))  // ride gain up
        }
        let loud = chunk(amplitude: 0.9)
        _ = gain.apply(to: loud)
        #expect(peak(of: loud) <= 0.96)
    }

    /// The "Close-up" pickup preset (maxGain 1) turns the stage off: far
    /// speech passes through untouched, only the meter RMS is computed.
    @Test func unityCeilingDisablesBoost() {
        var gain = FarFieldGain(maxGain: 1)
        let expected: Float = 0.014 / Float(2).squareRoot()
        for _ in 0..<60 {
            let buffer = chunk(amplitude: 0.014)
            let rms = gain.apply(to: buffer)
            #expect(abs(rms - expected) < 0.001)
            #expect(peak(of: buffer) <= 0.0141)
        }
    }

    /// The "Meeting room" preset reaches further than the default ceiling.
    @Test func higherCeilingBoostsFainterSpeech() {
        var defaultGain = FarFieldGain()
        var roomGain = FarFieldGain(maxGain: 12)
        var defaultRMS: Float = 0
        var roomRMS: Float = 0
        for _ in 0..<80 {
            defaultRMS = defaultGain.apply(to: chunk(amplitude: 0.008))
            roomRMS = roomGain.apply(to: chunk(amplitude: 0.008))
        }
        #expect(roomRMS > defaultRMS * 1.2)
    }

    @Test func boostHoldsThroughPauses() {
        var gain = FarFieldGain()
        for _ in 0..<60 {
            _ = gain.apply(to: chunk(amplitude: 0.014))
        }
        for _ in 0..<30 {  // ~1.3s pause between sentences
            _ = gain.apply(to: chunk(amplitude: 0))
        }
        // The next far-field sentence is boosted from its first chunk,
        // not re-learned from scratch.
        let resumed = gain.apply(to: chunk(amplitude: 0.014))
        #expect(resumed > 0.05)
    }
}
