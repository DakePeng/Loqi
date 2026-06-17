import AVFoundation
import Foundation

/// Captures microphone audio and yields buffers converted to the format the
/// speech analyzer wants. The tap callback runs on a realtime audio thread:
/// it must only convert and yield — never touch actors or allocate UI state.
final class AudioCaptureService: @unchecked Sendable {
    struct Levels: Sendable {
        /// Post-boost RMS power in [0, 1] for the level meter — what the
        /// recognizers hear, so a distant talker registers visibly.
        var rms: Float
    }

    /// AVAudioPCMBuffer is not Sendable, but each converted buffer is
    /// freshly allocated and never touched again after being yielded, so
    /// handing it across to the transcription actor is safe.
    struct AudioChunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var farFieldGain = FarFieldGain()
    private var bufferContinuation: AsyncStream<AudioChunk>.Continuation?
    private var levelContinuation: AsyncStream<Levels>.Continuation?

    private(set) var isRunning = false

    static func requestPermission() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
        #endif
    }

    /// Start the engine. Returns a stream of buffers in `outputFormat`
    /// (pass the analyzer's best available format), plus a level stream
    /// for UI metering and silence detection.
    func start(
        outputFormat: AVAudioFormat
    ) throws -> (buffers: AsyncStream<AudioChunk>, levels: AsyncStream<Levels>) {
        precondition(!isRunning, "AudioCaptureService started twice")

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Capture-only session (.playAndRecord dated from the deleted TTS
        // feature; saved-session playback runs its own .playback session).
        // No Bluetooth option on purpose: an HFP headset mic is narrowband
        // and beamformed at the wearer's mouth, so with AirPods connected a
        // meeting capture silently degrades to "me and my neighbors" — the
        // built-in mic must stay the recording device (wired/USB mics still
        // win the route). Default mode, NOT .measurement: measurement
        // disables the system's automatic gain control and mic processing,
        // which made far-away speakers too quiet to transcribe at all.
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        Self.tuneForRoomCapture(session)
        #endif

        // Fresh adaptation per turn — a stale boost from the previous room
        // shouldn't color the first seconds — with the reach the user's
        // pickup preset asks for.
        farFieldGain = FarFieldGain(maxGain: MicSensitivity.current.maxBoost)

        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: tapFormat, to: outputFormat)

        let (buffers, bufferCont) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        let (levels, levelCont) = AsyncStream<Levels>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        bufferContinuation = bufferCont
        levelContinuation = levelCont

        // ~43ms at 48kHz: small buffers keep caption latency low without
        // measurable CPU cost.
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }

            let ratio = outputFormat.sampleRate / tapFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: capacity
            ) else { return }

            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 {
                let rms = self.farFieldGain.apply(to: converted)
                self.levelContinuation?.yield(Levels(rms: min(1, rms * 4)))
                self.bufferContinuation?.yield(AudioChunk(buffer: converted))
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        return (buffers, levels)
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferContinuation?.finish()
        levelContinuation?.finish()
        bufferContinuation = nil
        levelContinuation = nil
        converter = nil
        isRunning = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

#if os(iOS)
    /// Meeting-room tuning for the built-in mic: the default data source
    /// runs a directional pattern favoring the device holder, so ask for
    /// omnidirectional pickup (and full input gain where settable) to give
    /// talkers across the room their best shot. External mics are the
    /// user's own choice and are left untouched.
    private static func tuneForRoomCapture(_ session: AVAudioSession) {
        guard session.currentRoute.inputs.allSatisfy({ $0.portType == .builtInMic }),
              let builtIn = session.availableInputs?
                  .first(where: { $0.portType == .builtInMic })
        else { return }

        let omniCapable: (AVAudioSessionDataSourceDescription) -> Bool = {
            $0.supportedPolarPatterns?.contains(.omnidirectional) == true
        }
        let source = builtIn.selectedDataSource.flatMap { omniCapable($0) ? $0 : nil }
            ?? builtIn.dataSources?.first(where: omniCapable)
        if let source {
            try? source.setPreferredPolarPattern(.omnidirectional)
            try? builtIn.setPreferredDataSource(source)
        }
        if session.isInputGainSettable {
            try? session.setInputGain(1)
        }
    }
#endif
}

/// Adaptive far-field boost. The system mic chain (AGC included) is tuned
/// for the person holding the phone; a talker across a meeting room lands
/// 15–25 dB lower, where VAD and endpointing shred their speech into
/// fragments. Buffers clearly above the tracked noise floor get lifted
/// toward a working speech level; plain room noise never qualifies, so
/// silence is not amplified into phantom speech. Runs inside the tap
/// callback: pure math, no allocation, no locks.
struct FarFieldGain {
    private var gain: Float = 1
    /// Fast-falling, slow-rising estimate of the room's noise RMS.
    private var noiseFloor: Float = 0.001
    /// Boost ceiling from the pickup preset: 1 disables the stage,
    /// ~8 (+18 dB) reaches across a table, ~12 (+21.6 dB) across a room —
    /// while staying low enough not to turn HVAC rumble into speech-level
    /// energy.
    private let maxGain: Float

    /// ≈ -22 dBFS — the ballpark the recognizers see from near speech.
    private static let targetRMS: Float = 0.08

    /// Ceiling for the slow-rising noise-floor estimate. Set to targetRMS/3 so
    /// the `floor * 3` speech gate can climb all the way to the target in a
    /// loud room: with the old 0.02 cap the gate pinned at 0.06, permanently
    /// below the target, so steady room noise in the 0.06–0.08 band kept
    /// reading as "speech." Above the target, noise is never boosted anyway
    /// (the desired gain clamps to ≥1). Residual: gain that ramped up before
    /// the floor caught up still holds — full release would need to
    /// distinguish a pause from sustained noise, which the pause-hold contract
    /// depends on, so it's left to the AGC's existing dynamics.
    private static let noiseFloorCeiling: Float = targetRMS / 3

    init(maxGain: Float = 8) {
        self.maxGain = max(1, maxGain)
    }

    /// Boost `buffer` in place. Returns the post-boost RMS of channel 0,
    /// which the caller reuses for the level meter.
    mutating func apply(to buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0
        else { return 0 }
        let count = Int(buffer.frameLength)
        let data = channels[0]
        var energy: Float = 0
        var peak: Float = 0
        for i in 0..<count {
            let v = data[i]
            energy += v * v
            peak = max(peak, abs(v))
        }
        let rms = sqrt(energy / Float(count))

        if rms < noiseFloor {
            noiseFloor = max(rms, 0.0002)
        } else {
            noiseFloor = min(noiseFloor * 1.004, Self.noiseFloorCeiling)
        }

        // Adapt only on plausible speech (well above the floor); through
        // pauses the gain holds, so a gap mid-sentence doesn't reset the
        // boost the sentence needed.
        if rms > noiseFloor * 3, rms > 0.001 {
            let desired = min(max(Self.targetRMS / rms, 1), maxGain)
            // Fast attack down (a near talker after a far one), slow
            // release up (no pumping across syllable gaps).
            gain += (desired - gain) * (desired < gain ? 0.5 : 0.1)
        }

        // Peak-safe: never boost into clipping, never attenuate.
        let applied = max(1, min(gain, peak > 0 ? 0.95 / peak : gain))
        if applied > 1.001 {
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for i in 0..<count {
                    samples[i] *= applied
                }
            }
        }
        return rms * applied
    }
}
