import AVFoundation
import Foundation
import Testing
@testable import Loqi

struct ImportEngineTests {
    /// Re-transcribe always prefers the Qwen3-ASR model when it's
    /// installed — downloading it IS the opt-in; otherwise the live-engine
    /// choice applies, falling back to Apple.
    @Test func qwen3WinsWheneverInstalled() {
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "apple", source: .japanese,
            senseVoiceInstalled: false, qwen3Installed: true, dolphinInstalled: false)
            == .qwen3ASR)
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "sensevoice", source: .japanese,
            senseVoiceInstalled: true, qwen3Installed: true, dolphinInstalled: false)
            == .qwen3ASR)
    }

    /// Dolphin is the experimental fast tier: while installed it outranks
    /// Qwen3 for its languages (installing IS choosing fast; removing it
    /// returns to the accuracy pass) — but it has NO English, so an
    /// English session must never route to it.
    @Test func dolphinTakesItsLanguagesWhileInstalled() {
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "apple", source: .japanese,
            senseVoiceInstalled: false, qwen3Installed: true, dolphinInstalled: true)
            == .dolphin)
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "apple", source: .english,
            senseVoiceInstalled: false, qwen3Installed: true, dolphinInstalled: true)
            == .qwen3ASR)
        #expect(OfflineTranscriber.postProcessBackend(
            source: .chinese,
            senseVoiceInstalled: false, qwen3Installed: true, dolphinInstalled: true)
            == .dolphin)
        #expect(OfflineTranscriber.postProcessBackend(
            source: .english,
            senseVoiceInstalled: false, qwen3Installed: true, dolphinInstalled: true)
            == .qwen3ASR)
        #expect(!OfflineTranscriber.dolphinSupports(.english))
        #expect(OfflineTranscriber.dolphinSupports(.korean))
    }

    @Test func senseVoiceUsedOnlyWhenChosenAndInstalled() {
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "sensevoice", source: .japanese,
            senseVoiceInstalled: true, qwen3Installed: false, dolphinInstalled: false)
            == .senseVoice)
        // Chosen but not downloaded → fall back to Apple.
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "sensevoice", source: .japanese,
            senseVoiceInstalled: false, qwen3Installed: false, dolphinInstalled: false)
            == .apple)
        // Apple chosen → never SenseVoice, even if installed.
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "apple", source: .japanese,
            senseVoiceInstalled: true, qwen3Installed: false, dolphinInstalled: false)
            == .apple)
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "", source: .japanese,
            senseVoiceInstalled: true, qwen3Installed: false, dolphinInstalled: false)
            == .apple)
    }

    /// Imports never auto-upgrade to Qwen3-ASR (near-realtime decode would
    /// turn a long import into an hour-long wait) — it runs only when the
    /// user explicitly picks it in the import options.
    @Test func importsHonorTheExplicitChoiceOnly() {
        // The key regression: an installed model must NOT hijack an import.
        #expect(OfflineTranscriber.importBackend(
            choice: "sensevoice", source: .japanese,
            senseVoiceInstalled: true, qwen3Installed: true, dolphinInstalled: true)
            == .senseVoice)
        #expect(OfflineTranscriber.importBackend(
            choice: "apple", source: .japanese,
            senseVoiceInstalled: true, qwen3Installed: true, dolphinInstalled: true)
            == .apple)
        // Explicit pick is honored when installed, falls back when not.
        #expect(OfflineTranscriber.importBackend(
            choice: "qwen3", source: .japanese,
            senseVoiceInstalled: false, qwen3Installed: true, dolphinInstalled: false)
            == .qwen3ASR)
        #expect(OfflineTranscriber.importBackend(
            choice: "qwen3", source: .japanese,
            senseVoiceInstalled: false, qwen3Installed: false, dolphinInstalled: false)
            == .apple)
        #expect(OfflineTranscriber.importBackend(
            choice: "dolphin", source: .japanese,
            senseVoiceInstalled: false, qwen3Installed: false, dolphinInstalled: true)
            == .dolphin)
        // A stale Dolphin pick on an English import falls back to Apple.
        #expect(OfflineTranscriber.importBackend(
            choice: "dolphin", source: .english,
            senseVoiceInstalled: false, qwen3Installed: false, dolphinInstalled: true)
            == .apple)
        #expect(OfflineTranscriber.importBackend(
            choice: "sensevoice", source: .japanese,
            senseVoiceInstalled: false, qwen3Installed: false, dolphinInstalled: false)
            == .apple)
    }

    @Test func newRecordingPostProcessUsesDownloadedASROnly() {
        #expect(OfflineTranscriber.postProcessBackend(
            source: .japanese,
            senseVoiceInstalled: true, qwen3Installed: true, dolphinInstalled: false)
            == .qwen3ASR)
        #expect(OfflineTranscriber.postProcessBackend(
            source: .japanese,
            senseVoiceInstalled: true, qwen3Installed: false, dolphinInstalled: false)
            == .senseVoice)
        #expect(OfflineTranscriber.postProcessBackend(
            source: .japanese,
            senseVoiceInstalled: false, qwen3Installed: false, dolphinInstalled: false)
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

        let reader = try AVAudioFile(forReading: url)
        let task = Task { @MainActor in
            try await OfflineTranscriber.transcribe(
                reader,
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
        #expect(OfflineTranscriber.Backend.qwen3ASR.rawValue == "qwen3asr")
        #expect(OfflineTranscriber.Backend.dolphin.rawValue == "dolphin")
    }

    @Test func retranscribeReusesOnlySameBackendSegments() {
        let segments = [
            SessionRecord.ImportCheckpoint.Segment(start: 0, end: 3.5, text: "黒川さんのボス"),
        ]
        let checkpoint = SessionRecord.RetranscribeCheckpoint(
            backendRaw: "qwen3asr", segments: segments)
        #expect(SessionRetranscriber.reusableSegments(
            checkpoint: checkpoint, backend: .qwen3ASR).count == 1)
        // A SenseVoice pass must never seed from Qwen3 segments.
        #expect(SessionRetranscriber.reusableSegments(
            checkpoint: checkpoint, backend: .senseVoice).isEmpty)
        #expect(SessionRetranscriber.reusableSegments(
            checkpoint: nil, backend: .qwen3ASR).isEmpty)
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

