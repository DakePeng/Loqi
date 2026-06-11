import Foundation
import os

/// Offline SenseVoice transcription for imported files. The live engine
/// pseudo-streams for volatile captions; an import just needs clean finals
/// with time ranges, so this drives the same silero VAD over the whole file
/// and decodes each closed segment. The VAD reports every segment's global
/// sample offset, so the time ranges line up with the original-file timeline
/// that diarization reads.
actor SenseVoiceFileTranscriber {
    struct Utterance: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private let language: AppLanguage
    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "import")

    private static let sampleRate = 16_000
    /// Feed window — small enough for smooth progress, big enough to be cheap.
    private static let feedWindow = 16_000   // 1s

    init(language: AppLanguage) {
        self.language = language
    }

    /// Segment sample bounds → seconds. Pure for testing.
    static func timeRange(
        start: Int, n: Int, sampleRate: Int
    ) -> (start: TimeInterval, end: TimeInterval) {
        let rate = Double(max(sampleRate, 1))
        return (Double(start) / rate, Double(start + n) / rate)
    }

    /// Transcribe a whole file already decoded to 16 kHz mono float.
    /// `onProgress` reports 0…1 by samples consumed.
    func transcribe(
        samples16k samples: [Float],
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async throws -> [Utterance] {
        guard SenseVoiceModelStore.isInstalled else {
            throw SenseVoiceError.modelMissing
        }

        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: SenseVoiceModelStore.fileURL("silero_vad.onnx").path,
                threshold: 0.5,
                minSilenceDuration: 0.5,
                minSpeechDuration: 0.25,
                windowSize: 512,
                maxSpeechDuration: 12),
            sampleRate: Int32(Self.sampleRate),
            numThreads: 1)
        let vad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig, buffer_size_in_seconds: 60)
        let decoder = SenseVoiceDecoder(language: language)

        var utterances: [Utterance] = []
        let total = max(samples.count, 1)

        var offset = 0
        while offset < samples.count {
            let upper = min(offset + Self.feedWindow, samples.count)
            vad.acceptWaveform(samples: Array(samples[offset..<upper]))
            offset = upper
            while !vad.isEmpty() {
                let segment = vad.front()
                let (start, end) = Self.timeRange(
                    start: segment.start, n: segment.n, sampleRate: Self.sampleRate)
                let text = await decoder.decode(segment.samples)
                vad.pop()
                if !text.isEmpty {
                    utterances.append(Utterance(text: text, start: start, end: end))
                }
            }
            await onProgress(Double(offset) / Double(total))
        }
        // Close any segment still open at EOF so the last words aren't lost.
        vad.flush()
        while !vad.isEmpty() {
            let segment = vad.front()
            let (start, end) = Self.timeRange(
                start: segment.start, n: segment.n, sampleRate: Self.sampleRate)
            let text = await decoder.decode(segment.samples)
            vad.pop()
            if !text.isEmpty {
                utterances.append(Utterance(text: text, start: start, end: end))
            }
        }
        await onProgress(1)

        logger.info("import: SenseVoice produced \(utterances.count) utterances")
        return utterances
    }
}
