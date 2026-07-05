import AVFoundation
import Foundation
import os

/// Re-transcribes a saved session's audio through the offline pipeline
/// (the same backends imports use) to lift transcript quality above what
/// the live single-pass produced, then hands the caller a record ready
/// for a fresh summarize.
///
/// Memory choreography is strict: the LLM is unloaded before the ASR
/// model runs and only reloaded by the summarize that follows — SenseVoice
/// ONNX arenas and the Qwen weights can't coexist on tight devices.
@MainActor
struct SessionRetranscriber {
    enum Phase: Equatable {
        case transcribing(Double)   // 0...1 through the file
        case cleaningUpTranscript(Double)
        case identifyingSpeakers(Double)
        case translating(Double)
    }

    enum RetranscribeError: LocalizedError {
        case noAudio

        var errorDescription: String? {
            String(localized: "This session has no saved recording to re-transcribe.")
        }
    }

    let llm: LLMService
    let translator: TranslationCoordinator
    /// Vocabulary that primes the Qwen3-ASR decoder when it runs the pass.
    var hotwords: HotwordStore?
    /// Settings gate for the LFM2.5 cleanup phase. Retranscribe jobs are
    /// already gated upstream (JobError.aiDisabled); passed for correctness.
    var llmCleanupEnabled = true
    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "retranscribe")

    /// True when the session has audio on disk to re-transcribe — gates
    /// the UI action.
    static func canRetranscribe(_ record: SessionRecord) -> Bool {
        guard let fileName = record.audioFileName else { return false }
        return FileManager.default.fileExists(
            atPath: SessionArchive.recordingURL(fileName: fileName).path)
    }

    /// Replace the record's transcript with an offline re-transcription of
    /// its saved audio. Speakers are inherited from the old transcript by
    /// time overlap (diarization segments aren't persisted; this keeps the
    /// user's `speakerNames` slots). Translations are re-drafted — the old
    /// ones describe the old text. The summary, notes, and live-coverage
    /// caches are cleared: they anchor to replaced entry IDs.
    ///
    /// The caller persists the result and runs a normal summarize.
    func retranscribe(
        _ record: SessionRecord,
        backend: OfflineTranscriber.Backend = OfflineTranscriber.currentBackend(),
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> SessionRecord {
        guard let fileName = record.audioFileName,
              let direction = record.entries.first?.direction
        else { throw RetranscribeError.noAudio }
        let url = SessionArchive.recordingURL(fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RetranscribeError.noAudio
        }
        let audioFile = try AVAudioFile(forReading: url)

        // Free the LLM before ASR; the summarize that follows reloads it
        // (its admission re-poll absorbs ONNX arena release lag). Required
        // for the Qwen3-ASR pass: ~940MB of decoder weights.
        await llm.unload()

        onPhase(.transcribing(0))
        let utterances = try await OfflineTranscriber.transcribe(
            audioFile,
            language: direction.source,
            backend: backend,
            hotwords: hotwords?.biasStrings(for: direction.source) ?? []
        ) { fraction in
            onPhase(.transcribing(fraction))
        }
        guard !utterances.isEmpty else { throw ImportError.nothingTranscribed }
        logger.info("retranscribe: \(utterances.count) utterances replace \(record.entries.count) entries")

        // Polish before translation drafting so Apple translates the
        // cleaned text: deterministic hotword fixup for every backend,
        // plus LFM2.5 sentence cleanup for the non-accuracy-pass ones
        // (Qwen3-ASR already had decoder hotword priming). The LLM stays
        // loaded afterwards — the summarize that follows swaps models
        // itself.
        let (polished, _) = try await OfflineTranscriptPolisher.run(
            texts: utterances.map(\.text),
            language: direction.source,
            backend: backend,
            llm: llm,
            llmEnabled: llmCleanupEnabled,
            matcher: hotwords?.matcher,
            onProgress: { onPhase(.cleaningUpTranscript($0)) })

        let speakers = Self.inheritSpeakers(
            for: utterances.map { ($0.start, $0.end) }, from: record)
        var entries = utterances.enumerated().map { index, utterance in
            SessionRecord.Entry(
                sourceText: polished.texts[index],
                translation: nil,
                speaker: speakers[index],
                direction: direction,
                timestamp: record.startedAt.addingTimeInterval(utterance.start),
                rawSourceText: polished.originals[index],
                audioOffset: utterance.start)
        }

        if direction.source != direction.target {
            await translator.addDirection(direction)
            for index in entries.indices {
                onPhase(.translating(Double(index) / Double(max(entries.count, 1))))
                entries[index].translation = try? await translator.draft(
                    entries[index].sourceText, direction: direction)
            }
        }

        var updated = record
        updated.entries = entries
        updated.chunkNotes = nil
        updated.liveNotesEndEntryID = nil
        updated.summary = nil
        updated.summaryEdited = nil
        return updated
    }

    /// Best-effort new-recording polish: downloaded ASR and downloaded
    /// offline diarization only. Failures keep the saved live session.
    func postProcessNewRecording(
        _ record: SessionRecord,
        backend: OfflineTranscriber.Backend?,
        speakerCount: Int?,
        voiceprint: VoiceprintService,
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> SessionRecord {
        var updated = record
        if let backend {
            do {
                updated = try await retranscribe(
                    updated, backend: backend, onPhase: onPhase)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("auto post-process ASR failed: \(error.localizedDescription)")
            }
        }

        guard VoiceprintService.isOfflineDiarizerDownloaded,
              let speakerCount,
              VoiceprintService.separationEnabled(forPickerValue: speakerCount),
              let fileName = updated.audioFileName
        else { return updated }
        let url = SessionArchive.recordingURL(fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return updated }

        do {
            onPhase(.identifyingSpeakers(0))
            let segments = try await voiceprint.diarizeFile(
                url: url, speakerCount: speakerCount
            ) { progress in
                Task { @MainActor in
                    if case .analysis(let fraction) = progress {
                        onPhase(.identifyingSpeakers(fraction))
                    }
                }
            }
            Self.applyDiarizationSegments(segments, to: &updated)
            updated.speakerSeparationFailed = nil
            updated.chunkNotes = nil
            updated.liveNotesEndEntryID = nil
            updated.summary = nil
            updated.summaryEdited = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            updated.speakerSeparationFailed = true
            logger.error("auto post-process diarization failed: \(error.localizedDescription)")
        }
        return updated
    }

    /// Map each new utterance to the old entry it overlaps most and take
    /// that entry's speaker slot. Old entries become segments running from
    /// their audio offset (falling back to the timestamp delta on records
    /// saved before offsets existed) to the next entry's start; reuses the
    /// import pipeline's overlap attribution.
    nonisolated static func inheritSpeakers(
        for utterances: [(start: TimeInterval, end: TimeInterval)],
        from record: SessionRecord
    ) -> [Int?] {
        let starts = record.entries.map { entry in
            entry.audioOffset ?? entry.timestamp.timeIntervalSince(record.startedAt)
        }
        var segments: [SpeakerAttribution.Segment] = []
        for (index, entry) in record.entries.enumerated() {
            guard let speaker = entry.speaker else { continue }
            let end = index + 1 < starts.count
                ? starts[index + 1]
                : max(utterances.last?.end ?? 0, starts[index] + 30)
            guard end > starts[index] else { continue }
            segments.append(.init(slot: speaker, start: starts[index], end: end))
        }
        return SpeakerAttribution.attribute(utterances: utterances, to: segments)
    }

    /// Re-attribute every entry to the speaker slot its audio range overlaps
    /// most. Reused by the standalone speaker-separation retry, so it's a
    /// pure static helper. Entry IDs are untouched — only the `speaker` slot
    /// changes — so cached summaries/notes stay valid.
    nonisolated static func applyDiarizationSegments(
        _ segments: [SpeakerAttribution.Segment],
        to record: inout SessionRecord
    ) {
        let utterances = record.entries.enumerated().map { index, entry in
            let start = record.resolvedAudioOffset(of: entry)
            let end = index + 1 < record.entries.count
                ? max(start, record.resolvedAudioOffset(of: record.entries[index + 1]))
                : max(start + 3, segments.last?.end ?? start + 3)
            return (start: start, end: end)
        }
        let slots = SpeakerAttribution.attribute(utterances: utterances, to: segments)
        for index in record.entries.indices {
            record.entries[index].speaker = slots[index]
        }
    }
}
