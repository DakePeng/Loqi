import ActivityKit
import Foundation

/// Thin ActivityKit wrapper for the recording Live Activity (lock screen +
/// Dynamic Island, rendered by the LoqiWidgets extension). Update traffic
/// is tiny by design: the elapsed timer is anchored text needing zero
/// updates, so only phase changes (pause/resume) post anything.
///
/// Holds the activity's id, never the Activity object: Activity is a
/// non-Sendable class, and a stored reference can't legally cross an await
/// under strict concurrency — fresh `Activity.activities` lookups can.
@MainActor
final class RecordingActivityController {
    private var activityID: String?
    private var lastState: RecordingActivityAttributes.ContentState?

    func start(startedAt: Date, title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingActivityAttributes.ContentState(
            statusLabel: String(localized: "Recording"), isPaused: false)
        let activity = try? Activity.request(
            attributes: RecordingActivityAttributes(
                startedAt: startedAt, sessionTitle: title),
            content: .init(state: state, staleDate: nil))
        activityID = activity?.id
        lastState = state
    }

    func update(statusLabel: String, isPaused: Bool) {
        guard let id = activityID else { return }
        let state = RecordingActivityAttributes.ContentState(
            statusLabel: statusLabel, isPaused: isPaused)
        guard state != lastState else { return }
        lastState = state
        Task { @MainActor in
            for activity in Activity<RecordingActivityAttributes>.activities
            where activity.id == id {
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }

    /// Shows `finalLabel` briefly, then dismisses.
    func end(finalLabel: String) {
        guard let id = activityID else { return }
        activityID = nil
        lastState = nil
        let state = RecordingActivityAttributes.ContentState(
            statusLabel: finalLabel, isPaused: false)
        Task { @MainActor in
            for activity in Activity<RecordingActivityAttributes>.activities
            where activity.id == id {
                await activity.end(
                    .init(state: state, staleDate: nil),
                    dismissalPolicy: .after(.now + 5))
            }
        }
    }

    /// A session killed mid-recording (jetsam, crash, force-quit) leaves a
    /// zombie "Recording" activity on the lock screen. Sweep at launch,
    /// before anything can start a new session.
    static func endAllStale() async {
        for stale in Activity<RecordingActivityAttributes>.activities {
            await stale.end(nil, dismissalPolicy: .immediate)
        }
    }
}
