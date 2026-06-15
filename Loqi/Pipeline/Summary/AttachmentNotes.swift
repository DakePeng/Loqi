import Foundation

/// Turns photo attachments into derived pseudo chunk-notes so their text
/// flows into the summary reduce, the chat outline, and "Summary so far".
/// Derived means derived: these notes are merged at consumption time and
/// never persisted into `chunkNotes` — mutating the cache would break the
/// `liveNotesEndEntryID` contiguous-coverage invariant that makes
/// re-summarizing reduce-only.
enum AttachmentNotes {
    static let maxLines = 6
    static let maxLineLength = 80
    static let headlineLength = 24

    /// nil when the attachment carries no text at all (no OCR result, no
    /// description, no caption) — an unreadable photo adds nothing to notes.
    static func note(
        for attachment: SessionRecord.Attachment
    ) -> SessionRecord.ChunkNote? {
        let ocr = lines(of: attachment.ocrText)
        let described = lines(of: attachment.vlmDescription)
        // Substantial OCR (slides, documents) beats the description; thin
        // OCR (diagrams, photos) defers to it.
        let body = ocr.reduce(0, { $0 + $1.count }) >= 12 || described.isEmpty
            ? ocr : described
        var facts = body.prefix(maxLines).map { String($0.prefix(maxLineLength)) }
        if let caption = attachment.caption?
            .trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
            facts.insert(String(caption.prefix(maxLineLength)), at: 0)
        }
        guard let first = facts.first else { return nil }
        return SessionRecord.ChunkNote(
            id: attachment.id,  // stable identity across re-merges
            headline: "📷 " + String(first.prefix(headlineLength)),
            startedAt: attachment.timestamp,
            anchorEntryID: attachment.anchorEntryID,
            facts: Array(facts.prefix(maxLines)))
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
}
