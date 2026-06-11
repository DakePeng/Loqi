import Foundation

/// A finished listening session, persisted as one JSON file. The transcript
/// keeps both languages and speaker attribution so it exports cleanly.
struct SessionRecord: Identifiable, Codable, Sendable {
    struct Entry: Codable, Sendable, Identifiable {
        var id = UUID()
        var sourceText: String
        var translation: String?
        var speaker: Int?
        var direction: LanguagePair
        var timestamp: Date
        /// Original ASR text when sourceText was LLM-polished.
        var rawSourceText: String?
    }

    /// One map-phase note per transcript chunk; powers the outline and the
    /// reduce step, and is cached so re-summarizing is cheap.
    struct ChunkNote: Codable, Sendable, Identifiable {
        var id = UUID()
        var headline: String
        var startedAt: Date
        /// First entry of the chunk — outline taps scroll here.
        var anchorEntryID: UUID?
        var facts: [String] = []
        var decisions: [String] = []
        var actions: [String] = []
        var terms: [String] = []
    }

    var id = UUID()
    var mode: SessionMode
    var startedAt: Date
    var endedAt: Date
    var entries: [Entry]
    /// User-assigned names for diarization slots ("Speaker 1" → "王经理").
    var speakerNames: [Int: String] = [:]
    /// On-device LLM summary, cached once generated. Lightweight markdown:
    /// overview paragraph, then "## Heading" sections of "- " bullets.
    var summary: String?
    /// True when the user hand-edited the summary; regenerate warns first.
    var summaryEdited: Bool?
    /// Map-phase notes (outline headlines + categorized bullets).
    var chunkNotes: [ChunkNote]?
    /// Last entry covered by live-generated chunkNotes; summarize maps only
    /// entries after this id (prune-proof, unlike an index).
    var liveNotesEndEntryID: UUID?
    /// Audio recording in SessionArchive.recordingsDirectory, if saved.
    var audioFileName: String?

    var title: String {
        entries.first?.sourceText.prefix(40).description ?? "Session"
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    func speakerLabel(_ slot: Int?) -> String? {
        guard let slot else { return nil }
        return speakerNames[slot] ?? "Speaker \(slot + 1)"
    }

    /// Markdown export: header, optional summary, then the transcript with
    /// speaker labels, source, and translation.
    func markdown() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        lines.append("# Loqi session — \(formatter.string(from: startedAt))")
        lines.append("")
        lines.append("- Mode: \(mode == .captions ? "Live Captions" : "Conversation")")
        lines.append("- Duration: \(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s")
        lines.append("")
        if let summary {
            lines.append("## Summary")
            lines.append("")
            // Section headings inside the summary nest one level down.
            let demoted = summary
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("## ") ? "#\($0)" : String($0) }
                .joined(separator: "\n")
            lines.append(demoted)
            lines.append("")
        }
        if let chunkNotes, chunkNotes.count > 1 {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            lines.append("## Timeline")
            lines.append("")
            for note in chunkNotes {
                lines.append("- \(formatter.string(from: note.startedAt)) — \(note.headline)")
            }
            lines.append("")
        }
        lines.append("## Transcript")
        lines.append("")
        var lastSpeaker: Int? = -1
        for entry in entries {
            if entry.speaker != lastSpeaker, let label = speakerLabel(entry.speaker) {
                lines.append("**\(label)**")
                lines.append("")
            }
            lastSpeaker = entry.speaker
            lines.append("> \(entry.sourceText)")
            if let translation = entry.translation {
                lines.append(">")
                lines.append("> \(translation)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Plain transcript for LLM prompts (summary, hotword mining).
    func plainTranscript(limit: Int = 6000) -> String {
        var text = entries.map { entry in
            let speaker = speakerLabel(entry.speaker).map { "[\($0)] " } ?? ""
            let translation = entry.translation.map { " → \($0)" } ?? ""
            return "\(speaker)\(entry.sourceText)\(translation)"
        }.joined(separator: "\n")
        if text.count > limit {
            text = String(text.suffix(limit))
        }
        return text
    }
}
