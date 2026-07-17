import Foundation
import os

#if os(iOS)
/// Shared offline flow behind SenseVoice and Dolphin file transcription:
/// silero VAD chops a whole decoded file into speech segments and each
/// closed segment gets one decode by the supplied recognizer. The VAD
/// reports every segment's global sample offset, so the time ranges line
/// up with the original-file timeline that diarization reads.
enum VADSegmentedTranscriber {
    struct Utterance: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    static let sampleRate = 16_000
    /// Feed window — small enough for smooth progress, big enough to be cheap.
    private static let feedWindow = 16_000   // 1s

    /// Segment sample bounds → seconds. Pure for testing.
    static func timeRange(
        start: Int, n: Int, sampleRate: Int
    ) -> (start: TimeInterval, end: TimeInterval) {
        let rate = Double(max(sampleRate, 1))
        return (Double(start) / rate, Double(start + n) / rate)
    }

    /// Text already decoded for this exact segment range on a prior
    /// attempt, if any. Pure for testing.
    static func cachedText(
        start: TimeInterval, end: TimeInterval,
        in alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment]
    ) -> String? {
        alreadyDecoded.first(where: { $0.start == start && $0.end == end })?.text
    }

    /// A decode that comes back empty for a clearly-speech-length segment
    /// is suspicious (autoregressive decoders can blank out near their
    /// token budget); retrying the halves rescues the content instead of
    /// silently dropping it from the transcript. Pure split for testing.
    static func retryHalves(start: Int, count: Int) -> [(start: Int, count: Int)] {
        let firstHalf = count / 2
        return [(start, firstHalf), (start + firstHalf, count - firstHalf)]
    }

    /// Segments at least this long should never legitimately decode to
    /// nothing — below it, empty just means noise.
    private static let suspiciousEmptySamples = sampleRate * 2

    private static let logger = Logger(
        subsystem: "com.kunzhipeng.loqi", category: "import")

    /// Decode one VAD segment, splitting once on a suspicious empty result.
    private static func decodeSegment(
        samples: [Float], start: Int,
        decode: ([Float]) async -> String
    ) async -> [Utterance] {
        let text = await decode(samples)
        if !text.isEmpty {
            let (s, e) = timeRange(start: start, n: samples.count, sampleRate: sampleRate)
            return [Utterance(text: text, start: s, end: e)]
        }
        guard samples.count >= suspiciousEmptySamples else { return [] }
        logger.warning("empty decode for \(samples.count) samples; retrying halves")
        var rescued: [Utterance] = []
        for half in retryHalves(start: start, count: samples.count) {
            let slice = Array(samples[(half.start - start)..<(half.start - start + half.count)])
            let halfText = await decode(slice)
            if !halfText.isEmpty {
                let (s, e) = timeRange(start: half.start, n: half.count, sampleRate: sampleRate)
                rescued.append(Utterance(text: halfText, start: s, end: e))
            }
        }
        return rescued
    }

    /// Maximum decoders the pool helper will ever return — two extra
    /// recognizers' worth of ONNX arenas is the most we'll risk.
    static let maxDecoderPool = 3

    /// True when the batch pass should hold before starting another
    /// segment: at sustained `.serious` iOS throttles the whole SoC, so
    /// pausing cools faster AND wastes less than grinding on. Pure for
    /// testing.
    static func shouldHoldForThermals(_ state: ProcessInfo.ThermalState) -> Bool {
        state >= .serious
    }

    /// How often a held decode re-checks the thermal state.
    static let thermalPollInterval: Duration = .seconds(15)

    /// Sleep-poll until the SoC cools below `.serious`. Cancellation
    /// propagates through `Task.sleep`, so a cancelled import/re-transcribe
    /// stops promptly even mid-hold. In-flight decodes finish naturally;
    /// only new segments wait.
    private static func waitWhileThermallyLimited() async throws {
        guard shouldHoldForThermals(ProcessInfo.processInfo.thermalState) else { return }
        logger.notice("offline decode paused: thermal state serious")
        repeat {
            try await Task.sleep(for: thermalPollInterval)
        } while shouldHoldForThermals(ProcessInfo.processInfo.thermalState)
        logger.notice("offline decode resumed: thermal state recovered")
    }

    /// How many independent decoders to run in parallel given the free
    /// memory and core budget. The first is always allowed (it's today's
    /// single-decoder baseline); each additional one needs its own
    /// `perInstanceBytes` free and a spare core, capped at `hardCap`. Pure
    /// for testing — mirrors `LLMService.admittedCacheLimit`.
    static func decoderPoolSize(
        freeBytes: UInt64, perInstanceBytes: UInt64, coreCount: Int, hardCap: Int
    ) -> Int {
        let byMemory = perInstanceBytes == 0
            ? hardCap : Int(freeBytes / perInstanceBytes)
        return max(1, min(hardCap, min(byMemory, max(1, coreCount))))
    }

    /// Transcribe a file already decoded to 16 kHz mono float.
    /// `maxSpeechDuration` caps a segment so monologues still split;
    /// `onProgress`
    /// reports 0…1 by samples consumed. Segments decode concurrently across
    /// the `decoders` pool (a 1-element pool is exactly serial); the in-flight
    /// bound paces the VAD producer to decode throughput, so progress stays
    /// meaningful and at most pool-size segment buffers are held at once.
    /// Cancellation-cooperative: long files decode for minutes and a
    /// cancelled import must stop promptly.
    ///
    /// `alreadyDecoded` lets a resumed import skip segments it already has
    /// text for (matched by exact time range — VAD is a deterministic
    /// function of the same audio, so a replay reproduces the same
    /// ranges). `onSegmentComplete` reports each freshly-decoded (non-empty)
    /// segment as it lands, so a caller can checkpoint it immediately.
    /// ponytail: a segment rescued by `retryHalves` caches under its two
    /// half-ranges, not the parent range, so a resume re-decodes it once
    /// more instead of matching — harmless (same deterministic result),
    /// just not a free skip; only worth precise sub-range matching if that
    /// shows up as a real resume-time cost.
    static func transcribe(
        samples16k samples: [Float],
        vadModelPath: String,
        sensitivity: MicSensitivity = .balanced,
        maxSpeechDuration: Float,
        decoders: [@Sendable ([Float]) async -> String],
        alreadyDecoded: [SessionRecord.ImportCheckpoint.Segment] = [],
        onSegmentComplete: (@MainActor @Sendable (SessionRecord.ImportCheckpoint.Segment) -> Void)? = nil,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async throws -> [Utterance] {
        precondition(!decoders.isEmpty, "need at least one decoder")
        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: vadModelPath,
                threshold: sensitivity.sileroThreshold,
                minSilenceDuration: sensitivity.sileroMinSilence,
                minSpeechDuration: 0.25,
                windowSize: 512,
                maxSpeechDuration: maxSpeechDuration),
            sampleRate: Int32(sampleRate),
            numThreads: 1)
        let vad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig, buffer_size_in_seconds: 60)

        let total = max(samples.count, 1)
        // maxSpeechDuration only tightens the VAD's gate; steady noise or
        // music keeps a segment open forever and the buffer grows without
        // bound. Force a split at 2× so decodes stay near the intended
        // length (a too-long decode can come back empty and the
        // retry-halves rescue re-splits it anyway).
        var runLimiter = SpeechRunLimiter(
            limit: Int(maxSpeechDuration * 2) * sampleRate)

        return try await withThrowingTaskGroup(
            of: (segment: Int, slot: Int, utterances: [Utterance]).self
        ) { group in
            // Results keyed by discovery order; `free` is the indices of
            // idle decoders so each is used by at most one task at a time.
            var results: [Int: [Utterance]] = [:]
            var free = Array(decoders.indices)
            var discovered = 0

            func harvestOne() async throws {
                guard let done = try await group.next() else { return }
                results[done.segment] = done.utterances
                free.append(done.slot)
                for utterance in done.utterances {
                    await onSegmentComplete?(SessionRecord.ImportCheckpoint.Segment(
                        start: utterance.start, end: utterance.end, text: utterance.text))
                }
            }

            // Dispatch a closed segment to an idle decoder, harvesting first
            // when the pool is saturated (this is what paces the producer).
            // A segment whose exact range was already decoded on a prior
            // attempt reuses that text instead of paying for another decode.
            func dispatch(_ segmentSamples: [Float], start: Int, index: Int) async throws {
                let (s, e) = timeRange(start: start, n: segmentSamples.count, sampleRate: sampleRate)
                if let text = Self.cachedText(start: s, end: e, in: alreadyDecoded) {
                    results[index] = [Utterance(text: text, start: s, end: e)]
                    return
                }
                try await waitWhileThermallyLimited()
                if free.isEmpty { try await harvestOne() }
                let slot = free.removeLast()
                group.addTask {
                    let utterances = await decodeSegment(
                        samples: segmentSamples, start: start,
                        decode: decoders[slot])
                    return (index, slot, utterances)
                }
            }

            var offset = 0
            while offset < samples.count {
                try Task.checkCancellation()
                let upper = min(offset + feedWindow, samples.count)
                vad.acceptWaveform(samples: Array(samples[offset..<upper]))
                if runLimiter.shouldSplit(
                    isSpeech: vad.isSpeechDetected(), samples: upper - offset) {
                    vad.flush()
                }
                offset = upper
                while !vad.isEmpty() {
                    let segment = vad.front()
                    let segmentSamples = segment.samples
                    let segmentStart = segment.start
                    vad.pop()
                    try await dispatch(segmentSamples, start: segmentStart, index: discovered)
                    discovered += 1
                }
                await onProgress(Double(offset) / Double(total))
            }
            // Close any segment still open at EOF so the last words aren't lost.
            vad.flush()
            while !vad.isEmpty() {
                let segment = vad.front()
                let segmentSamples = segment.samples
                let segmentStart = segment.start
                vad.pop()
                try await dispatch(segmentSamples, start: segmentStart, index: discovered)
                discovered += 1
            }
            // Drain remaining in-flight decodes, then reassemble in time order.
            while results.count < discovered {
                try await harvestOne()
            }
            await onProgress(1)
            return (0..<discovered).flatMap { results[$0] ?? [] }
        }
    }
}
#else
enum VADSegmentedTranscriber {
    struct Utterance: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    static let maxDecoderPool = 1

    static func timeRange(
        start: Int, n: Int, sampleRate: Int
    ) -> (start: TimeInterval, end: TimeInterval) {
        let rate = Double(max(sampleRate, 1))
        return (Double(start) / rate, Double(start + n) / rate)
    }

    static func retryHalves(start: Int, count: Int) -> [(start: Int, count: Int)] {
        let firstHalf = count / 2
        return [(start, firstHalf), (start + firstHalf, count - firstHalf)]
    }

    static func decoderPoolSize(
        freeBytes: UInt64, perInstanceBytes: UInt64, coreCount: Int, hardCap: Int
    ) -> Int {
        1
    }
}
#endif
