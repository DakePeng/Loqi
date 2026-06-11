import Foundation
import Observation

/// Single source of truth for the transcript the UI renders.
/// All pipeline stages funnel their mutations through here on the main actor.
/// Entries are tagged by SessionMode so Captions and Conversation never leak
/// into each other's UI, and old entries are pruned so day-long sessions
/// can't grow memory without bound.
@MainActor
@Observable
final class CaptionStore {
    private(set) var entries: [CaptionEntry] = []

    /// Entry currently receiving volatile updates, if any.
    private(set) var activeEntryID: UUID?

    /// Mode stamped onto new entries; the pipeline sets this per session.
    var currentMode: SessionMode = .captions

    /// Pruning bounds: when entries exceed `maxEntries`, the oldest are
    /// dropped down to `prunedEntries`. Saved-sessions (roadmap) should
    /// persist before pruning.
    private let maxEntries = 600
    private let prunedEntries = 500

    func entries(in mode: SessionMode) -> [CaptionEntry] {
        entries.filter { $0.mode == mode }
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
        var entry = CaptionEntry(sourceText: text, direction: direction, mode: currentMode)
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

    /// LLM transcript polish: replace the displayed source, preserving the
    /// raw ASR text for fidelity.
    func applyCleanedSource(_ cleaned: String, for id: UUID) {
        guard let index = index(of: id), entries[index].sourceText != cleaned else { return }
        if entries[index].rawSourceText == nil {
            entries[index].rawSourceText = entries[index].sourceText
        }
        entries[index].sourceText = cleaned
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

    /// Recent completed turns of the current mode, oldest first, for the
    /// LLM prompt — context must not mix modes.
    func recentHistory(limit: Int) -> [CaptionEntry] {
        entries
            .filter {
                $0.mode == currentMode && $0.state != .volatile
                    && $0.displayTranslation != nil
            }
            .suffix(limit)
    }

    func entry(for id: UUID) -> CaptionEntry? {
        index(of: id).map { entries[$0] }
    }

    /// Clear one surface's transcript without touching the other's.
    func clear(_ mode: SessionMode) {
        if let id = activeEntryID, entry(for: id)?.mode == mode {
            activeEntryID = nil
        }
        entries.removeAll { $0.mode == mode }
    }

    private func prune() {
        guard entries.count > maxEntries else { return }
        entries.removeFirst(entries.count - prunedEntries)
    }

    private func index(of id: UUID) -> Int? {
        // Volatile updates always touch the newest entries; search from the end.
        entries.lastIndex { $0.id == id }
    }
}
