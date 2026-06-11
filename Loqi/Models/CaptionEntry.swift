import Foundation

/// Which app surface a transcript entry belongs to. Captions and
/// Conversation share one pipeline but must not leak entries into each
/// other's UI ("Clear" in one must not wipe the other).
enum SessionMode: String, Sendable, Codable {
    case captions
    case conversation
}

/// One utterance in the transcript. The `id` stays stable while ASR keeps
/// revising the volatile text, so SwiftUI updates the row in place instead
/// of inserting new rows.
struct CaptionEntry: Identifiable, Sendable, Equatable {
    enum State: Sendable, Equatable {
        /// ASR is still revising this text.
        case volatile
        /// ASR finalized the text; tier-2 refinement may still be pending.
        case finalized
        /// The LLM is currently refining the draft translation.
        case refining
        /// Refinement finished (or was skipped permanently).
        case refined
    }

    let id: UUID
    var sourceText: String
    /// Tier-1 NMT translation. Shown as soon as it exists.
    var draftTranslation: String?
    /// Tier-2 LLM translation. Replaces the draft when present.
    var refinedTranslation: String?
    var state: State
    var direction: LanguagePair
    var mode: SessionMode
    /// Diarization slot (0-based) when captions-mode speaker grouping is on.
    var speaker: Int?
    /// Tier-1 translation failed (e.g. language pack missing offline);
    /// the UI shows an unavailable state instead of a spinner.
    var draftFailed = false
    /// Original ASR text when the LLM polished sourceText — the truthful
    /// record stays recoverable (and exported).
    var rawSourceText: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceText: String = "",
        direction: LanguagePair,
        mode: SessionMode = .captions,
        state: State = .volatile,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceText = sourceText
        self.direction = direction
        self.mode = mode
        self.state = state
        self.createdAt = createdAt
    }

    /// What the UI should show as the translation right now.
    var displayTranslation: String? { refinedTranslation ?? draftTranslation }
}
