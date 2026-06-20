import Foundation
import Observation

/// Single source of truth for the transcript the UI renders.
/// All pipeline stages funnel their mutations through here on the main actor.
/// The render window is bounded so day-long sessions can't grow the
/// re-grouping cost (or memory) without bound. Entries pushed out of the
/// window are handed to `onEvict` first, so the owner can retain them for
/// archival rather than losing the transcript.
@MainActor
@Observable
final class CaptionStore {
    private(set) var entries: [CaptionEntry] = [] {
        didSet { cachedSegments = nil }
    }

    @ObservationIgnored private var cachedSegments: [CaptionSegment]?

    /// Entry currently receiving volatile updates, if any.
    private(set) var activeEntryID: UUID?

    /// Delivered the finalized entries pruning drops from the render window,
    /// oldest-first, BEFORE they leave the store — the owner (CaptionPipeline)
    /// retains them so the archived transcript and crash journal stay complete
    /// on sessions longer than `maxEntries` utterances. Infrastructure, not
    /// rendered state.
    @ObservationIgnored var onEvict: (([CaptionEntry]) -> Void)?

    /// Render-window bounds: when entries exceed `maxEntries`, the oldest are
    /// dropped down to `prunedEntries`. Dropped entries are handed to
    /// `onEvict` so they're persisted, never silently lost.
    private let maxEntries = 600
    private let prunedEntries = 500

    func segments() -> [CaptionSegment] {
        if let cached = cachedSegments { return cached }
        let built = CaptionGrouping.segments(from: entries)
        cachedSegments = built
        return built
    }

    // MARK: Volatile lifecycle

    /// Create or update the in-flight entry with new volatile ASR text.
    /// Returns the entry's stable id so downstream stages can reference it.
    @discardableResult
    func applyVolatile(text: String, direction: LanguagePair) -> UUID {
        if let id = activeEntryID, let index = index(of: id) {
            entries[index].sourceText = text
            if entries[index].direction != direction {
                entries[index].direction = direction
            }
            return id
        }
        var entry = CaptionEntry(sourceText: text, direction: direction)
        entry.state = .volatile
        entries.append(entry)
        prune()
        activeEntryID = entry.id
        return entry.id
    }

    /// Freeze the in-flight entry with its final text. Returns the frozen
    /// entry (for the refinement queue), or nil if there was none.
    @discardableResult
    func finalizeActive(text: String, direction: LanguagePair) -> CaptionEntry? {
        let id = applyVolatile(text: text, direction: direction)
        guard let index = index(of: id) else { return nil }
        entries[index].state = .finalized
        activeEntryID = nil
        return entries[index]
    }

    /// Finalize the active volatile entry as the first part of a speaker
    /// split, then append finalized entries for the remaining parts — one ASR
    /// utterance whose speaker changed midway becomes several captions. The
    /// UI already groups consecutive entries by speaker, so the parts render
    /// as distinct bubbles. Returns the parts in order (for the pipeline's
    /// per-entry translation/refinement/notes).
    @discardableResult
    func finalizeActiveSplit(
        parts: [(text: String, speaker: Int?, offset: TimeInterval)],
        direction: LanguagePair
    ) -> [CaptionEntry] {
        guard let firstPart = parts.first,
              let first = finalizeActive(text: firstPart.text, direction: direction)
        else { return [] }
        if let speaker = firstPart.speaker { setSpeaker(speaker, for: first.id) }
        var result = [entry(for: first.id) ?? first]
        let baseDate = first.createdAt
        for part in parts.dropFirst() {
            var entry = CaptionEntry(
                sourceText: part.text,
                direction: direction,
                state: .finalized,
                createdAt: baseDate.addingTimeInterval(part.offset))
            entry.speaker = part.speaker
            entries.append(entry)
            result.append(entry)
        }
        prune()
        return result
    }

    /// Drop an empty in-flight entry (e.g. turn ended with no speech).
    func discardActiveIfEmpty() {
        guard let id = activeEntryID, let index = index(of: id),
              entries[index].sourceText.isEmpty else { return }
        entries.remove(at: index)
        activeEntryID = nil
    }

    /// Turn teardown: freeze whatever volatile text exists so the next
    /// turn can never adopt this entry and overwrite its text/direction.
    /// Empty entries are dropped. Returns the frozen entry, if any.
    @discardableResult
    func finalizeActiveAsIs() -> CaptionEntry? {
        guard let id = activeEntryID else { return nil }
        defer { activeEntryID = nil }
        guard let index = index(of: id) else { return nil }
        guard !entries[index].sourceText.isEmpty else {
            entries.remove(at: index)
            return nil
        }
        guard entries[index].state == .volatile else { return nil }
        entries[index].state = .finalized
        return entries[index]
    }

    // MARK: Translation results

    func setDraft(_ translation: String, for id: UUID) {
        guard let index = index(of: id) else { return }
        entries[index].draftTranslation = translation
        entries[index].draftFailed = false
    }

    func markDraftFailed(_ id: UUID) {
        guard let index = index(of: id) else { return }
        entries[index].draftFailed = true
    }

    func setSpeaker(_ speaker: Int, for id: UUID) {
        guard let index = index(of: id) else { return }
        entries[index].speaker = speaker
    }

    func markRefining(_ id: UUID) {
        guard let index = index(of: id), entries[index].state == .finalized else { return }
        entries[index].state = .refining
    }

    func setRefined(_ translation: String?, for id: UUID) {
        guard let index = index(of: id) else { return }
        if let translation { entries[index].refinedTranslation = translation }
        entries[index].state = .refined
    }

    // MARK: Refinement context

    /// Recent completed turns, oldest first, for the LLM prompt.
    func recentHistory(limit: Int) -> [CaptionEntry] {
        entries
            .filter { $0.state != .volatile && $0.displayTranslation != nil }
            .suffix(limit)
    }

    func entry(for id: UUID) -> CaptionEntry? {
        index(of: id).map { entries[$0] }
    }

    func clear() {
        activeEntryID = nil
        entries.removeAll()
    }

    private func prune() {
        guard entries.count > maxEntries else { return }
        let dropCount = entries.count - prunedEntries
        // Hand the evicted (always-finalized; the volatile entry is newest)
        // transcript to the owner before dropping it, or long sessions lose
        // their opening on archive.
        let evicted = Array(entries.prefix(dropCount))
        entries.removeFirst(dropCount)
        onEvict?(evicted)
    }

    private func index(of id: UUID) -> Int? {
        // Volatile updates always touch the newest entries; search from the end.
        entries.lastIndex { $0.id == id }
    }
}
