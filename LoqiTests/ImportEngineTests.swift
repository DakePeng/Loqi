import AVFoundation
import Foundation
import Testing
@testable import Loqi

struct ImportEngineTests {
    /// Dolphin is the high-accuracy tier: while installed it takes every
    /// session whose languages ALL fit (installing IS the opt-in; removing
    /// it falls back) — but it has NO English, so any English in the
    /// session keeps the multilingual backends.
    @Test func dolphinTakesItsLanguagesWhileInstalled() {
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "apple", sourceLanguages: [.japanese],
            senseVoiceInstalled: false, dolphinInstalled: true)
            == .dolphin)
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "apple", sourceLanguages: [.english],
            senseVoiceInstalled: false, dolphinInstalled: true)
            == .apple)
        #expect(OfflineTranscriber.postProcessBackend(
            sourceLanguages: [.chinese, .japanese],
            senseVoiceInstalled: false, dolphinInstalled: true)
            == .dolphin)
        // The flagship zh/en code-switching meeting must keep the
        // multilingual pass — Dolphin would garble every English utterance.
        #expect(OfflineTranscriber.postProcessBackend(
            sourceLanguages: [.chinese, .english],
            senseVoiceInstalled: true, dolphinInstalled: true)
            == .senseVoice)
        // No entries yet (audio-only session) fails closed to multilingual.
        #expect(OfflineTranscriber.postProcessBackend(
            sourceLanguages: [],
            senseVoiceInstalled: true, dolphinInstalled: true)
            == .senseVoice)
        #expect(!OfflineTranscriber.dolphinSupports(.english))
        #expect(OfflineTranscriber.dolphinSupports(.korean))
    }

    @Test func senseVoiceUsedOnlyWhenChosenAndInstalled() {
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "sensevoice", sourceLanguages: [.japanese],
            senseVoiceInstalled: true, dolphinInstalled: false)
            == .senseVoice)
        // Hybrid's record layer IS SenseVoice — same backend.
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "hybrid", sourceLanguages: [.japanese],
            senseVoiceInstalled: true, dolphinInstalled: false)
            == .senseVoice)
        // Chosen but not downloaded → fall back to Apple.
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "sensevoice", sourceLanguages: [.japanese],
            senseVoiceInstalled: false, dolphinInstalled: false)
            == .apple)
        // Apple chosen → never SenseVoice, even if installed.
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "apple", sourceLanguages: [.japanese],
            senseVoiceInstalled: true, dolphinInstalled: false)
            == .apple)
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "", sourceLanguages: [.japanese],
            senseVoiceInstalled: true, dolphinInstalled: false)
            == .apple)
    }

    /// Imports honor the per-file pick; unavailable picks (including the
    /// retired "qwen3" choice from an old checkpoint) fall back to Apple.
    @Test func importsHonorTheExplicitChoiceOnly() {
        // The key regression: an installed model must NOT hijack an import.
        #expect(OfflineTranscriber.importBackend(
            choice: "sensevoice", source: .japanese,
            senseVoiceInstalled: true, dolphinInstalled: true)
            == .senseVoice)
        #expect(OfflineTranscriber.importBackend(
            choice: "apple", source: .japanese,
            senseVoiceInstalled: true, dolphinInstalled: true)
            == .apple)
        #expect(OfflineTranscriber.importBackend(
            choice: "dolphin", source: .japanese,
            senseVoiceInstalled: false, dolphinInstalled: true)
            == .dolphin)
        // A stale Dolphin pick on an English import falls back to Apple.
        #expect(OfflineTranscriber.importBackend(
            choice: "dolphin", source: .english,
            senseVoiceInstalled: false, dolphinInstalled: true)
            == .apple)
        #expect(OfflineTranscriber.importBackend(
            choice: "sensevoice", source: .japanese,
            senseVoiceInstalled: false, dolphinInstalled: false)
            == .apple)
        // Retired engine choice from an old import checkpoint.
        #expect(OfflineTranscriber.importBackend(
            choice: "qwen3", source: .japanese,
            senseVoiceInstalled: true, dolphinInstalled: true)
            == .apple)
    }

    @Test func newRecordingPostProcessUsesDownloadedASROnly() {
        #expect(OfflineTranscriber.postProcessBackend(
            sourceLanguages: [.japanese],
            senseVoiceInstalled: true, dolphinInstalled: true)
            == .dolphin)
        #expect(OfflineTranscriber.postProcessBackend(
            sourceLanguages: [.japanese],
            senseVoiceInstalled: true, dolphinInstalled: false)
            == .senseVoice)
        #expect(OfflineTranscriber.postProcessBackend(
            sourceLanguages: [.japanese],
            senseVoiceInstalled: false, dolphinInstalled: false)
            == nil)
    }

    @MainActor
    @Test func cancelledOfflineDecodeStopsBeforeModelCheck() async throws {
        let url = URL.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1))
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 16_000))
        buffer.frameLength = 16_000
        try writer.write(from: buffer)

        let task = Task { @MainActor in
            try await OfflineTranscriber.transcribe(
                contentsOf: url,
                language: .english,
                backend: .senseVoice
            ) { _ in }
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test func segmentTimeRangeMapsSamplesToSeconds() {
        // 16 kHz: sample 8000 = 0.5s; 24000 samples long = 1.5s window.
        let range = VADSegmentedTranscriber.timeRange(
            start: 8_000, n: 24_000, sampleRate: 16_000)
        #expect(abs(range.start - 0.5) < 1e-9)
        #expect(abs(range.end - 2.0) < 1e-9)
    }

    @Test func timeRangeGuardsZeroSampleRate() {
        let range = VADSegmentedTranscriber.timeRange(start: 100, n: 100, sampleRate: 0)
        #expect(range.start == 100)   // divides by 1, never crashes
        #expect(range.end == 200)
    }

    @Test func decoderPoolSizeScalesWithMemoryAndCores() {
        // Ample memory + cores: capped at hardCap.
        #expect(VADSegmentedTranscriber.decoderPoolSize(
            freeBytes: 4_000_000_000, perInstanceBytes: 900_000_000,
            coreCount: 6, hardCap: 3) == 3)
        // ~2 GB free fits two instances (a 6 GB-class device).
        #expect(VADSegmentedTranscriber.decoderPoolSize(
            freeBytes: 2_000_000_000, perInstanceBytes: 900_000_000,
            coreCount: 6, hardCap: 3) == 2)
        // Tight memory always leaves the serial baseline of one decoder.
        #expect(VADSegmentedTranscriber.decoderPoolSize(
            freeBytes: 300_000_000, perInstanceBytes: 900_000_000,
            coreCount: 6, hardCap: 3) == 1)
        // Cores cap the pool even when memory is plentiful.
        #expect(VADSegmentedTranscriber.decoderPoolSize(
            freeBytes: 8_000_000_000, perInstanceBytes: 900_000_000,
            coreCount: 1, hardCap: 3) == 1)
        // Never zero, even on a hypothetical zero-memory reading.
        #expect(VADSegmentedTranscriber.decoderPoolSize(
            freeBytes: 0, perInstanceBytes: 900_000_000,
            coreCount: 6, hardCap: 3) == 1)
    }

    @Test func backendRawValuesStayStable() {
        // Persisted in RetranscribeCheckpoint.backendRaw — a rename breaks
        // every in-flight resume.
        #expect(OfflineTranscriber.Backend.apple.rawValue == "apple")
        #expect(OfflineTranscriber.Backend.senseVoice.rawValue == "sensevoice")
        #expect(OfflineTranscriber.Backend.dolphin.rawValue == "dolphin")
    }

    @Test func retranscribeReusesOnlySameBackendSegments() {
        let segments = [
            SessionRecord.ImportCheckpoint.Segment(start: 0, end: 3.5, text: "黒川さんのボス"),
        ]
        let checkpoint = SessionRecord.RetranscribeCheckpoint(
            backendRaw: "dolphin", segments: segments)
        #expect(SessionRetranscriber.reusableSegments(
            checkpoint: checkpoint, backend: .dolphin).count == 1)
        // A SenseVoice pass must never seed from Dolphin segments.
        #expect(SessionRetranscriber.reusableSegments(
            checkpoint: checkpoint, backend: .senseVoice).isEmpty)
        #expect(SessionRetranscriber.reusableSegments(
            checkpoint: nil, backend: .dolphin).isEmpty)
        // A checkpoint persisted by the retired Qwen3-ASR backend seeds
        // nothing — the current pass starts clean.
        let stale = SessionRecord.RetranscribeCheckpoint(
            backendRaw: "qwen3asr", segments: segments)
        #expect(SessionRetranscriber.reusableSegments(
            checkpoint: stale, backend: .dolphin).isEmpty)
    }

    /// The Languages-menu resolution: spoken override wins over the
    /// recorded source; translate-to inherits (nil), disables (""), or
    /// overrides the target; transcribe-only records stay transcribe-only
    /// when only the source moves.
    @Test func languageDirectionHonorsRecordOverrides() {
        var record = SessionRecord(
            mode: .captions, startedAt: .now, endedAt: .now,
            entries: [SessionRecord.Entry(
                sourceText: "こんにちは",
                translation: nil,
                speaker: nil,
                direction: LanguagePair(source: .japanese, target: .chinese),
                timestamp: .now)])

        // nil overrides → recorded pair.
        #expect(SessionRetranscriber.languageDirection(for: record)
            == LanguagePair(source: .japanese, target: .chinese))
        // Spoken override moves the source, target inherited.
        record.spokenLanguageRaw = AppLanguage.korean.rawValue
        #expect(SessionRetranscriber.languageDirection(for: record)
            == LanguagePair(source: .korean, target: .chinese))
        // Explicit off → transcribe-only.
        record.translateToRaw = ""
        #expect(SessionRetranscriber.languageDirection(for: record)
            == LanguagePair(source: .korean, target: .korean))
        // Explicit target.
        record.translateToRaw = AppLanguage.english.rawValue
        #expect(SessionRetranscriber.languageDirection(for: record)
            == LanguagePair(source: .korean, target: .english))
        // Transcribe-only record + spoken override stays transcribe-only.
        var plain = record
        plain.spokenLanguageRaw = AppLanguage.chinese.rawValue
        plain.translateToRaw = nil
        plain.entries[0].direction = LanguagePair(source: .japanese, target: .japanese)
        #expect(SessionRetranscriber.languageDirection(for: plain)
            == LanguagePair(source: .chinese, target: .chinese))
        // No entries → nil.
        plain.entries = []
        #expect(SessionRetranscriber.languageDirection(for: plain) == nil)
    }

    /// Manual re-transcribe diarizes ONLY a label-less session — labels
    /// present means inherit-by-overlap, protecting renamed slots.
    @Test func manualRetranscribeDiarizesOnlyLabellessSessions() {
        #expect(SessionRetranscriber.manualRetranscribeDiarizes(
            entriesHaveSpeakers: false, diarizerDownloaded: true, speakerCount: -1))
        #expect(SessionRetranscriber.manualRetranscribeDiarizes(
            entriesHaveSpeakers: false, diarizerDownloaded: true, speakerCount: 3))
        // Existing labels → inherit, never re-cluster.
        #expect(!SessionRetranscriber.manualRetranscribeDiarizes(
            entriesHaveSpeakers: true, diarizerDownloaded: true, speakerCount: -1))
        // No model → nothing to run.
        #expect(!SessionRetranscriber.manualRetranscribeDiarizes(
            entriesHaveSpeakers: false, diarizerDownloaded: false, speakerCount: -1))
        // Separation off (one voice) → skip.
        #expect(!SessionRetranscriber.manualRetranscribeDiarizes(
            entriesHaveSpeakers: false, diarizerDownloaded: true, speakerCount: 0))
    }

    @Test func thermalHoldTriggersAtSeriousAndAbove() {
        // Below .serious the batch pass runs; at .serious+ it holds so the
        // SoC cools instead of grinding through OS throttling.
        #expect(!VADSegmentedTranscriber.shouldHoldForThermals(.nominal))
        #expect(!VADSegmentedTranscriber.shouldHoldForThermals(.fair))
        #expect(VADSegmentedTranscriber.shouldHoldForThermals(.serious))
        #expect(VADSegmentedTranscriber.shouldHoldForThermals(.critical))
    }

    @Test func cachedTextMatchesOnlyExactRange() {
        let checkpoint = [
            SessionRecord.ImportCheckpoint.Segment(start: 0, end: 4.5, text: "大家好"),
            SessionRecord.ImportCheckpoint.Segment(start: 4.5, end: 9, text: "今天讲翻译"),
        ]
        #expect(VADSegmentedTranscriber.cachedText(
            start: 0, end: 4.5, in: checkpoint) == "大家好")
        #expect(VADSegmentedTranscriber.cachedText(
            start: 4.5, end: 9, in: checkpoint) == "今天讲翻译")
        // A resumed decode reproducing a different boundary (VAD drift,
        // or the retry-halves sub-ranges) is a clean miss, not a mismatch.
        #expect(VADSegmentedTranscriber.cachedText(
            start: 0, end: 5, in: checkpoint) == nil)
        #expect(VADSegmentedTranscriber.cachedText(
            start: 10, end: 12, in: []) == nil)
    }
}

