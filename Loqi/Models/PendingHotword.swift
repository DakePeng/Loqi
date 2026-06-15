import Foundation

/// A mined vocabulary suggestion awaiting user confirmation in the
/// Vocabulary tab. Persisted in hotword-suggestions.json, separate from
/// hotwords.json so that file keeps its plain `[Hotword]` shape.
struct PendingHotword: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var term: String
    var note: String = ""
    /// Where the suggestion was mined, so the inbox can group one session's
    /// batch and offer "Ignore all". Optional: suggestions persisted before
    /// this field (and any future untagged source) stay loadable.
    var sessionID: UUID?
    /// Title snapshot for the group header — the session may be renamed or
    /// deleted later, and the inbox has no archive access.
    var sessionTitle: String?
    /// When the suggestion was mined. Nil for legacy items persisted before
    /// this field existed — those are exempt from auto-retirement.
    var createdAt: Date?
}
