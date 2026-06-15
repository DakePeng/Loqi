import Foundation

/// Recording state shared with the widget extension through the app group:
/// the Control Center toggle reads it to render on/off without launching
/// the app. Compiled into both targets — Foundation only.
struct RecordingSharedState: Codable, Equatable {
    var isRunning: Bool
    var startedAt: Date?

    static let suiteName = "group.com.kunzhipeng.loqi"
    static let key = "recording.sharedState"
    /// One control covers Control Center, the Lock Screen, and the Action
    /// Button (assigned in Settings).
    static let controlKind = "com.kunzhipeng.loqi.recording"

    /// Pure decode with a safe default — anything unreadable means "not
    /// recording", never a crash in the extension.
    static func decode(_ data: Data?) -> RecordingSharedState {
        guard let data,
              let state = try? JSONDecoder().decode(RecordingSharedState.self, from: data)
        else { return RecordingSharedState(isRunning: false, startedAt: nil) }
        return state
    }

    static func read() -> RecordingSharedState {
        decode(UserDefaults(suiteName: suiteName)?.data(forKey: key))
    }

    static func write(_ state: RecordingSharedState) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
