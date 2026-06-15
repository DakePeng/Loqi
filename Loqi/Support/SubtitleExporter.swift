import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Builds SRT/WebVTT subtitle files from a session's entries. Cue starts
/// come from the stamped audio offsets (wall-clock fallback for legacy
/// records); a cue ends at the next cue's start, capped at 4 seconds.
enum SubtitleExporter {
    struct Cue: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var lines: [String]
    }

    /// Longest a cue stays up without a successor; also the tail cue length.
    static let maxCueDuration: TimeInterval = 4
    static let minCueDuration: TimeInterval = 0.5

    static func cues(for record: SessionRecord, bilingual: Bool) -> [Cue] {
        let entries = record.entries.filter { !$0.sourceText.isEmpty }
        var cues: [Cue] = []
        for (index, entry) in entries.enumerated() {
            var start = record.resolvedAudioOffset(of: entry)
            if let last = cues.last { start = max(start, last.start + minCueDuration) }
            let next = index + 1 < entries.count
                ? record.resolvedAudioOffset(of: entries[index + 1]) : nil
            var end = min(next ?? start + maxCueDuration, start + maxCueDuration)
            end = max(end, start + minCueDuration)
            var lines = [entry.sourceText]
            if bilingual, let translation = entry.translation, !translation.isEmpty {
                lines.append(translation)
            }
            cues.append(Cue(start: start, end: end, lines: lines))
        }
        // Cues may not overlap: a cue yields to its successor.
        for index in cues.indices.dropLast() {
            cues[index].end = min(cues[index].end, cues[index + 1].start)
        }
        return cues
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(timestamp(cue.start, fraction: ",")) --> \(timestamp(cue.end, fraction: ","))
            \(cue.lines.joined(separator: "\n"))
            """
        }.joined(separator: "\n\n") + "\n"
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            """
            \(timestamp(cue.start, fraction: ".")) --> \(timestamp(cue.end, fraction: "."))
            \(cue.lines.joined(separator: "\n"))
            """
        }.joined(separator: "\n\n") + "\n"
    }

    /// "HH:MM:SS,mmm" (SRT) or "HH:MM:SS.mmm" (VTT).
    static func timestamp(_ time: TimeInterval, fraction separator: String) -> String {
        let clamped = max(0, time)
        let millis = Int((clamped * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d%@%03d",
            millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60,
            separator, millis % 1000)
    }
}

/// Wraps subtitle text so ShareLink writes a correctly named .srt/.vtt file.
struct SubtitleDocument: Transferable {
    enum Format: String {
        case srt, vtt

        var utType: UTType { UTType(filenameExtension: rawValue) ?? .plainText }
    }

    var text: String
    var fileName: String
    var format: Format

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { document in
            let url = URL.temporaryDirectory
                .appending(path: "\(document.fileName).\(document.format.rawValue)")
            try Data(document.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
