import AVFoundation
import Foundation
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
        case fetchingSpeakerModel(Double)   // first diarized import only
        case identifyingSpeakers(Double)
        case translating(Double)
    }

    private let translator: TranslationCoordinator
    private let voiceprint: VoiceprintService
    /// Unloaded before a Qwen3-ASR decode: its ~940MB of weights and the
    /// resident LLM can't coexist on 6GB devices. Imports never use the
    /// LLM (drafts come from the system translator), so it reloads lazily
    /// at the next AI feature.
    private let llm: LLMService?
    /// Vocabulary that primes the Qwen3-ASR decoder.
    private let hotwords: HotwordStore?
    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "import")

    init(
        translator: TranslationCoordinator,
        voiceprint: VoiceprintService,
        llm: LLMService? = nil,
        hotwords: HotwordStore? = nil
    ) {
        self.translator = translator
        self.voiceprint = voiceprint
        self.llm = llm
        self.hotwords = hotwords
    }

    func importAudio(
        url: URL,
        sessionID: UUID = UUID(),
        direction: LanguagePair,
        speakerCount: Int,
        engine: String = "apple",
        sensitivity: MicSensitivity = .balanced,
        onAudioReady: @MainActor @Sendable (
            _ recordingName: String, _ duration: TimeInterval, _ recordedAt: Date
        ) -> Void = { _, _, _ in },
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> SessionRecord {
        // Files-picker URLs are security-scoped; copy into our container so
        // long processing never races the scope.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let localURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: localURL)
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

        // Persist the imported audio before transcribing, not after: a kill
        // mid-decode still leaves a durable file a resume can read back.
        // Keep the source extension (AVAudioPlayer reads m4a/wav/caf alike).
        let recordingName = "\(sessionID.uuidString)."
            + (workingURL.pathExtension.isEmpty ? "m4a" : workingURL.pathExtension)
        let recordingURL = SessionArchive.recordingURL(fileName: recordingName)
        try FileManager.default.createDirectory(
            at: SessionArchive.recordingsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: workingURL, to: recordingURL)
        onAudioReady(recordingName, duration, recordedAt)

        // MARK: Transcribe (finals only, each carrying a time range)
        onPhase(.transcribing(0))
        let backend = OfflineTranscriber.importBackend(
            choice: engine,
            senseVoiceInstalled: SenseVoiceModelStore.isInstalled,
            qwen3Installed: Qwen3ASRModelStore.isInstalled)
        if backend == .qwen3ASR { await llm?.unload() }
        let rawUtterances = try await OfflineTranscriber.transcribe(
            audioFile,
            language: direction.source,
            backend: backend,
            sensitivity: sensitivity,
            hotwords: hotwords?.biasStrings(for: direction.source) ?? [],
            onSegmentComplete: onSegmentComplete
        ) { fraction in
            onPhase(.transcribing(fraction))
        }
        // Drop punctuation-only finals ("." / "。") before they become entries;
        // filtering here keeps utterances index-aligned with diarization below.
        let utterances = rawUtterances.filter { $0.text.hasSpeechContent }
        logger.info("import: \(utterances.count) utterances from \(Int(duration))s file")

        let entries = utterances.map { utterance in
            SessionRecord.Entry(
                sourceText: utterance.text,
                translation: nil,
                speaker: nil,
                direction: direction,
                timestamp: recordedAt.addingTimeInterval(utterance.start),
                audioOffset: utterance.start)
        }

        return try await finishImport(
            sessionID: sessionID, direction: direction, speakerCount: speakerCount,
            utterances: utterances, entries: entries, recordingName: recordingName,
            recordedAt: recordedAt, duration: duration, onPhase: onPhase)
    }

    /// Resumes an interrupted import from its checkpoint. Reads audio
    /// straight from the durable copy a prior attempt already made — never
    /// touches the original picker URL, which may not even be valid
    /// anymore after a relaunch — and skips VAD segments already decoded.
    func resumeImport(
        checkpoint: SessionRecord.ImportCheckpoint,
        sessionID: UUID,
        audioFileName: String,
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> SessionRecord {
        let audioFile = try AVAudioFile(
            forReading: SessionArchive.recordingURL(fileName: audioFileName))
        let direction = checkpoint.direction
        let sensitivity = MicSensitivity(rawValue: checkpoint.sensitivityRaw) ?? .balanced

        onPhase(.transcribing(0))
        let backend = OfflineTranscriber.importBackend(
            choice: checkpoint.engine,
            senseVoiceInstalled: SenseVoiceModelStore.isInstalled,
            qwen3Installed: Qwen3ASRModelStore.isInstalled)
        if backend == .qwen3ASR { await llm?.unload() }
        let rawUtterances = try await OfflineTranscriber.transcribe(
            audioFile,
            language: direction.source,
            backend: backend,
            sensitivity: sensitivity,
            hotwords: hotwords?.biasStrings(for: direction.source) ?? [],
            alreadyDecoded: checkpoint.segments,
            onSegmentComplete: onSegmentComplete
        ) { fraction in
            onPhase(.transcribing(fraction))
        }
        let utterances = rawUtterances.filter { $0.text.hasSpeechContent }
        logger.info(
            "import: resumed with \(utterances.count) utterances, \(checkpoint.segments.count) cached")

        let entries = utterances.map { utterance in
            SessionRecord.Entry(
                sourceText: utterance.text,
                translation: nil,
                speaker: nil,
                direction: direction,
                timestamp: checkpoint.recordedAt.addingTimeInterval(utterance.start),
                audioOffset: utterance.start)
        }

        return try await finishImport(
            sessionID: sessionID, direction: direction, speakerCount: checkpoint.speakerCount,
            utterances: utterances, entries: entries, recordingName: audioFileName,
            recordedAt: checkpoint.recordedAt, duration: checkpoint.duration, onPhase: onPhase)
    }

    /// Diarization + tier-1 translation, then the final record. Shared by a
    /// fresh import and a resumed one — by the time this runs the durable
    /// audio copy already exists at `recordingName` either way.
    private func finishImport(
        sessionID: UUID,
        direction: LanguagePair,
        speakerCount: Int,
        utterances: [OfflineTranscriber.Utterance],
        entries initialEntries: [SessionRecord.Entry],
        recordingName: String,
        recordedAt: Date,
        duration: TimeInterval,
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> SessionRecord {
        var entries = initialEntries
        let recordingURL = SessionArchive.recordingURL(fileName: recordingName)

        // The two phases are independent — diarization reads the audio and
        // writes speaker slots; translation reads source text and writes the
        // translation field — so when both run, the tier-1 drafts overlap the
        // off-main diarizer (which owns the visible progress, including any
        // first-use model download). With no diarization, translation drives
        // the progress bar itself, exactly as before. Same-language imports
        // are transcribe-only and skip translation entirely.
        try Task.checkCancellation()
        let needsTranslation = direction.source != direction.target
        if needsTranslation { await translator.addDirection(direction) }

        var speakerSeparationFailed = false
        if let speakerCap = VoiceprintService.clusterCap(forPickerValue: speakerCount) {
            // Snapshot the entries (a `let`) so the concurrent draft pass and
            // the diarization speaker-writes below don't contend for `entries`.
            let entriesSnapshot = entries
            async let drafts: [String?] = Self.draftAll(
                entries: entriesSnapshot, direction: direction,
                translator: needsTranslation ? translator : nil)

            onPhase(.identifyingSpeakers(0))
            do {
                let segments = try await voiceprint.diarizeFile(
                    url: recordingURL, maxSpeakers: speakerCap, source: .current
                ) { progress in
                    Task { @MainActor in
                        switch progress {
                        case .download(let fraction):
                            onPhase(.fetchingSpeakerModel(fraction))
                        case .analysis(let fraction):
                            onPhase(.identifyingSpeakers(fraction))
                        }
                    }
                }
                let slots = SpeakerAttribution.attribute(
                    utterances: utterances.map { ($0.start, $0.end) },
                    to: segments)
                for index in entries.indices {
                    entries[index].speaker = slots[index]
                }
                logger.info("import: \(Set(segments.map(\.slot)).count) speakers across \(segments.count) segments")
            } catch is CancellationError {
                // A background/yield preempt mid-diarization must stop the
                // whole import (checkpointed, resumed on foreground) — not
                // be swallowed as "labels failed" and keep Metal-backed
                // work running past the scene exit.
                throw CancellationError()
            } catch {
                // Speaker labels are an enhancement: a failed model download
                // or analysis must not cost the transcript. But surface it —
                // a silently label-less import is exactly "diarization doesn't
                // work for uploads"; the flag drives a retry affordance.
                speakerSeparationFailed = true
                logger.error("import diarization failed: \(error.localizedDescription)")
            }

            // Apply the translations drafted concurrently with diarization.
            let translations = try await drafts
            for index in entries.indices where index < translations.count {
                entries[index].translation = translations[index]
            }
        } else if needsTranslation {
            for index in entries.indices {
                try Task.checkCancellation()
                onPhase(.translating(Double(index) / Double(max(entries.count, 1))))
                entries[index].translation = try? await translator.draft(
                    entries[index].sourceText, direction: direction)
            }
        }

        guard entries.count >= 1 else { throw ImportError.nothingTranscribed }

        // Preassigned ID: the job center's placeholder record keeps its
        // identity when this finished record replaces it.
        var record = SessionRecord(
            id: sessionID,
            mode: .captions,
            startedAt: recordedAt,
            endedAt: recordedAt.addingTimeInterval(duration),
            entries: entries)
        record.recordingSpeakerCount = speakerCount
        record.audioFileName = FileManager.default.fileExists(atPath: recordingURL.path)
            ? recordingName : nil
        record.speakerSeparationFailed = speakerSeparationFailed ? true : nil
        return record
    }

    /// Draft every entry's tier-1 translation, in order. Extracted so it can
    /// run as an `async let` overlapping the off-main diarizer; a nil
    /// translator (same-language import) yields no drafts.
    private static func draftAll(
        entries: [SessionRecord.Entry],
        direction: LanguagePair,
        translator: TranslationCoordinator?
    ) async throws -> [String?] {
        guard let translator else { return [] }
        var drafts: [String?] = []
        drafts.reserveCapacity(entries.count)
        for entry in entries {
            try Task.checkCancellation()
            drafts.append(try? await translator.draft(
                entry.sourceText, direction: direction))
        }
        return drafts
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
        do {
            try await export.export(to: output, as: .m4a)
        } catch {
            throw ImportError.audioExtractionFailed
        }
        logger.info("import: extracted audio track from video")
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
