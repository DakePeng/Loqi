import Foundation

/// User preference for summary detail. The engine still scales the final
/// budget by transcript size, then clamps it to device-safe caps.
enum SummaryLength: String, Codable, CaseIterable, Identifiable, Sendable {
    case concise
    case standard
    case detailed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .concise: String(localized: "Concise")
        case .standard: String(localized: "Standard")
        case .detailed: String(localized: "Detailed")
        }
    }

    var symbolName: String {
        switch self {
        case .concise: "text.line.first.and.arrowtriangle.forward"
        case .standard: "text.alignleft"
        case .detailed: "text.justify.left"
        }
    }
}

struct SummaryPromptSizing: Equatable, Sendable {
    var maxTokens: Int
    var overviewCap: Int
    var sectionCaps: [Int]
}
