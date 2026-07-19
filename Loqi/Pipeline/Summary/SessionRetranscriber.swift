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
        /// Decode held at thermal .serious — progress is deliberately
        /// frozen; ends with the next transcribing tick.
        case coolingDown
    }

    enum RetranscribeError: LocalizedError {
        case noAudio

        var errorDescription: String? {
            String(localized: "This session has no saved recording to re-transcribe.")
        }
    }

    let llm: LLMService
    let translator: TranslationCoordinator
    /// Vocabulary for the polish phase's text-level fixup.
    var hotwords: HotwordStore?
    /// Settings gate for the LFM2.5 cleanup phase. False when AI is off:
    /// re-transcribe then runs ASR + deterministic fixup only (no LLM
    /// cleanup), and the job skips the re-summary.
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
    /// The language pair every language-touching pass runs under,
    /// honoring the record's Languages-menu choices: spoken-language
    /// override wins over what the first entry recorded; the translate-to
    /// choice wins over the recorded target (nil inherits it, "" turns
    /// translation off — source == target means transcribe-only
    /// downstream). nil only when the record has no entries. Pure for
    /// testing.
    nonisolated static func languageDirection(for record: SessionRecord) -> LanguagePair? {
        guard let base = record.entries.first?.direction else { return nil }
        let source = record.spokenLanguageOverride ?? base.source
        let target: AppLanguage
        switch record.translateToRaw {
        case nil:
            // Inherit; a transcribe-only record stays transcribe-only
            // even when the spoken override moved the source.
            target = base.source == base.target ? source : base.target
        case "":
            target = source
        case let raw?:
            target = AppLanguage(rawValue: raw) ?? source
        }
        return LanguagePair(source: source, target: target)
    }

    /// Segments a fresh pass may reuse from a prior attempt's checkpoint:
    /// only when the checkpoint was written by the SAME backend — decoders
    /// aren't interchangeable. Pure for testing.
    nonisolated static func reusableSegments(
        checkpoint: SessionRecord.RetranscribeCheckpoint?,
        backend: OfflineTranscriber.Backend
    ) -> [SessionRecord.ImportCheckpoint.Segment] {
        guard let checkpoint, checkpoint.backendRaw == backend.rawValue
        else { return [] }
        return checkpoint.segments
    }

    func retranscribe(
        _ record: SessionRecord,
        backend: OfflineTranscriber.Backend,
        sensitivity: MicSensitivity = .balanced,
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> SessionRecord {
        guard let fileName = record.audioFileName,
              let direction = Self.languageDirection(for: record)
        else { throw RetranscribeError.noAudio }
        let url = SessionArchive.recordingURL(fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RetranscribeError.noAudio
        }

        // Free the LLM before ASR; the summarize that follows reloads it
        // (its admission re-poll absorbs ONNX arena release lag). The
        // decode pools size themselves against free memory, so this
        // headroom directly buys parallel decoders.
        await llm.unload()

        onPhase(.transcribing(0))
        let rawUtterances = try await OfflineTranscriber.transcribe(
            contentsOf: url,
            language: direction.source,
            backend: backend,
            sensitivity: sensitivity,
            alreadyDecoded: alreadyDecoded,
            onSegmentComplete: onSegmentComplete,
            onThermalPause: { onPhase(.coolingDown) }
        ) { fraction in
            onPhase(.transcribing(fraction))
        }
        guard !rawUtterances.isEmpty else { throw ImportError.nothingTranscribed }
        // Drop punctuation-only finals (imports do the same), attribute
        // speakers to the RAW utterances (inherited from the old record's
        // labeled ranges), then merge speaker-aware — same order as
        // imports, so pause-broken sentences heal and a speaker's
        // consecutive sentences join without fusing turn changes. Polish,
        // entries, and translation all read the merged array, aligned.
        let spoken = rawUtterances.filter { $0.text.hasSpeechContent }
        let (utterances, slots) = UtteranceMerger.mergeAttributed(
            spoken,
            slots: Self.inheritSpeakers(
                for: spoken.map { ($0.start, $0.end) }, from: record))
        // All punctuation-only noise counts as nothing transcribed.
        guard !utterances.isEmpty else { throw ImportError.nothingTranscribed }
        logger.info("retranscribe: \(rawUtterances.count) raw -> \(utterances.count) merged utterances replace \(record.entries.count) entries")

        // Polish before translation drafting so Apple translates the
        // cleaned text: deterministic hotword fixup plus LFM2.5 sentence
        // cleanup. The LLM stays loaded afterwards — the summarize that
        // follows swaps models itself.
        let (polished, _) = try await OfflineTranscriptPolisher.run(
            texts: utterances.map(\.text),
            language: direction.source,
            backend: backend,
            llm: llm,
            llmEnabled: llmCleanupEnabled,
            matcher: hotwords?.matcher,
            onProgress: { onPhase(.cleaningUpTranscript($0)) })

        var entries = utterances.enumerated().map { index, utterance in
            SessionRecord.Entry(
                sourceText: polished.texts[index],
                translation: nil,
                speaker: slots[index],
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
            // Terminal tick — the last per-entry emission was (n-1)/n.
            onPhase(.translating(1))
        }

        var updated = record
        updated.entries = entries
        updated.chunkNotes = nil
        updated.liveNotesEndEntryID = nil
        updated.summary = nil
        updated.summaryEdited = nil
        // The pass is complete — the resume checkpoint has served its
        // purpose and must not survive into the finished record.
        updated.retranscribeCheckpoint = nil
        return updated
    }

    /// Best-effort new-recording polish: downloaded ASR and downloaded
    /// offline diarization only. Failures keep the saved live session.
    func postProcessNewRecording(
        _ record: SessionRecord,
        backend: OfflineTranscriber.Backend?,
        speakerCount: Int?,
        voiceprint: VoiceprintService,
        sensitivity: MicSensitivity = .balanced,
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> SessionRecord {
        var updated = record
        if let backend {
            do {
                updated = try await retranscribe(
                    updated, backend: backend,
                    sensitivity: sensitivity,
                    alreadyDecoded: alreadyDecoded,
                    onSegmentComplete: onSegmentComplete,
                    onPhase: onPhase)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("auto post-process ASR failed: \(error.localizedDescription)")
            }
        }

        if let speakerCount {
            try await applySpeakerSeparation(
                to: &updated, speakerCount: speakerCount,
                voiceprint: voiceprint, onPhase: onPhase)
        }
        return updated
    }

    /// Manual re-transcribe diarizes only when the old transcript has no
    /// speaker labels to inherit — existing labels mean inherit-by-overlap,
    /// which protects the user's renamed slots. Pure for testing.
    nonisolated static func manualRetranscribeDiarizes(
        entriesHaveSpeakers: Bool, diarizerDownloaded: Bool, speakerCount: Int
    ) -> Bool {
        !entriesHaveSpeakers && diarizerDownloaded
            && VoiceprintService.separationEnabled(forPickerValue: speakerCount)
    }

    /// Diarize `updated`'s saved audio and stamp the slots onto its
    /// entries. Best-effort: success clears `speakerSeparationFailed` and
    /// the caches anchored to the old labels; failure sets the flag (the
    /// detail view then offers Retry). Throws only on cancellation.
    /// No-op when the diarizer isn't downloaded, separation is off for
    /// `speakerCount`, or the audio file is gone.
    func applySpeakerSeparation(
        to updated: inout SessionRecord,
        speakerCount: Int,
        voiceprint: VoiceprintService,
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws {
        guard VoiceprintService.isOfflineDiarizerDownloaded,
              VoiceprintService.separationEnabled(forPickerValue: speakerCount),
              let fileName = updated.audioFileName
        else { return }
        let url = SessionArchive.recordingURL(fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

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
            logger.error("diarization failed: \(error.localizedDescription)")
        }
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
        let slots = SpeakerAttribution.denselyRenumbered(
            SpeakerAttribution.attribute(utterances: utterances, to: segments))
        for index in record.entries.indices {
            record.entries[index].speaker = slots[index]
        }
    }
}
