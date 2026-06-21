import Foundation
import os

#if os(iOS)
/// Offline SenseVoice transcription for imported files. The live engine
/// pseudo-streams for volatile captions; an import just needs clean finals
/// with time ranges, so this drives the shared VAD segmentation over the
/// whole file and decodes each closed segment (VADSegmentedTranscriber —
/// the same flow the Qwen3-ASR post-pass uses).
actor SenseVoiceFileTranscriber {
    typealias Utterance = VADSegmentedTranscriber.Utterance

    private let language: AppLanguage
    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "import")

    init(language: AppLanguage) {
        self.language = language
    }

    /// Transcribe a whole file already decoded to 16 kHz mono float.
    /// `onProgress` reports 0…1 by samples consumed.
    func transcribe(
        samples16k samples: [Float],
        sensitivity: MicSensitivity = .balanced,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async throws -> [Utterance] {
        guard SenseVoiceModelStore.isInstalled else {
            throw SenseVoiceError.modelMissing
        }
        // Size a decode pool to the device: non-autoregressive SenseVoice
        // segments are independent, so several decode in parallel and a long
        // file finishes in a fraction of the serial time. Each recognizer's
        // ONNX arenas cost memory, so the pool shrinks to 1 when memory is
        // tight; the remaining cores fan out as per-decoder threads.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let poolSize = VADSegmentedTranscriber.decoderPoolSize(
            freeBytes: UInt64(max(0, os_proc_available_memory())),
            perInstanceBytes: 900_000_000,
            coreCount: cores,
            hardCap: VADSegmentedTranscriber.maxDecoderPool)
        let threads = max(2, cores / poolSize)
        let language = self.language
        let decoders: [@Sendable ([Float]) async -> String] = (0..<poolSize).map { _ in
            let decoder = SenseVoiceDecoder(
                sourceSelection: .language(language), numThreads: threads)
            return { await decoder.decode($0).text }
        }
        let utterances = try await VADSegmentedTranscriber.transcribe(
            samples16k: samples,
            vadModelPath: SenseVoiceModelStore.fileURL("silero_vad.onnx").path,
            sensitivity: sensitivity,
            // Force a split mid-monologue so long speech still yields
            // periodic finals (matches the live engine's cap).
            maxSpeechDuration: 12,
            decoders: decoders,
            onProgress: onProgress)
        logger.info("import: SenseVoice produced \(utterances.count) utterances from a \(poolSize)-decoder pool")
        return utterances
    }
}
#else
actor SenseVoiceFileTranscriber {
    typealias Utterance = VADSegmentedTranscriber.Utterance

    init(language: AppLanguage) {}

    func transcribe(
        samples16k samples: [Float],
        sensitivity: MicSensitivity = .balanced,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async throws -> [Utterance] {
        throw SenseVoiceError.unavailableOnMac
    }
}
#endif
