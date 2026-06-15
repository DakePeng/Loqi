import UIKit

/// Best-effort extra runtime when the app backgrounds mid-job: a UIKit
/// background task buys ~30 seconds before suspension freezes the work
/// (it resumes on foreground — transcription is pure computation). Each
/// job holds one grace for its whole lifetime; `end()` is idempotent and
/// the expiration handler ends synchronously, as the watchdog demands.
@MainActor
final class BackgroundTaskGrace {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
