import AVFoundation
import Foundation

/// Captures microphone audio and yields buffers converted to the format the
/// speech analyzer wants. The tap callback runs on a realtime audio thread:
/// it must only convert and yield — never touch actors or allocate UI state.
final class AudioCaptureService: @unchecked Sendable {
    struct Levels: Sendable {
        /// RMS power in [0, 1], for the level meter and silence detection.
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
    private var bufferContinuation: AsyncStream<AudioChunk>.Continuation?
    private var levelContinuation: AsyncStream<Levels>.Continuation?

    private(set) var isRunning = false

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Start the engine. Returns a stream of buffers in `outputFormat`
    /// (pass the analyzer's best available format), plus a level stream
    /// for UI metering and silence detection.
    func start(
        outputFormat: AVAudioFormat
    ) throws -> (buffers: AsyncStream<AudioChunk>, levels: AsyncStream<Levels>) {
        precondition(!isRunning, "AudioCaptureService started twice")

        let session = AVAudioSession.sharedInstance()
        // playAndRecord so spoken translations (TTS) can play mid-session.
        // Default mode, NOT .measurement: measurement disables the system's
        // automatic gain control and mic processing, which made far-away
        // speakers too quiet to transcribe at all.
        try session.setCategory(
            .playAndRecord, mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

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

            self.levelContinuation?.yield(Levels(rms: Self.rms(of: buffer)))

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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += data[i] * data[i]
        }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 4)
    }
}
