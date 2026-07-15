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
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
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
            alreadyDecoded: alreadyDecoded,
            onSegmentComplete: onSegmentComplete,
            onProgress: onProgress)
        logger.info("import: SenseVoice produced \(utterances.count) utterances from a \(poolSize)-decoder pool")
        return utterances
    }
}
/// Offline Dolphin-small CTC transcription — the fast tier. Same pooled
/// VAD-segmented flow as SenseVoice (CTC segments are independent, so
/// they fan out across a decode pool); language auto-detected within
/// Dolphin's Eastern-language set. ponytail: hosted here rather than its
/// own file so the xcodegen-generated pbxproj needn't change; split it
/// out on the next project regen.
actor DolphinFileTranscriber {
    typealias Utterance = VADSegmentedTranscriber.Utterance

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "dolphin")

    /// Transcribe a whole file already decoded to 16 kHz mono float.
    /// `onProgress` reports 0…1 by samples consumed.
    func transcribe(
        samples16k samples: [Float],
        sensitivity: MicSensitivity = .balanced,
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async throws -> [Utterance] {
        guard DolphinModelStore.isInstalled else {
            throw DolphinError.modelMissing
        }
        // ~250MB int8 weights + ONNX arenas per instance; the pool shrinks
        // to 1 when memory is tight, mirroring the SenseVoice sizing.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let poolSize = VADSegmentedTranscriber.decoderPoolSize(
            freeBytes: UInt64(max(0, os_proc_available_memory())),
            perInstanceBytes: 500_000_000,
            coreCount: cores,
            hardCap: VADSegmentedTranscriber.maxDecoderPool)
        let threads = max(2, cores / poolSize)
        let decoders: [@Sendable ([Float]) async -> String] = (0..<poolSize).map { _ in
            let decoder = DolphinDecoder(numThreads: threads)
            return { await decoder.decode($0) }
        }
        let utterances = try await VADSegmentedTranscriber.transcribe(
            samples16k: samples,
            vadModelPath: DolphinModelStore.fileURL("silero_vad.onnx").path,
            sensitivity: sensitivity,
            maxSpeechDuration: 12,
            decoders: decoders,
            alreadyDecoded: alreadyDecoded,
            onSegmentComplete: onSegmentComplete,
            onProgress: onProgress)
        logger.info("import: Dolphin produced \(utterances.count) utterances from a \(poolSize)-decoder pool")
        return utterances
    }
}

/// Owns one sherpa-onnx Dolphin recognizer, mirroring SenseVoiceDecoder.
/// Lazy init: weights load on first decode and release with the actor.
actor DolphinDecoder {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let numThreads: Int

    init(numThreads: Int = 2) {
        self.numThreads = numThreads
    }

    func decode(_ samples: [Float]) -> String {
        if recognizer == nil {
            var config = sherpaOnnxOfflineRecognizerConfig(
                featConfig: sherpaOnnxFeatureConfig(),
                modelConfig: sherpaOnnxOfflineModelConfig(
                    tokens: DolphinModelStore.fileURL("tokens.txt").path,
                    numThreads: numThreads,
                    dolphin: sherpaOnnxOfflineDolphinModelConfig(
                        model: DolphinModelStore.fileURL("model.int8.onnx").path)))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        }
        guard let recognizer else { return "" }
        // Same intra-CJK space normalization the SenseVoice path applies.
        return SenseVoiceDecoder.collapsedCJKTokenSpaces(
            recognizer.decode(samples: samples).text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#else
actor SenseVoiceFileTranscriber {
    typealias Utterance = VADSegmentedTranscriber.Utterance

    init(language: AppLanguage) {}

    func transcribe(
        samples16k samples: [Float],
        sensitivity: MicSensitivity = .balanced,
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async throws -> [Utterance] {
        throw SenseVoiceError.unavailableOnMac
    }
}

actor DolphinFileTranscriber {
    typealias Utterance = VADSegmentedTranscriber.Utterance

    func transcribe(
        samples16k samples: [Float],
        sensitivity: MicSensitivity = .balanced,
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async throws -> [Utterance] {
        throw DolphinError.unavailableOnMac
    }
}
#endif

enum DolphinError: LocalizedError {
    case modelMissing
    case unavailableOnMac

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            String(localized: "Download the Dolphin model in Settings first.")
        case .unavailableOnMac:
            String(localized: "Dolphin is unavailable in the native Mac app until the sherpa-onnx macOS library is bundled.")
        }
    }
}
