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

    /// Raw values are persisted in `SessionRecord.RetranscribeCheckpoint`
    /// — keep them stable.
    enum Backend: String, Equatable {
        case apple
        case senseVoice = "sensevoice"
        case qwen3ASR = "qwen3asr"
        case dolphin
    }

    /// Dolphin covers Eastern languages only — 中文/日本語/한국어 among the
    /// app's four; an English session must never route to it.
    nonisolated static func dolphinSupports(_ source: AppLanguage) -> Bool {
        source != .english
    }

    /// Which backend Re-transcribe & summarize should use. Installing a
    /// post-process model IS the opt-in. Dolphin (the fast tier) outranks
    /// Qwen3-ASR while installed and the language fits — trying it is the
    /// point; delete it in Settings to return to the accuracy pass.
    /// Otherwise the live-engine choice applies (SenseVoice when chosen
    /// AND installed), falling back to Apple. Pure for testing.
    nonisolated static func effectiveBackend(
        engineChoice: String, source: AppLanguage,
        senseVoiceInstalled: Bool, qwen3Installed: Bool, dolphinInstalled: Bool
    ) -> Backend {
        #if os(macOS)
        return .apple
        #else
        if dolphinInstalled, dolphinSupports(source) { return .dolphin }
        if qwen3Installed { return .qwen3ASR }
        // Hybrid's record layer IS SenseVoice — same re-transcribe backend.
        if engineChoice == "sensevoice" || engineChoice == "hybrid",
           senseVoiceInstalled { return .senseVoice }
        return .apple
        #endif
    }

    /// Which backend an import should use. Imports never auto-upgrade:
    /// Qwen3-ASR decodes near realtime, so a long file would turn the
    /// import sheet into an hour-long wait — it runs only when the user
    /// picks it in the import options. Unavailable picks fall back to
    /// Apple. Pure for testing.
    nonisolated static func importBackend(
        choice: String, source: AppLanguage,
        senseVoiceInstalled: Bool, qwen3Installed: Bool, dolphinInstalled: Bool
    ) -> Backend {
        #if os(macOS)
        return .apple
        #else
        switch choice {
        case "qwen3" where qwen3Installed: .qwen3ASR
        case "dolphin" where dolphinInstalled && dolphinSupports(source): .dolphin
        case "sensevoice" where senseVoiceInstalled: .senseVoice
        default: .apple
        }
        #endif
    }

    /// Auto post-process for new recordings: use downloaded high-accuracy
    /// engines only. nil means keep the live transcript and summarize.
    /// Same priority as `effectiveBackend`: fast Dolphin tier first when
    /// installed and the language fits.
    nonisolated static func postProcessBackend(
        source: AppLanguage,
        senseVoiceInstalled: Bool, qwen3Installed: Bool, dolphinInstalled: Bool
    ) -> Backend? {
        #if os(macOS)
        return nil
        #else
        if dolphinInstalled, dolphinSupports(source) { return .dolphin }
        if qwen3Installed { return .qwen3ASR }
        if senseVoiceInstalled { return .senseVoice }
        return nil
        #endif
    }

    /// The Re-transcribe backend for the current device + settings state.
    static func currentBackend(source: AppLanguage) -> Backend {
        effectiveBackend(
            engineChoice: UserDefaults.standard.string(forKey: "asr.engine") ?? "apple",
            source: source,
            senseVoiceInstalled: SenseVoiceModelStore.isInstalled,
            qwen3Installed: Qwen3ASRModelStore.isInstalled,
            dolphinInstalled: DolphinModelStore.isInstalled)
    }

    /// `onProgress` reports 0...1 through the file. `hotwords` reach only
    /// the Qwen3-ASR decoder (the other backends have no biasing).
    /// `alreadyDecoded`/`onSegmentComplete` let a resumed import skip and
    /// checkpoint VAD segments; the Apple backend has no segment
    /// boundaries, so both are no-ops there.
    static func transcribe(
        _ audioFile: AVAudioFile,
        language: AppLanguage,
        backend: Backend,
        sensitivity: MicSensitivity = .balanced,
        hotwords: [String] = [],
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        switch backend {
        case .qwen3ASR:
            return try await transcribeWithQwen3ASR(
                audioFile, sensitivity: sensitivity, hotwords: hotwords,
                alreadyDecoded: alreadyDecoded, onSegmentComplete: onSegmentComplete,
                onProgress: onProgress)
        case .dolphin:
            return try await transcribeWithDolphin(
                audioFile, sensitivity: sensitivity,
                alreadyDecoded: alreadyDecoded, onSegmentComplete: onSegmentComplete,
                onProgress: onProgress)
        case .senseVoice:
            return try await transcribeWithSenseVoice(
                audioFile, language: language, sensitivity: sensitivity,
                alreadyDecoded: alreadyDecoded, onSegmentComplete: onSegmentComplete,
                onProgress: onProgress)
        case .apple:
            let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            return try await transcribeWithApple(
                audioFile, source: language, duration: duration, onProgress: onProgress)
        }
    }

    /// Dolphin fast tier: CTC (non-autoregressive), pooled like SenseVoice,
    /// language auto-detected across its Eastern-language set. No hotword
    /// biasing (CTC can't) — the text-level fixup downstream still applies.
    private static func transcribeWithDolphin(
        _ audioFile: AVAudioFile,
        sensitivity: MicSensitivity,
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        let samples = try await decodeMono16k(audioFile)
        let transcriber = DolphinFileTranscriber()
        let utterances = try await transcriber.transcribe(
            samples16k: samples, sensitivity: sensitivity,
            alreadyDecoded: alreadyDecoded, onSegmentComplete: onSegmentComplete
        ) { fraction in
            onProgress(fraction)
        }
        return utterances.map { ($0.text, $0.start, $0.end) }
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
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        let samples = try await decodeMono16k(audioFile)
        let transcriber = Qwen3ASRFileTranscriber(hotwords: hotwords)
        let utterances = try await transcriber.transcribe(
            samples16k: samples, sensitivity: sensitivity,
            alreadyDecoded: alreadyDecoded, onSegmentComplete: onSegmentComplete
        ) { fraction in
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
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        let samples = try await decodeMono16k(audioFile)
        let transcriber = SenseVoiceFileTranscriber(language: language)
        let utterances = try await transcriber.transcribe(
            samples16k: samples, sensitivity: sensitivity,
            alreadyDecoded: alreadyDecoded, onSegmentComplete: onSegmentComplete
        ) { fraction in
            onProgress(fraction)
        }
        return utterances.map { ($0.text, $0.start, $0.end) }
    }

    /// Decode an audio file to a flat 16 kHz mono float buffer — shared by
    /// the sherpa backends here and VoiceprintService's diarizer.
    static func decodeMono16k(_ file: AVAudioFile) async throws -> [Float] {
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