struct ImportAudioSheetTests {
    @Test func importLanguageDoesNotInheritRecordingAuto() {
        #expect(ImportAudioSheet.importLanguageRaw("auto") == AppLanguage.english.rawValue)
        #expect(ImportAudioSheet.importLanguageRaw(nil) == AppLanguage.english.rawValue)
        #expect(ImportAudioSheet.importLanguageRaw("chinese") == AppLanguage.chinese.rawValue)
    }

    @Test func importSensitivityDefaultsToBalancedAndKeepsValidChoices() {
        #expect(ImportAudioSheet.importSensitivityRaw(nil) == MicSensitivity.balanced.rawValue)
        #expect(ImportAudioSheet.importSensitivityRaw("loud") == MicSensitivity.balanced.rawValue)
        #expect(ImportAudioSheet.importSensitivityRaw("far") == MicSensitivity.far.rawValue)
    }
}

/// Empty-decode rescue: suspicious segments split into exact halves so a
/// blanked autoregressive decode can't silently eat transcript content.
struct RetryHalvesTests {
    @Test func halvesCoverTheSegmentExactly() {
        let halves = VADSegmentedTranscriber.retryHalves(start: 16_000, count: 161_000)
        #expect(halves.count == 2)
        #expect(halves[0].start == 16_000)
        #expect(halves[0].count == 80_500)
        #expect(halves[1].start == 96_500)
        #expect(halves[1].count == 80_500)
        #expect(halves[0].count + halves[1].count == 161_000)
    }

