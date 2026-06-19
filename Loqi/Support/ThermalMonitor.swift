import Foundation
import Observation

/// Watches thermal state and decides which pipeline tiers may run.
/// Degradation order: tier-2 refinement first, then the LLM itself.
/// ASR and tier-1 drafts are never sacrificed. Downgrades are slow on
/// purpose (`.serious` must persist for a dwell) and `.critical` is
/// immediate; upgrades wait out a cool-down hysteresis.
@MainActor
@Observable
final class ThermalMonitor {
    enum Policy: Sendable, Equatable {
        /// Full pipeline.
        case full
        /// Tier-2 paused, model stays loaded.
        case refinementPaused
        /// LLM unloaded entirely; ASR + tier-1 only.
        case llmUnloaded
    }

    private(set) var policy: Policy = .full
    private(set) var thermalState = ProcessInfo.processInfo.thermalState

    struct Transition: Equatable, Sendable {
        let state: ProcessInfo.ThermalState
        let at: Date
    }

    /// Recent thermal-state changes for the Diagnostics screen (newest last).
    private(set) var transitions: [Transition] = []

    /// Pure ring-append: keep the newest `limit` transitions. Static so it's
    /// testable without the live notification stream.
    nonisolated static func appendTransition(
        _ transition: Transition, to log: [Transition], limit: Int = 20
    ) -> [Transition] {
        var next = log
        next.append(transition)
        if next.count > limit { next.removeFirst(next.count - limit) }
        return next
    }

    /// Don't pause tier-2 until `.serious` has persisted this long. iPhones
    /// tick into `.serious` during transient bursts (LLM load, a summary
    /// reduce) and recover on their own; reacting to the first notification
    /// paused refinement far too eagerly.
    private let seriousDwell: Duration = .seconds(60)
    /// Don't re-enable tier-2 until we've been cool for this long.
    private let recoveryHysteresis: Duration = .seconds(60)
    private var pauseTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?

    init() {
        observation = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: ProcessInfo.thermalStateDidChangeNotification)
            for await _ in notifications {
                guard let self else { return }
                self.apply(ProcessInfo.processInfo.thermalState)
            }
        }
        apply(ProcessInfo.processInfo.thermalState)
    }

    // No deinit: the monitor lives for the app's lifetime (owned by
    // CaptionPipeline), and a deinit cannot touch main-actor state.

    private func apply(_ state: ProcessInfo.ThermalState) {
        if state != thermalState {
            transitions = Self.appendTransition(.init(state: state, at: .now), to: transitions)
        }
        thermalState = state
        switch state {
        case .critical:
            cancelPendingPause()
            cancelRecovery()
            policy = .llmUnloaded
        case .serious:
            cancelRecovery()
            // Never upgrade from llmUnloaded directly; recovery handles that.
            schedulePauseAfterDwell()
        case .nominal, .fair:
            cancelPendingPause()
            scheduleRecovery()
        @unknown default:
            break
        }
    }

    /// Cancel AND nil — a cancelled task that stays referenced blocks
    /// `scheduleRecovery`'s guard forever, permanently disabling recovery.
    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    /// Same footgun as `cancelRecovery`: nil it or no pause can ever be
    /// scheduled again.
    private func cancelPendingPause() {
        pauseTask?.cancel()
        pauseTask = nil
    }

    /// Downgrade to refinementPaused only if `.serious` outlasts the dwell.
    /// A bounce back to fair/nominal cancels the pending pause, so a device
    /// oscillating at the boundary keeps its full pipeline.
    private func schedulePauseAfterDwell() {
        guard policy == .full, pauseTask == nil else { return }
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: self?.seriousDwell ?? .seconds(60))
            guard let self, !Task.isCancelled else { return }
            if ProcessInfo.processInfo.thermalState >= .serious, self.policy == .full {
                self.policy = .refinementPaused
            }
            self.pauseTask = nil
        }
    }

    private func scheduleRecovery() {
        guard policy != .full, recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: self?.recoveryHysteresis ?? .seconds(60))
            guard let self, !Task.isCancelled else { return }
            if ProcessInfo.processInfo.thermalState <= .fair {
                self.policy = .full
            }
            self.recoveryTask = nil
        }
    }
}

extension ProcessInfo.ThermalState: @retroactive Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
