import Foundation
import Observation

/// Watches thermal state and decides which pipeline tiers may run.
/// Degradation order: tier-2 refinement first, then the LLM itself.
/// ASR and tier-1 drafts are never sacrificed.
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

    /// Don't re-enable tier-2 until we've been cool for this long.
    private let recoveryHysteresis: Duration = .seconds(60)
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
        thermalState = state
        switch state {
        case .critical:
            cancelRecovery()
            policy = .llmUnloaded
        case .serious:
            cancelRecovery()
            // Never upgrade from llmUnloaded directly; recovery handles that.
            if policy == .full { policy = .refinementPaused }
        case .nominal, .fair:
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
