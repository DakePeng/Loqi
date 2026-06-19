import Foundation

/// Keyword search over saved sessions. CJK-safe by construction: plain
/// case-insensitive substring containment — no word boundaries, no
/// tokenization, and no diacritic folding (dakuten stay significant).
enum SessionSearch {
    struct Match: Identifiable {
        var sessionID: UUID
        var matchCount: Int
        var snippet: String
        /// First transcript entry whose text matched — the detail view's
        /// jump target. nil when only summary/notes/speaker names matched.
        var firstEntryID: UUID?
        var id: UUID { sessionID }
    }

    /// Everything searchable, lowercased and newline-joined. Counting and
    /// filtering run on this blob; snippets are re-derived from the
    /// original-cased fields because lowercasing can change string length
    /// (ß → ss) and shift indices.
    static func haystack(for record: SessionRecord) -> String {
        var parts: [String] = []
        if let titleText = record.titleText { parts.append(titleText) }
        for entry in record.entries {
            parts.append(entry.sourceText)
            if let translation = entry.translation { parts.append(translation) }
        }
        if let summary = record.summary { parts.append(summary) }
        for note in record.chunkNotes ?? [] {
            parts.append(note.headline)
            parts.append(contentsOf: note.facts)
            parts.append(contentsOf: note.decisions)
            parts.append(contentsOf: note.actions)
            parts.append(contentsOf: note.terms)
            for summaryRecord in note.summaryRecords ?? [] {
                parts.append(summaryRecord.text)
                if let topicTitle = summaryRecord.topicTitle { parts.append(topicTitle) }
                if let owner = summaryRecord.owner { parts.append(owner) }
                if let deadline = summaryRecord.deadline { parts.append(deadline) }
            }
        }
        parts.append(contentsOf: record.speakerNames.values)
        for attachment in record.attachments ?? [] {
            if let text = attachment.ocrText { parts.append(text) }
            if let caption = attachment.caption { parts.append(caption) }
            if let described = attachment.vlmDescription { parts.append(described) }
            for summaryRecord in attachment.summaryRecords ?? [] {
                parts.append(summaryRecord.text)
                if let topicTitle = summaryRecord.topicTitle { parts.append(topicTitle) }
            }
        }
        return parts.joined(separator: "\n").lowercased()
    }

    /// Cheap cache-invalidation key: changes whenever anything searchable
    /// can have changed (summarize, speaker rename, summary edit, import).
    static func fingerprint(of record: SessionRecord) -> String {
        let names = record.speakerNames.sorted { $0.key < $1.key }
            .map(\.value).joined(separator: ",")
        let summary = record.summary?.count ?? 0
        let notes = record.chunkNotes?.count ?? 0
        let title = record.titleText ?? ""
        let attachments = (record.attachments ?? []).reduce(0) {
            $0 + 1 + ($1.ocrText?.count ?? 0) + ($1.caption?.count ?? 0)
                + ($1.vlmDescription?.count ?? 0)
                + ($1.summaryRecords ?? []).reduce(0) { $0 + $1.text.count }
        }
        let recordText = (record.chunkNotes ?? []).reduce(0) {
            $0 + ($1.summaryRecords ?? []).reduce(0) { $0 + $1.text.count }
        }
        return "\(record.entries.count)|\(summary)|\(notes)|\(recordText)|\(names)|\(title)|\(attachments)|\(record.endedAt.timeIntervalSince1970)"
    }

    /// Non-overlapping occurrences of the lowercased query in the blob.
    static func occurrences(of lowercasedQuery: String, in haystack: String) -> Int {
        guard !lowercasedQuery.isEmpty else { return 0 }
        var count = 0
        var from = haystack.startIndex
        while let range = haystack.range(
            of: lowercasedQuery, range: from..<haystack.endIndex) {
            count += 1
            from = range.upperBound
        }
        return count
    }

