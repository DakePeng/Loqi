import AVFoundation
import Foundation
import Speech

/// Shared offline transcription backends — file-based Apple SpeechAnalyzer,
/// SenseVoice, or the Qwen3-ASR post-processing model — returning finals
/// with time ranges. Extracted from FileImportEngine so session
/// re-transcription runs the exact pipeline that imports do.
@MainActor
enum OfflineTranscriber {
    typealias Utterance = (text: String, start: TimeInterval, end: TimeInterval)

    enum Backend: Equatable {
        case apple
        case senseVoice
        case qwen3ASR
    }

    /// Which backend Re-transcribe & summarize should use. Qwen3-ASR wins
    /// whenever installed — that's the deliberate accuracy pass, and
    /// installing the model IS the opt-in. Otherwise the live-engine
    /// choice applies (SenseVoice when chosen AND installed), falling
    /// back to Apple. Pure for testing.
    nonisolated static func effectiveBackend(
        engineChoice: String, senseVoiceInstalled: Bool, qwen3Installed: Bool
    ) -> Backend {
        #if os(macOS)
        return .apple
        #else
        if qwen3Installed { return .qwen3ASR }
        if engineChoice == "sensevoice", senseVoiceInstalled { return .senseVoice }
        return .apple
        #endif
    }

    /// Which backend an import should use. Imports never auto-upgrade:
    /// Qwen3-ASR decodes near realtime, so a long file would turn the
    /// import sheet into an hour-long wait — it runs only when the user
    /// picks it in the import options. Unavailable picks fall back to
    /// Apple. Pure for testing.
    nonisolated static func importBackend(
        choice: String, senseVoiceInstalled: Bool, qwen3Installed: Bool
    ) -> Backend {
        #if os(macOS)
        return .apple
        #else
        switch choice {
        case "qwen3" where qwen3Installed: .qwen3ASR
        case "sensevoice" where senseVoiceInstalled: .senseVoice
        default: .apple
        }
        #endif
    }

    /// Auto post-process for new recordings: use downloaded high-accuracy
    /// engines only. nil means keep the live transcript and summarize.
    nonisolated static func postProcessBackend(
        senseVoiceInstalled: Bool, qwen3Installed: Bool
    ) -> Backend? {
        #if os(macOS)
        return nil
        #else
        if qwen3Installed { return .qwen3ASR }
        if senseVoiceInstalled { return .senseVoice }
        return nil
        #endif
    }

    /// The Re-transcribe backend for the current device + settings state.
    static func currentBackend() -> Backend {
        effectiveBackend(
            engineChoice: UserDefaults.standard.string(forKey: "asr.engine") ?? "apple",
            senseVoiceInstalled: SenseVoiceModelStore.isInstalled,
            qwen3Installed: Qwen3ASRModelStore.isInstalled)
    }

    /// `onProgress` reports 0...1 through the file. `hotwords` reach only
    /// the Qwen3-ASR decoder (the other backends have no biasing).
    static func transcribe(
        _ audioFile: AVAudioFile,
        language: AppLanguage,
        backend: Backend,
        sensitivity: MicSensitivity = .balanced,
        hotwords: [String] = [],
        onProgress: @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        switch backend {
        case .qwen3ASR:
            return try await transcribeWithQwen3ASR(
                audioFile, sensitivity: sensitivity, hotwords: hotwords,
                onProgress: onProgress)
        case .senseVoice:
            return try await transcribeWithSenseVoice(
                audioFile, language: language, sensitivity: sensitivity,
                onProgress: onProgress)
        case .apple:
            let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            return try await transcribeWithApple(
                audioFile, source: language, duration: duration, onProgress: onProgress)
        }
    }

    /// Apple SpeechAnalyzer: file-based, finals only, each Result carrying a
    /// time range. Unchanged from the original single-engine import.
    private static func transcribeWithApple(
        _ audioFile: AVAudioFile,
        source: AppLanguage,
        duration: TimeInterval,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        let transcriber = SpeechTranscriber(
            locale: source.speechLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        var utterances: [Utterance] = []
        let collector = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                utterances.append((text, start, end))
                onProgress(duration > 0 ? min(end / duration, 1) : 0)
            }
        }
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        try await collector.value
        return utterances
    }

    /// Qwen3-ASR post-pass: highest accuracy, language auto-detected,
    /// hotword-primed. Same decode-to-16k + VAD flow as SenseVoice.
    private static func transcribeWithQwen3ASR(
        _ audioFile: AVAudioFile,
        sensitivity: MicSensitivity,
        hotwords: [String],
        onProgress: @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        let samples = try await decodeMono16k(audioFile)
        let transcriber = Qwen3ASRFileTranscriber(hotwords: hotwords)
        let utterances = try await transcriber.transcribe(
            samples16k: samples, sensitivity: sensitivity) { fraction in
            onProgress(fraction)
        }
        return utterances.map { ($0.text, $0.start, $0.end) }
    }

    /// SenseVoice offline: decode the file to 16 kHz mono, then run the VAD +
    /// recognizer over it. Higher zh/ja/ko accuracy than the system engine.
    private static func transcribeWithSenseVoice(
        _ audioFile: AVAudioFile,
        language: AppLanguage,
        sensitivity: MicSensitivity,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        let samples = try await decodeMono16k(audioFile)
        let transcriber = SenseVoiceFileTranscriber(language: language)
        let utterances = try await transcriber.transcribe(
            samples16k: samples, sensitivity: sensitivity) { fraction in
            onProgress(fraction)
        }
        return utterances.map { ($0.text, $0.start, $0.end) }
    }

    /// Decode an audio file to a flat 16 kHz mono float buffer for SenseVoice.
    private static func decodeMono16k(_ file: AVAudioFile) async throws -> [Float] {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw ImportError.audioExtractionFailed }

        var output: [Float] = []
        let readSize: AVAudioFrameCount = 16_000 * 10   // 10s of source frames
        var finished = false

        while !finished {
            try Task.checkCancellation()
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: target, frameCapacity: readSize) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inStatus in
                guard let inBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: readSize) else {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer)
                } catch {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                inStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError { throw conversionError }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(
                    start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error || outBuffer.frameLength == 0 {
                finished = true
            }
        }
        try Task.checkCancellation()
        return output
    }
}
