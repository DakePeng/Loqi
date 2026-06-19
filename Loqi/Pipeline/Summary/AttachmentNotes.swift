import Foundation

/// Turns photo attachments into derived pseudo chunk-notes so their text
/// flows into the summary reduce, the chat outline, and "Summary so far".
/// Derived means derived: these notes are merged at consumption time and
/// never persisted into `chunkNotes` — mutating the cache would break the
/// `liveNotesEndEntryID` contiguous-coverage invariant that makes
/// re-summarizing reduce-only.
enum AttachmentNotes {
    static let maxLines = 6
    /// A photo contributes at most this many lines to the summary — full OCR
    /// stays in the viewer/export so cluttered backgrounds don't flood notes.
    static let summaryMaxLines = 3
    static let maxLineLength = 80
    static let headlineLength = 24

    /// nil when the attachment carries no text at all (no OCR result, no
    /// description, no caption) — an unreadable photo adds nothing to notes.
    static func note(
        for attachment: SessionRecord.Attachment
    ) -> SessionRecord.ChunkNote? {
        let facts = facts(for: attachment)
        guard let first = facts.first else { return nil }
        return SessionRecord.ChunkNote(
            id: attachment.id,  // stable identity across re-merges
            headline: "📷 " + String(first.prefix(headlineLength)),
            startedAt: attachment.timestamp,
            anchorEntryID: attachment.anchorEntryID,
            facts: Array(facts.prefix(maxLines)),
            summaryRecords: records(for: attachment))
    }

    static func records(
        for attachment: SessionRecord.Attachment,
        fallbackIndex: Int = 0
    ) -> [SessionRecord.SummaryRecord] {
        if let records = attachment.summaryRecords, !records.isEmpty {
            return records
        }
        let facts = facts(for: attachment)
        guard !facts.isEmpty else { return [] }
        let label = sourceLabel(for: attachment)
        let baseID = "p" + attachment.id.uuidString.prefix(8)
        // Photo facts attach to the surrounding transcript topic as labeled
        // points instead of spawning their own topic — so a narrated slide
        // isn't a parallel agenda item, and its lines dedup against what was
        // said about it.
        return facts.prefix(maxLines).enumerated().map { offset, fact in
            SessionRecord.SummaryRecord(
                kind: .point,
                source: .photo,
                sourceIDs: ["\(baseID)-\(offset)"],
                sourceIndex: fallbackIndex * 100 + offset,
                timestamp: attachment.timestamp,
                text: fact,
                sourceLabel: label)
        }
    }

    /// Chunk notes with the attachments' pseudo-notes folded in by time.
    /// Equal timestamps keep real notes first (sort is stable).
    static func merged(
        _ notes: [SessionRecord.ChunkNote],
        attachments: [SessionRecord.Attachment]?
    ) -> [SessionRecord.ChunkNote] {
        let extra = (attachments ?? []).compactMap(note(for:))
        guard !extra.isEmpty else { return notes }
        return (notes + extra).sorted { $0.startedAt < $1.startedAt }
    }

    private static func lines(of text: String?) -> [String] {
        (text ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func facts(for attachment: SessionRecord.Attachment) -> [String] {
        // Flatten any markdown/list scaffolding a VLM left in the description
        // so the deterministic summary never renders raw markup (also cleans
        // descriptions stored before the prompt was tightened).
        let cleanedDescription = attachment.vlmDescription.map {
            PromptBuilder().plainDescription($0)
        }
        let described = lines(of: cleanedDescription)
        let ocr = lines(of: attachment.ocrText)
        // The VLM description is the photo's summary; raw OCR (often cluttered
        // backgrounds, UI chrome) feeds the summary only when there's no
        // description — and even then just a snippet.
        let body = described.isEmpty ? ocr : described
        var facts = body.prefix(summaryMaxLines).map { String($0.prefix(maxLineLength)) }
        if let caption = attachment.caption?
            .trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
            facts.insert(String(caption.prefix(maxLineLength)), at: 0)
        }
        return Array(facts.prefix(summaryMaxLines))
    }

    private static func sourceLabel(for attachment: SessionRecord.Attachment) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Photo \(formatter.string(from: attachment.timestamp))"
    }
}