    @Test func oddCountsLoseNothing() {
        let halves = VADSegmentedTranscriber.retryHalves(start: 0, count: 33)
        #expect(halves[0].count + halves[1].count == 33)
        #expect(halves[1].start == 16)
    }
}

/// The speaker-separation retry's core: re-attributing existing entries to
/// diarization slots by audio-time overlap, leaving entry IDs (and thus the
/// summaries/notes anchored to them) intact.
struct SpeakerSeparationRetryTests {
    @Test func reattributesBySlotOverlapAndKeepsEntryIDs() {
        let direction = LanguagePair(source: .english, target: .english)
        let now = Date()
        var record = SessionRecord(
            mode: .captions, startedAt: now, endedAt: now.addingTimeInterval(20),
            entries: [
                .init(sourceText: "first", translation: nil, speaker: nil,
                      direction: direction, timestamp: now, audioOffset: 0),
                .init(sourceText: "second", translation: nil, speaker: nil,
                      direction: direction, timestamp: now.addingTimeInterval(10),
                      audioOffset: 10),
            ])
        let ids = record.entries.map(\.id)

        SessionRetranscriber.applyDiarizationSegments(
            [.init(slot: 0, start: 0, end: 9), .init(slot: 1, start: 10, end: 20)],
            to: &record)

        #expect(record.entries.map(\.speaker) == [0, 1])
        #expect(record.entries.map(\.id) == ids)
    }
}

