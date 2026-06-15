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
        /// Position in the session's audio file, in seconds. Stamped at
        /// archive time via AudioTimeline so interruption gaps don't skew
        /// it; nil on records saved before this field existed.
        var audioOffset: TimeInterval?
    }

    /// One turn of the "chat with this session" Q&A. `role` is a raw
    /// String ("user"/"assistant") — the summaryStyle trick — so an unknown
    /// future role can never fail record decoding.
    struct ChatMessage: Codable, Sendable, Identifiable {
        var id = UUID()
        var role: String
        var text: String
        var date: Date

        var isUser: Bool { role == "user" }
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
        /// True when extraction failed and this note is a headline-only
        /// stub; summarize re-maps such chunks instead of trusting them.
        /// Optional so records saved before this field keep decoding.
        var isFallback: Bool?

        var hasContent: Bool {
            !facts.isEmpty || !decisions.isEmpty
                || !actions.isEmpty || !terms.isEmpty
        }
    }

    /// A photo attached during (or after) the session: slides, whiteboards,
    /// documents. The image file lives in SessionArchive.attachmentsDirectory;
    /// extracted text flows into summary, chat, and search as derived
    /// pseudo-notes (AttachmentNotes) — never cached into `chunkNotes`.
    struct Attachment: Codable, Sendable, Identifiable {
        var id = UUID()
        var fileName: String
        var timestamp: Date
        /// Last finalized entry when the photo was taken — positions the
        /// thumbnail in the transcript.
        var anchorEntryID: UUID?
        /// Vision OCR result; nil when no text was found (or OCR pending).
        var ocrText: String?
        /// User-entered caption.
        var caption: String?
        /// Vision-LLM description, when a vision-capable model tier is
        /// active. Preferred over thin OCR (diagrams, photos).
        var vlmDescription: String?
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
    /// SummaryStyle raw value the cached summary was written in. Stored as
    /// String so an unknown future value can never fail record decoding;
    /// nil (legacy records) resolves to .meeting.
    var summaryStyle: String?
    /// SummaryLength raw value used for the cached summary. Stored as a
    /// String for the same forward-compatible decode behavior as style;
    /// nil/unknown resolves to the current default, .standard.
    var summaryLength: String?
    /// Persisted Q&A turns from the chat sheet, capped at
    /// `SessionRecord.chatHistoryCap` (oldest dropped). Optional: records
    /// written before this field must keep decoding.
    var chatHistory: [ChatMessage]?
    /// LLM-generated (or user-renamed) session title. nil falls back down
    /// the `title` chain — first note headline, then transcript prefix.
    var titleText: String?
    /// True once the user renamed the session; auto-titling then never
    /// overwrites it (mirrors `summaryEdited`).
    var titleEdited: Bool?
    /// Photos attached to the session. Optional: legacy records decode.
    var attachments: [Attachment]?
    /// True until the user opens the session — the Sessions list shows a
    /// dot for fresh arrivals (saved live sessions, finished imports).
    /// Optional: legacy records decode as seen.
    var unseen: Bool?
    /// True while an import job is still filling this record. Survives a
    /// crash only as a tombstone: the archive sweeps importing records at
    /// load (a partial import has no transcript worth keeping).
    var importing: Bool?

    static let chatHistoryCap = 40

    var resolvedSummaryStyle: SummaryStyle {
        summaryStyle.flatMap(SummaryStyle.init(rawValue:)) ?? .meeting
    }

    var resolvedSummaryLength: SummaryLength {
        summaryLength.flatMap(SummaryLength.init(rawValue:)) ?? .standard
    }

    var title: String {
        titleText
            ?? chunkNotes?.first?.headline
            ?? entries.first?.sourceText.prefix(40).description
            ?? "Session"
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Audio position for an entry: the stamped offset when available,
    /// wall-clock delta from session start otherwise (legacy records; exact
    /// for imports, late by any paused stretch on old live recordings).
    func resolvedAudioOffset(of entry: Entry) -> TimeInterval {
        entry.audioOffset ?? max(0, entry.timestamp.timeIntervalSince(startedAt))
    }

    func speakerLabel(_ slot: Int?) -> String? {
        guard let slot else { return nil }
        return speakerNames[slot] ?? String(localized: "Speaker \(slot + 1)")
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
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        // Photos render at their anchor entry; ones without a (surviving)
        // anchor trail the transcript.
        var attachmentsByAnchor: [UUID: [Attachment]] = [:]
        var unanchored: [Attachment] = []
        let entryIDs = Set(entries.map(\.id))
        for attachment in attachments ?? [] {
            if let anchor = attachment.anchorEntryID, entryIDs.contains(anchor) {
                attachmentsByAnchor[anchor, default: []].append(attachment)
            } else {
                unanchored.append(attachment)
            }
        }
        func appendAttachment(_ attachment: Attachment) {
            lines.append("**🖼 Photo \(timeFormatter.string(from: attachment.timestamp))**")
            lines.append("")
            if let caption = attachment.caption, !caption.isEmpty {
                lines.append("*\(caption)*")
                lines.append("")
            }
            let text = attachment.ocrText ?? attachment.vlmDescription
            if let text, !text.isEmpty {
                for line in text.split(separator: "\n") {
                    lines.append("> \(line)")
                }
                lines.append("")
            }
        }
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
            for attachment in attachmentsByAnchor[entry.id] ?? [] {
                appendAttachment(attachment)
                lastSpeaker = -1  // re-label the next speaker after the break
            }
        }
        for attachment in unanchored {
            appendAttachment(attachment)
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