    /// ~`radius` characters either side of the first case-insensitive hit,
    /// ellipsized where clipped; original casing preserved.
    static func snippet(in text: String, query: String, radius: Int = 28) -> String? {
        guard let range = text.range(of: query, options: .caseInsensitive)
        else { return nil }
        let start = text.index(
            range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(
            range.upperBound, offsetBy: radius, limitedBy: text.endIndex)
            ?? text.endIndex
        var clip = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
        if start > text.startIndex { clip = "…" + clip }
        if end < text.endIndex { clip += "…" }
        return clip
    }

    static func firstMatchingEntryID(in record: SessionRecord, query: String) -> UUID? {
        for entry in record.entries {
            if entry.sourceText.range(of: query, options: .caseInsensitive) != nil
                || entry.translation?.range(of: query, options: .caseInsensitive) != nil {
                return entry.id
            }
        }
        return nil
    }

    /// First original-cased field containing the query, in display-priority
    /// order: entry source → entry translation → summary → note text →
    /// speaker name.
    static func snippetSource(in record: SessionRecord, query: String) -> String? {
        for entry in record.entries {
            if entry.sourceText.range(of: query, options: .caseInsensitive) != nil {
                return entry.sourceText
            }
            if let translation = entry.translation,
               translation.range(of: query, options: .caseInsensitive) != nil {
                return translation
            }
        }
        if let summary = record.summary,
           summary.range(of: query, options: .caseInsensitive) != nil {
            return summary
        }
        for note in record.chunkNotes ?? [] {
            for line in [note.headline] + note.facts + note.decisions
                + note.actions + note.terms
            where line.range(of: query, options: .caseInsensitive) != nil {
                return line
            }
            for summaryRecord in note.summaryRecords ?? [] {
                let fields = [
                    summaryRecord.text,
                    summaryRecord.topicTitle,
                    summaryRecord.owner,
                    summaryRecord.deadline,
                ].compactMap { $0 }
                if let match = fields.first(where: {
                    $0.range(of: query, options: .caseInsensitive) != nil
                }) {
                    return match
                }
            }
        }
        for attachment in record.attachments ?? [] {
            let fields = [
                attachment.caption,
                attachment.ocrText,
                attachment.vlmDescription,
            ].compactMap { $0 }
            if let match = fields.first(where: {
                $0.range(of: query, options: .caseInsensitive) != nil
            }) {
                return match
            }
            for summaryRecord in attachment.summaryRecords ?? [] {
                let fields = [summaryRecord.text, summaryRecord.topicTitle]
                    .compactMap { $0 }
                if let match = fields.first(where: {
                    $0.range(of: query, options: .caseInsensitive) != nil
                }) {
                    return match
                }
            }
        }
        return record.speakerNames.values.first {
            $0.range(of: query, options: .caseInsensitive) != nil
        }
    }

    static func match(
        _ record: SessionRecord, lowercasedQuery: String, haystack: String
    ) -> Match? {
        let count = occurrences(of: lowercasedQuery, in: haystack)
        guard count > 0 else { return nil }
        // The blob and the fields cover the same text, so a source always
        // exists; the title fallback only guards a query that straddles the
        // blob's field separator.
        let snippet = snippetSource(in: record, query: lowercasedQuery)
            .flatMap { Self.snippet(in: $0, query: lowercasedQuery) }
            ?? record.title
        return Match(
            sessionID: record.id,
            matchCount: count,
            snippet: snippet,
            firstEntryID: firstMatchingEntryID(in: record, query: lowercasedQuery))
    }
}

/// Per-keystroke search driver owning a lazily built haystack cache, so
/// typing doesn't re-join every session's transcript on each character.
@MainActor
final class SessionSearchIndex {
    private var blobs: [UUID: (fingerprint: String, blob: String)] = [:]

    func matches(in sessions: [SessionRecord], query: String) -> [SessionSearch.Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()
        return sessions.compactMap { record in
            let fingerprint = SessionSearch.fingerprint(of: record)
            let blob: String
            if let cached = blobs[record.id], cached.fingerprint == fingerprint {
                blob = cached.blob
            } else {
                blob = SessionSearch.haystack(for: record)
                blobs[record.id] = (fingerprint, blob)
            }
            return SessionSearch.match(record, lowercasedQuery: needle, haystack: blob)
        }
    }
}
