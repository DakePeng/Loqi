import Foundation
import Translation

/// Tier-1 draft translation via the system Translation framework.
///
/// TranslationSession cannot be instantiated directly — the system delivers
/// it through the SwiftUI `.translationTask` modifier and it is only valid
/// while that view is attached. TranslationHostView captures the session and
/// parks it here; that is why this type is @MainActor.
///
/// Directions without a direct model (possibly zh↔ja) pivot through English:
/// source→en, then en→target, using two registered sessions.
/// TranslationSession is not Sendable, but Apple's API hands it to a
/// nonisolated SwiftUI task closure while translate calls must be issued
/// from our MainActor pipeline. The box confines every use of the session
/// to values that traveled with it, which is safe: the system session is
/// internally thread-safe and only invalid after its host view detaches.
struct TranslationSessionBox: @unchecked Sendable {
    let session: TranslationSession

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }

    /// Triggers the language-pack download UI if the pack is missing.
    func prepare() async throws {
        try await session.prepareTranslation()
    }
}

@MainActor
@Observable
final class TranslationCoordinator {
    private var sessions: [LanguagePair: TranslationSessionBox] = [:]
    /// Directions the UI must keep host views alive for.
    private(set) var requiredDirections: Set<LanguagePair> = []
    /// Pairs that runtime checks showed need the English pivot.
    private var pivotPairs: Set<LanguagePair> = []

    private var debounceTasks: [UUID: Task<Void, Never>] = [:]

    /// Pivot decision, injectable for tests (default: live AssetManager).
    private let needsPivot: (LanguagePair) async -> Bool

    init(needsPivot: ((LanguagePair) async -> Bool)? = nil) {
        if let needsPivot {
            self.needsPivot = needsPivot
        } else {
            let assets = AssetManager()
            self.needsPivot = { await assets.needsEnglishPivot(for: $0) }
        }
    }

    /// Declare which directions the current mode needs. Expands pivot pairs
    /// into their two English legs. The UI observes `requiredDirections`
    /// and mounts one TranslationHostView per element.
    func setDirections(_ directions: Set<LanguagePair>) async {
        var needed: Set<LanguagePair> = []
        for direction in directions where direction.source != direction.target {
            if await needsPivot(direction) {
                pivotPairs.insert(direction)
                needed.insert(LanguagePair(source: direction.source, target: .english))
                needed.insert(LanguagePair(source: .english, target: direction.target))
            } else {
                needed.insert(direction)
            }
        }
        requiredDirections = needed
        sessions = sessions.filter { needed.contains($0.key) }
    }

    /// Additively register one direction mid-session (turn switching can
    /// need a direction the session was not started with). The host stack
    /// observes `requiredDirections` and mounts the new session view.
    func addDirection(_ direction: LanguagePair) async {
        guard direction.source != direction.target,
              !requiredDirections.contains(direction),
              !pivotPairs.contains(direction) else { return }
        if await needsPivot(direction) {
            pivotPairs.insert(direction)
            requiredDirections.insert(LanguagePair(source: direction.source, target: .english))
            requiredDirections.insert(LanguagePair(source: .english, target: direction.target))
        } else {
            requiredDirections.insert(direction)
        }
    }

    /// Called by TranslationHostView when the system hands it a session.
    func register(session: TranslationSessionBox, for pair: LanguagePair) {
        sessions[pair] = session
    }

    func unregister(pair: LanguagePair) {
        sessions[pair] = nil
    }

    /// Translate finalized text immediately.
    func draft(_ text: String, direction: LanguagePair) async throws -> String {
        if pivotPairs.contains(direction) {
            let viaEnglish = try await translate(
                text, pair: LanguagePair(source: direction.source, target: .english))
            return try await translate(
                viaEnglish, pair: LanguagePair(source: .english, target: direction.target))
        }
        return try await translate(text, pair: direction)
    }

    /// Translate volatile text, debounced: a newer update for the same entry
    /// cancels the pending one, capping tier-1 calls at ~4/sec per entry.
    func draftDebounced(
        _ text: String,
        direction: LanguagePair,
        entryID: UUID,
        store: CaptionStore
    ) {
        debounceTasks[entryID]?.cancel()
        debounceTasks[entryID] = Task { [weak self, weak store] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, let store, !Task.isCancelled else { return }
            guard let translation = try? await self.draft(text, direction: direction),
                  !Task.isCancelled else { return }
            store.setDraft(translation, for: entryID)
            self.debounceTasks[entryID] = nil
        }
    }

    func cancelPending(entryID: UUID) {
        debounceTasks[entryID]?.cancel()
        debounceTasks[entryID] = nil
    }

    /// Sessions register asynchronously (SwiftUI mounts the host view a
    /// beat after a direction is required), so the first utterance of a
    /// session must wait briefly instead of failing instantly.
    private func awaitSession(
        _ pair: LanguagePair, timeout: Duration = .seconds(5)
    ) async throws -> TranslationSessionBox {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while sessions[pair] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let session = sessions[pair] else {
            throw TranslationCoordinatorError.sessionUnavailable(pair)
        }
        return session
    }

    private func translate(_ text: String, pair: LanguagePair) async throws -> String {
        let session = try await awaitSession(pair)
        do {
            return try await session.translate(text)
        } catch {
            // Session may have been invalidated by a view/config change;
            // retry once in case the host view re-registered a fresh one.
            try await Task.sleep(for: .milliseconds(200))
            guard let retrySession = sessions[pair] else { throw error }
            return try await retrySession.translate(text)
        }
    }
}

enum TranslationCoordinatorError: Error {
    case sessionUnavailable(LanguagePair)
}