/// The Qwen3-ASR store's file manifest: per-source paths and the local
/// layout the recognizer config depends on (tokenizer/ subdirectory).
struct Qwen3ASRModelStoreTests {
    @Test func manifestCoversRecognizerAndVAD() {
        let names = Qwen3ASRModelStore.files.map(\.name)
        #expect(names.contains("conv_frontend.onnx"))
        #expect(names.contains("encoder.int8.onnx"))
        #expect(names.contains("decoder.int8.onnx"))
        #expect(names.contains("tokenizer/vocab.json"))
        #expect(names.contains("tokenizer/merges.txt"))
        #expect(names.contains("tokenizer/tokenizer_config.json"))
        // Own VAD copy: the post-pass must not depend on SenseVoice.
        #expect(names.contains("silero_vad.onnx"))
    }

    @Test func everyFileResolvesAPathPerSource() {
        for file in Qwen3ASRModelStore.files {
            for source in ASRModelSource.allCases {
                let path = file.path(for: source)
                #expect(!path.isEmpty)
                #expect(path.hasSuffix((file.name as NSString).lastPathComponent))
            }
            #expect(file.minBytes > 0)
            #expect(file.expectedBytes >= file.minBytes)
        }
    }

    @Test func totalSizeMatchesTheDownloadButtonCopy() {
        // "~990 MB" in Settings; keep the claim honest as files change.
        let total = Qwen3ASRModelStore.totalExpectedBytes
        #expect(total > 950_000_000 && total < 1_050_000_000)
    }

    @Test func tokenizerDirectoryIsInsideTheStore() {
        #expect(Qwen3ASRModelStore.tokenizerDirectory.path.hasPrefix(
            Qwen3ASRModelStore.directory.path))
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

