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
    private let logger = Logger(subsystem: "com.kunzhipeng.locally", category: "import")

    init(translator: TranslationCoordinator, voiceprint: VoiceprintService) {
        self.translator = translator
        self.voiceprint = voiceprint
    }

    func importAudio(
        url: URL,
        direction: LanguagePair,
        speakerCount: Int,
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

        let audioFile = try AVAudioFile(forReading: localURL)
        let sampleRate = audioFile.fileFormat.sampleRate
        let duration = Double(audioFile.length) / sampleRate
        let recordedAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? Date.now.addingTimeInterval(-duration)

        // MARK: Transcribe (finals only; Result carries the time range)
        onPhase(.transcribing(0))
        let transcriber = SpeechTranscriber(
            locale: direction.source.speechLocale,
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
            let reader = try AVAudioFile(forReading: localURL)
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
}

enum ImportError: LocalizedError {
    case nothingTranscribed

    var errorDescription: String? {
        String(localized: "No speech was recognized in this recording.")
    }
}
