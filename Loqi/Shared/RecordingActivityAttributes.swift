#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity state for a recording session. Compiled into BOTH the app
/// and the widget extension — keep it free of app types and imports beyond
/// ActivityKit/Foundation. Strings arrive pre-rendered (and pre-localized)
/// from the app; elapsed time renders via Text(timerInterval:) anchored on
/// `startedAt`, costing zero activity updates.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Pre-localized status line ("Recording" / "Paused" / "Saved").
        var statusLabel: String
        /// Drives the icon/tint (interruption: another app took the mic).
        var isPaused: Bool
    }

    /// Session start — the elapsed timer anchors here.
    var startedAt: Date
    /// Pre-rendered language label ("中文 → English", or "中文" when
    /// transcribe-only).
    var sessionTitle: String
}
#endif
