import Foundation

/// Remaining-time estimate for a long job reporting completion fractions.
/// Phase changes must `reset()` — each phase has its own 0…1 scale.
///
/// Qwen3-ASR progress is bursty: silence skips advance several percent in a
/// blink, then a minute-long decode barely moves. Two guards keep the
/// readout honest there (a 25-minute decode once opened with "~30 sec
/// left"): nothing shows until the phase has both run and progressed enough
/// to mean something, and the projected rate is the *lower* of a
/// time-weighted recent rate and the whole-phase average — bursts can't
/// promise a finish the long stretches won't deliver.
struct ProcessingETA {
    /// Recent-rate horizon: a burst `dt` seconds long can shift the smoothed
    /// rate by at most `1 - exp(-dt/tau)` of the way toward its rate.
    private static let tau: TimeInterval = 60
    /// No estimate until the phase has run this long…
    private static let warmupSeconds: TimeInterval = 20
    /// …and progressed this far. Both gates together: a fast first skip
    /// alone can't mint an estimate, nor can 20 idle seconds.
    private static let warmupProgress = 0.01
    /// Below this fraction/second the job is effectively stalled and an
    /// estimate would be nonsense (hours, growing) — report nothing.
    private static let minimumRate = 1e-5

    private var anchorFraction: Double?
    private var anchorAt: Date?
    private var lastFraction: Double?
    private var lastAt: Date?
    /// Fraction per second over roughly the last `tau` seconds.
    private var recentRate: Double?
    private(set) var remaining: TimeInterval?

    mutating func update(fraction: Double, at now: Date = .now) {
        guard let lastFraction, let lastAt, let anchorFraction, let anchorAt else {
            self.anchorFraction = fraction
            self.anchorAt = now
            self.lastFraction = fraction
            self.lastAt = now
            return
        }
        defer {
            self.lastFraction = fraction
            self.lastAt = now
        }
        let dt = now.timeIntervalSince(lastAt)
        let df = fraction - lastFraction
        guard dt > 0, df >= 0 else { return }

        // Time-weighted EMA: irregular callback cadence must not skew the
        // estimate — a flurry of tiny samples carries the weight of its
        // duration, not of its count.
        let alpha = 1 - exp(-dt / Self.tau)
        let sample = df / dt
        recentRate = recentRate.map { $0 + alpha * (sample - $0) } ?? sample

        let elapsed = now.timeIntervalSince(anchorAt)
        let progressed = max(0, fraction - anchorFraction)
        guard elapsed >= Self.warmupSeconds, progressed >= Self.warmupProgress else {
            remaining = nil
            return
        }
        let average = progressed / elapsed
        let rate = min(recentRate ?? average, average)
        remaining = rate >= Self.minimumRate ? (1 - fraction) / rate : nil
    }

    mutating func reset() {
        self = ProcessingETA()
    }

    /// "~4 min left" / "~30 sec left"; sub-minute estimates stay coarse —
    /// a counting-down seconds display would jitter with the decode bursts.
    static func text(remaining: TimeInterval) -> String {
        if remaining < 60 {
            return String(localized: "~30 sec left")
        }
        let minutes = Int((remaining / 60).rounded(.up))
        return String(localized: "~\(minutes) min left")
    }
}
