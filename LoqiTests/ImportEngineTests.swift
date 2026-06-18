import Foundation
import Testing
@testable import Loqi

struct ImportEngineTests {
    /// Re-transcribe always prefers the Qwen3-ASR model when it's
    /// installed — downloading it IS the opt-in; otherwise the live-engine
    /// choice applies, falling back to Apple.
    @Test func qwen3WinsWheneverInstalled() {
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "apple", senseVoiceInstalled: false, qwen3Installed: true)
            == .qwen3ASR)
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "sensevoice", senseVoiceInstalled: true, qwen3Installed: true)
            == .qwen3ASR)
    }

    @Test func senseVoiceUsedOnlyWhenChosenAndInstalled() {
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "sensevoice", senseVoiceInstalled: true, qwen3Installed: false)
            == .senseVoice)
        // Chosen but not downloaded → fall back to Apple.
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "sensevoice", senseVoiceInstalled: false, qwen3Installed: false)
            == .apple)
        // Apple chosen → never SenseVoice, even if installed.
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "apple", senseVoiceInstalled: true, qwen3Installed: false)
            == .apple)
        #expect(OfflineTranscriber.effectiveBackend(
            engineChoice: "", senseVoiceInstalled: true, qwen3Installed: false)
            == .apple)
    }

    /// Imports never auto-upgrade to Qwen3-ASR (near-realtime decode would
    /// turn a long import into an hour-long wait) — it runs only when the
    /// user explicitly picks it in the import options.
    @Test func importsHonorTheExplicitChoiceOnly() {
        // The key regression: Qwen3 installed must NOT hijack an import.
        #expect(OfflineTranscriber.importBackend(
            choice: "sensevoice", senseVoiceInstalled: true, qwen3Installed: true)
            == .senseVoice)
        #expect(OfflineTranscriber.importBackend(
            choice: "apple", senseVoiceInstalled: true, qwen3Installed: true)
            == .apple)
        // Explicit pick is honored when installed, falls back when not.
        #expect(OfflineTranscriber.importBackend(
            choice: "qwen3", senseVoiceInstalled: false, qwen3Installed: true)
            == .qwen3ASR)
        #expect(OfflineTranscriber.importBackend(
            choice: "qwen3", senseVoiceInstalled: false, qwen3Installed: false)
            == .apple)
        #expect(OfflineTranscriber.importBackend(
            choice: "sensevoice", senseVoiceInstalled: false, qwen3Installed: false)
            == .apple)
    }

    @Test func newRecordingPostProcessUsesDownloadedASROnly() {
        #expect(OfflineTranscriber.postProcessBackend(
            senseVoiceInstalled: true, qwen3Installed: true) == .qwen3ASR)
        #expect(OfflineTranscriber.postProcessBackend(
            senseVoiceInstalled: true, qwen3Installed: false) == .senseVoice)
        #expect(OfflineTranscriber.postProcessBackend(
            senseVoiceInstalled: false, qwen3Installed: false) == nil)
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
