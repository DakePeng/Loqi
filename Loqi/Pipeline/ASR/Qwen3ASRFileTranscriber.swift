import Foundation
import os

#if os(iOS)
/// Offline Qwen3-ASR-0.6B transcription — the high-accuracy pass behind
/// "Re-transcribe & summarize" and imports. Same VAD segmentation as the
/// SenseVoice path; each segment gets one autoregressive Speech-LLM
/// decode (slower, noticeably more accurate, language auto-detected).
/// Hotwords prime the decoder itself — the vocabulary the user taught the
/// app reaches recognition here, not just the downstream fixup.
actor Qwen3ASRFileTranscriber {
    /// Keep priming behind one flag so a bad field run can disable it quickly.
    nonisolated static let hotwordPrimingEnabled = true

    private let hotwords: [String]
    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "qwen3asr")

    init(hotwords: [String] = []) {
        self.hotwords = Self.hotwordPrimingEnabled ? hotwords : []
    }

    /// Transcribe a whole file already decoded to 16 kHz mono float.
    /// `onProgress` reports 0…1 by samples consumed.
    func transcribe(
        samples16k samples: [Float],
        sensitivity: MicSensitivity = .balanced,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async throws -> [VADSegmentedTranscriber.Utterance] {
        guard Qwen3ASRModelStore.isInstalled else {
            throw Qwen3ASRError.modelMissing
        }
        let decoder = Qwen3ASRDecoder(hotwords: hotwords)
        let utterances = try await VADSegmentedTranscriber.transcribe(
            samples16k: samples,
            vadModelPath: Qwen3ASRModelStore.fileURL("silero_vad.onnx").path,
            sensitivity: sensitivity,
            // Shorter cap than SenseVoice's 12s: a segment's audio tokens
            // plus the transcription must fit the decoder's 512-token
            // budget (official default).
            maxSpeechDuration: 10,
            // Single-element pool: Qwen3-ASR is autoregressive and ~940 MB,
            // so a second instance is memory-prohibitive — this stays serial.
            decoders: [{ await decoder.decode($0) }],
            onProgress: onProgress)
        logger.info("post-pass: Qwen3-ASR produced \(utterances.count) utterances")
        return utterances
    }
}

/// Owns the sherpa-onnx Qwen3-ASR recognizer on its own actor, mirroring
/// SenseVoiceDecoder. Lazy init: the ~940MB of weights load on the first
/// decode and release with the actor.
actor Qwen3ASRDecoder {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let hotwords: String

    init(hotwords: [String] = []) {
        self.hotwords = Self.hotwordString(from: hotwords)
    }

    /// sherpa's Qwen3-ASR `hotwords` field is comma-separated (c-api.h:1018).
    nonisolated static func hotwordString(from words: [String]) -> String {
        words.filter { !$0.isEmpty }.joined(separator: ",")
    }

    func decode(_ samples: [Float]) -> String {
        if recognizer == nil {
            // Config mirrors the official swift-api example: tokens is
            // empty (the model brings its own tokenizer, passed as the
            // DIRECTORY holding vocab.json/merges.txt/tokenizer_config.json).
            var config = sherpaOnnxOfflineRecognizerConfig(
                featConfig: sherpaOnnxFeatureConfig(),
                modelConfig: sherpaOnnxOfflineModelConfig(
                    tokens: "",
                    // 4 (vs the example's 2): the autoregressive decode is
                    // the whole wait, and this batch pass owns the device —
                    // nothing else competes for cores while the sheet is up.
                    numThreads: 4,
                    qwen3Asr: sherpaOnnxOfflineQwen3ASRModelConfig(
                        convFrontend: Qwen3ASRModelStore.fileURL("conv_frontend.onnx").path,
                        encoder: Qwen3ASRModelStore.fileURL("encoder.int8.onnx").path,
                        decoder: Qwen3ASRModelStore.fileURL("decoder.int8.onnx").path,
                        tokenizer: Qwen3ASRModelStore.tokenizerDirectory.path,
                        hotwords: hotwords)))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        }
        guard let recognizer else { return "" }
        return recognizer.decode(samples: samples)
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Qwen3ASRError: LocalizedError {
    case modelMissing

    var errorDescription: String? {
        String(localized: "Download the Qwen3-ASR model in Settings first.")
    }
}
#else
actor Qwen3ASRFileTranscriber {
    nonisolated static let hotwordPrimingEnabled = false

    init(hotwords: [String] = []) {}

    func transcribe(
        samples16k samples: [Float],
        sensitivity: MicSensitivity = .balanced,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async throws -> [VADSegmentedTranscriber.Utterance] {
        throw Qwen3ASRError.unavailableOnMac
    }
}

actor Qwen3ASRDecoder {
    init(hotwords: [String] = []) {}
    func decode(_ samples: [Float]) -> String { "" }
}

enum Qwen3ASRError: LocalizedError {
    case modelMissing
    case unavailableOnMac

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            String(localized: "Download the Qwen3-ASR model in Settings first.")
        case .unavailableOnMac:
            String(localized: "Qwen3-ASR is unavailable in the native Mac app until the sherpa-onnx macOS library is bundled.")
        }
    }
}
#endif
