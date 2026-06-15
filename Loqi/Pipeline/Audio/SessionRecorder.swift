import AVFoundation
import Foundation
import os

/// Writes the session's mic audio to an AAC file (~14 MB/hour, mono) as a
/// third consumer of the capture stream. Recording failure must never harm
/// the session: any write error puts the recorder in a dead state and the
/// transcript continues without audio.
///
/// Container is CAF, not m4a: an m4a is unplayable unless the writer
/// finalizes it (crash/jetsam mid-recording = dead file), while CAF marks
/// its audio chunk "grows to EOF" — a process killed mid-write leaves a
/// file playable up to the last chunk, which is what session recovery
/// hands back to the user.
actor SessionRecorder {
    private var targetURL: URL?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var dead = false
    private var wroteAnything = false
    private var framesWritten: AVAudioFramePosition = 0

    /// Seconds of audio written so far — the anchor for mapping wall-clock
    /// entry timestamps onto the file timeline (AudioTimeline).
    var secondsWritten: TimeInterval {
        guard let file, framesWritten > 0 else { return 0 }
        return TimeInterval(framesWritten) / file.processingFormat.sampleRate
    }

    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "recorder")

    /// AAC encoder settings derived from the incoming stream's format.
    static func aacSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    /// The file a session records into — shared with the crash journal so
    /// recovery can claim the audio without asking the (dead) recorder.
    nonisolated static func fileName(for sessionID: UUID) -> String {
        "\(sessionID.uuidString).caf"
    }

    func begin(sessionID: UUID) {
        let directory = SessionArchive.recordingsDirectory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        targetURL = directory.appending(path: Self.fileName(for: sessionID))
        file = nil
        converter = nil
        dead = false
        wroteAnything = false
        framesWritten = 0
    }

    /// Append one capture chunk. The file opens lazily on the first chunk so
    /// encoder settings always match the real stream format; it then stays
    /// open across turn restarts (an AVAudioFile cannot be reopened for
    /// append).
    func append(_ chunk: AudioCaptureService.AudioChunk) {
        guard !dead, let targetURL else { return }
        let buffer = chunk.buffer
        do {
            if file == nil {
                file = try AVAudioFile(
                    forWriting: targetURL,
                    settings: Self.aacSettings(for: buffer.format),
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved)
            }
            guard let file else { return }
            if buffer.format == file.processingFormat {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
            } else {
                // Route changes can rebuild the engine with a new format.
                guard let converted = convert(buffer, to: file.processingFormat) else { return }
                try file.write(from: converted)
                framesWritten += AVAudioFramePosition(converted.frameLength)
            }
            wroteAnything = true
        } catch {
            logger.error("recording failed; continuing without audio: \(error)")
            dead = true
            file = nil
            try? FileManager.default.removeItem(at: targetURL)
        }
    }

    /// Close the file and return its name for the session record; nil when
    /// nothing usable was recorded.
    func finish() -> String? {
        defer {
            file = nil
            targetURL = nil
        }
        file = nil  // closes on release
        guard !dead, wroteAnything, let targetURL else {
            if let targetURL { try? FileManager.default.removeItem(at: targetURL) }
            return nil
        }
        return targetURL.lastPathComponent
    }

    /// Failed session start: discard any partial file.
    func abort() {
        file = nil
        dead = true
        if let targetURL { try? FileManager.default.removeItem(at: targetURL) }
        targetURL = nil
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        converter.convert(to: output, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return output.frameLength > 0 ? output : nil
    }
}
