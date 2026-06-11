import AVFoundation
import Foundation
import Speech
import os

/// Imports a pre-recorded audio file (Voice Memos via share sheet, or any
/// audio from Files) through the offline pipeline: file-based SpeechAnalyzer
/// transcription (faster than real time), optional speaker diarization, and
/// tier-1 translation — producing a normal SessionRecord that summaries,
/// outlines, and export all work on.
@MainActor
final class FileImportEngine {
    enum Phase: Equatable {
        case transcribing(Double)   // 0...1 through the file
        case identifyingSpeakers(Double)
        case translating(Double)
    }

    private let translator: TranslationCoordinator
    private let voiceprint: VoiceprintService
    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "import")

    init(translator: TranslationCoordinator, voiceprint: VoiceprintService) {
        self.translator = translator
        self.voiceprint = voiceprint
    }

    /// Whether to actually use SenseVoice: requested AND installed, else
    /// fall back to Apple (mirrors the live pipeline). Pure for testing.
    nonisolated static func effectiveUseSenseVoice(choice: String, installed: Bool) -> Bool {
        choice == "sensevoice" && installed
    }

    func importAudio(
        url: URL,
        direction: LanguagePair,
        speakerCount: Int,
        engine: String = "apple",
        onPhase: @escaping (Phase) -> Void
    ) async throws -> SessionRecord {
        // Files-picker URLs are security-scoped; copy into our container so
        // long processing never races the scope.
        let scoped = url.startAccessingSecurityScopedResource()
        let localURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: localURL)
        if scoped { url.stopAccessingSecurityScopedResource() }
        defer { try? FileManager.default.removeItem(at: localURL) }

        // Video files: pull the audio track into a temp .m4a so the rest of
        // the pipeline (AVAudioFile, diarization) works uniformly.
        let workingURL = try await resolveAudioURL(localURL)
        defer {
            if workingURL != localURL { try? FileManager.default.removeItem(at: workingURL) }
        }

        let audioFile = try AVAudioFile(forReading: workingURL)
        let sampleRate = audioFile.fileFormat.sampleRate
        let duration = Double(audioFile.length) / sampleRate
        let recordedAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? Date.now.addingTimeInterval(-duration)

        // MARK: Transcribe (finals only, each carrying a time range)
        onPhase(.transcribing(0))
        let useSenseVoice = Self.effectiveUseSenseVoice(
            choice: engine, installed: SenseVoiceModelStore.isInstalled)
        let utterances = useSenseVoice
            ? try await transcribeWithSenseVoice(
                audioFile, language: direction.source, onPhase: onPhase)
            : try await transcribeWithApple(
                audioFile, source: direction.source, duration: duration, onPhase: onPhase)
        logger.info("import: \(utterances.count) utterances from \(Int(duration))s file")

        var entries = utterances.map { utterance in
            SessionRecord.Entry(
                sourceText: utterance.text,
                translation: nil,
                speaker: nil,
                direction: direction,
                timestamp: recordedAt.addingTimeInterval(utterance.start))
        }

        // MARK: Diarization (optional; model must already be downloaded)
        if speakerCount >= 2, await voiceprint.state == .ready {
            await voiceprint.startDiarization(maxSpeakers: speakerCount)
            let reader = try AVAudioFile(forReading: workingURL)
            var slotByEntry: [UUID: Int] = [:]
            for (index, utterance) in utterances.enumerated() {
                onPhase(.identifyingSpeakers(
                    Double(index) / Double(max(utterances.count, 1))))
                await voiceprint.beginUtterance()
                await feedSegment(
                    of: reader,
                    from: utterance.start, to: utterance.end,
                    sampleRate: sampleRate)
                await voiceprint.endUtterance()
                if let result = await voiceprint.assignSpeaker(entryID: entries[index].id) {
                    slotByEntry[entries[index].id] = result.slot
                    for (entryID, slot) in result.relabels {
                        slotByEntry[entryID] = slot
                    }
                }
            }
            await voiceprint.stopDiarization()
            for index in entries.indices {
                entries[index].speaker = slotByEntry[entries[index].id]
            }
        }

        // MARK: Tier-1 translation (same-language import = transcribe-only)
        if direction.source != direction.target {
            await translator.addDirection(direction)
            for index in entries.indices {
                onPhase(.translating(Double(index) / Double(max(entries.count, 1))))
                entries[index].translation = try? await translator.draft(
                    entries[index].sourceText, direction: direction)
            }
        }

        guard entries.count >= 1 else { throw ImportError.nothingTranscribed }
        return SessionRecord(
            mode: .captions,
            startedAt: recordedAt,
            endedAt: recordedAt.addingTimeInterval(duration),
            entries: entries)
    }

    /// Stream one utterance's samples into the voiceprint service in ≤1s
    /// buffers (its rolling window keeps the last 3s; resampling happens
    /// inside ingest).
    private func feedSegment(
        of file: AVAudioFile,
        from start: TimeInterval, to end: TimeInterval,
        sampleRate: Double
    ) async {
        let startFrame = AVAudioFramePosition(max(0, start) * sampleRate)
        let endFrame = min(AVAudioFramePosition(end * sampleRate), file.length)
        guard endFrame > startFrame else { return }
        file.framePosition = startFrame
        var remaining = AVAudioFrameCount(endFrame - startFrame)
        let chunkFrames = AVAudioFrameCount(sampleRate)  // 1s
        while remaining > 0 {
            let count = min(remaining, chunkFrames)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: count
            ), (try? file.read(into: buffer, frameCount: count)) != nil,
                  buffer.frameLength > 0 else { break }
            let chunk = AudioCaptureService.AudioChunk(buffer: buffer)
            await voiceprint.ingest(chunk)
            remaining -= buffer.frameLength
        }
    }

    // MARK: Audio extraction (video → audio)

    /// If `url` is a movie, export its audio track to a temp .m4a and return
    /// that; if it's already audio, return it unchanged. Throws when there's
    /// no audio track to work with.
    private func resolveAudioURL(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw ImportError.noAudioTrack }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { return url }  // already audio-only

        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { throw ImportError.audioExtractionFailed }
        let output = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("m4a")
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? ImportError.audioExtractionFailed
        }
        logger.info("import: extracted audio track from video")
        return output
    }

    // MARK: Transcription backends

    /// Apple SpeechAnalyzer: file-based, finals only, each Result carrying a
    /// time range. Unchanged from the original single-engine import.
    private func transcribeWithApple(
        _ audioFile: AVAudioFile,
        source: AppLanguage,
        duration: TimeInterval,
        onPhase: @escaping (Phase) -> Void
    ) async throws -> [(text: String, start: TimeInterval, end: TimeInterval)] {
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

        var utterances: [(text: String, start: TimeInterval, end: TimeInterval)] = []
        let collector = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                utterances.append((text, start, end))
                onPhase(.transcribing(duration > 0 ? min(end / duration, 1) : 0))
            }
        }
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        try await collector.value
        return utterances
    }

    /// SenseVoice offline: decode the file to 16 kHz mono, then run the VAD +
    /// recognizer over it. Higher zh/ja/ko accuracy than the system engine.
    private func transcribeWithSenseVoice(
        _ audioFile: AVAudioFile,
        language: AppLanguage,
        onPhase: @escaping (Phase) -> Void
    ) async throws -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        let samples = try decodeMono16k(audioFile)
        let transcriber = SenseVoiceFileTranscriber(language: language)
        let utterances = try await transcriber.transcribe(samples16k: samples) { fraction in
            onPhase(.transcribing(fraction))
        }
        return utterances.map { ($0.text, $0.start, $0.end) }
    }

    /// Decode an audio file to a flat 16 kHz mono float buffer for SenseVoice.
    private func decodeMono16k(_ file: AVAudioFile) throws -> [Float] {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw ImportError.audioExtractionFailed }

        var output: [Float] = []
        let readSize: AVAudioFrameCount = 16_000 * 10   // 10s of source frames
        var finished = false

        while !finished {
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
        return output
    }
}

enum ImportError: LocalizedError {
    case nothingTranscribed
    case noAudioTrack
    case audioExtractionFailed

    var errorDescription: String? {
        switch self {
        case .nothingTranscribed:
            String(localized: "No speech was recognized in this recording.")
        case .noAudioTrack:
            String(localized: "This file has no audio track to transcribe.")
        case .audioExtractionFailed:
            String(localized: "Couldn't read the audio from this file.")
        }
    }
}
