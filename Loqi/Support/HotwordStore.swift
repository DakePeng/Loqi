import Foundation
import Observation

/// User-managed hotword list with JSON persistence. The pipeline snapshots
/// `matcher` per utterance; edits notify `onChange` so live ASR sessions can
/// refresh their contextual strings.
///
/// Also holds the mined-suggestion inbox (`pending`): terms captured from
/// summary edits that the user confirms in the Vocabulary tab. Pending items
/// persist in their own file so hotwords.json keeps its plain `[Hotword]`
/// shape, and they don't fire `onChange` — only confirmed hotwords bias ASR.
@MainActor
@Observable
final class HotwordStore {
    private(set) var hotwords: [Hotword] = []
    /// Mined suggestions awaiting confirmation; drives the tab badge.
    private(set) var pending: [PendingHotword] = []

    /// Set by CaptionPipeline; fired after any mutation.
    @ObservationIgnored var onChange: (() -> Void)?

    private let directory: URL
    private var fileURL: URL { directory.appending(path: "hotwords.json") }
    private var pendingFileURL: URL {
        directory.appending(path: "hotword-suggestions.json")
    }

    private static let pendingLimit = 20
    private static let retirementDays = 14

    init(directory: URL = .applicationSupportDirectory) {
        self.directory = directory
        load()
        retireStale()
    }

    /// Immutable snapshot for use off the main actor.
    var matcher: HotwordMatcher { HotwordMatcher(hotwords: hotwords) }

    /// Strings to bias ASR recognition for one language. Apple guidance for
    /// contextual strings: keep the list modest.
    func biasStrings(for language: AppLanguage) -> [String] {
        var seen = Set<String>()
        var strings: [String] = []
        for hotword in hotwords {
            for form in hotword.recognitionForms(for: language)
            where seen.insert(form).inserted {
                strings.append(form)
            }
        }
        return Array(strings.prefix(100))
    }

    /// True when `term` matches any hotword's term, rendering, or alias
    /// (trimmed, case-insensitive).
    func isKnown(_ term: String) -> Bool {
        let needle = Self.normalized(term)
        guard !needle.isEmpty else { return false }
        return hotwords.contains { hotword in
            Self.normalized(hotword.term) == needle
                || hotword.renderings.values.contains { Self.normalized($0) == needle }
                || (hotword.aliases ?? []).contains { Self.normalized($0) == needle }
        }
    }

    private static func normalized(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Mutations

    func add(_ hotword: Hotword) {
        hotwords.append(hotword)
        prunePending()
        persist()
    }

    func update(_ hotword: Hotword) {
        guard let index = hotwords.firstIndex(where: { $0.id == hotword.id }) else { return }
        hotwords[index] = hotword
        prunePending()
        persist()
    }

    func remove(at offsets: IndexSet) {
        hotwords.remove(atOffsets: offsets)
        persist()
    }

    /// Silent capture for names the user just confirmed elsewhere (speaker
    /// rename). No-op for empty or already-known terms.
    @discardableResult
    func captureIfNew(term: String, note: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isKnown(trimmed) else { return false }
        add(Hotword(term: trimmed, note: note))
        return true
    }

    // MARK: Pending suggestions

    /// Queue mined suggestions, skipping known terms and duplicates already
    /// pending. The queue is capped; overflow is dropped, not rotated —
    /// stale unreviewed suggestions shouldn't churn. Tag the source session
    /// so the inbox can group the batch and offer "Ignore all".
    func enqueueSuggestions(
        _ items: [HotwordSuggestion],
        sessionID: UUID? = nil,
        sessionTitle: String? = nil
    ) {
        var changed = false
        for item in items {
            let trimmed = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard pending.count < Self.pendingLimit, !trimmed.isEmpty,
                  !isKnown(trimmed),
                  !pending.contains(where: {
                      Self.normalized($0.term) == Self.normalized(trimmed)
                  })
            else { continue }
            pending.append(PendingHotword(
                term: trimmed,
                renderings: item.renderings.isEmpty ? nil : item.renderings,
                note: item.note,
                sessionID: sessionID, sessionTitle: sessionTitle,
                createdAt: Date()))
            changed = true
        }
        if changed { persistPending() }
    }

    func enqueueSuggestions(
        _ items: [(term: String, note: String)],
        sessionID: UUID? = nil,
        sessionTitle: String? = nil
    ) {
        enqueueSuggestions(
            items.map { HotwordSuggestion(term: $0.term, note: $0.note) },
            sessionID: sessionID,
            sessionTitle: sessionTitle)
    }

    /// Promote a suggestion to a real hotword and remove it from the queue.
    func accept(_ suggestion: PendingHotword) {
        pending.removeAll { $0.id == suggestion.id }
        persistPending()
        // A raced manual add may have made it known meanwhile.
        guard !isKnown(suggestion.term) else { return }
        add(Hotword(
            term: suggestion.term,
            renderings: suggestion.renderings ?? [:],
            note: suggestion.note))
    }

    func dismiss(_ suggestion: PendingHotword) {
        pending.removeAll { $0.id == suggestion.id }
        persistPending()
    }

    /// Batch-ignore one session's mined batch (nil clears the untagged
    /// group — legacy items and sources without a session).
    func dismissAll(sessionID: UUID?) {
        let before = pending.count
        pending.removeAll { $0.sessionID == sessionID }
        guard pending.count != before else { return }
        persistPending()
    }

    /// A deleted session should not leave its mined recommendations behind
    /// in the Vocabulary inbox.
    func discardSuggestions(forSession sessionID: UUID) {
        dismissAll(sessionID: sessionID)
    }

    /// Drop suggestions that have sat unreviewed past the retirement window.
    /// Legacy items (nil createdAt) are exempt — we can't know their age.
    func retireStale(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(
            -Double(Self.retirementDays) * 86400)
        let before = pending.count
        pending.removeAll { suggestion in
            guard let created = suggestion.createdAt else { return false }
            return created < cutoff
        }
        if pending.count != before { persistPending() }
    }

    /// Suggestions made redundant by an add/update (manual entry, speaker
    /// rename) leave the queue so the badge stays honest.
    private func prunePending() {
        let stale = pending.filter { isKnown($0.term) }
        guard !stale.isEmpty else { return }
        pending.removeAll { suggestion in stale.contains { $0.id == suggestion.id } }
        persistPending()
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Hotword].self, from: data) {
            hotwords = decoded
        }
        if let data = try? Data(contentsOf: pendingFileURL),
           let decoded = try? JSONDecoder().decode([PendingHotword].self, from: data) {
            pending = decoded
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(hotwords) {
            try? data.write(to: fileURL, options: .atomic)
        }
        onChange?()
    }

    private func persistPending() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: pendingFileURL, options: .atomic)
        }
    }
}
