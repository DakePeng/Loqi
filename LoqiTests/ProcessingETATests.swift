import Foundation
import Testing
@testable import Loqi

struct ProcessingETATests {
    private func at(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    @Test func noEstimateBeforeTwoSamples() {
        var eta = ProcessingETA()
        eta.update(fraction: 0.1, at: at(0))
        #expect(eta.remaining == nil)
    }

    @Test func warmupGatesEarlyEstimates() {
        var eta = ProcessingETA()
        // Healthy steady progress, but the phase is only 10 seconds old —
        // too early to promise anything.
        for second in stride(from: 0.0, through: 10, by: 2) {
            eta.update(fraction: second * 0.01, at: at(second))
        }
        #expect(eta.remaining == nil)
    }

    @Test func steadyRateProjectsRemaining() throws {
        var eta = ProcessingETA()
        // 1%/second: at t=30 (past warm-up), 70% left → ~70 seconds.
        for second in stride(from: 0.0, through: 30, by: 2) {
            eta.update(fraction: second * 0.01, at: at(second))
        }
        let remaining = try #require(eta.remaining)
        #expect(abs(remaining - 70) < 5)
    }

    /// The reported failure: a silence-skip burst opened a ~25-minute decode
    /// with "~30 sec left". The burst rate must not survive the blend with
    /// the phase average.
    @Test func openingBurstCannotPromiseAQuickFinish() throws {
        var eta = ProcessingETA()
        // 5% in the first two seconds…
        eta.update(fraction: 0, at: at(0))
        eta.update(fraction: 0.05, at: at(2))
        // …then the real pace: 1% per 15 seconds.
        var fraction = 0.05
        var time = 2.0
        while time < 62 {
            time += 15
            fraction += 0.01
            eta.update(fraction: fraction, at: at(time))
        }
        let remaining = try #require(eta.remaining)
        // True remaining at ~9% done and 1%/15s is ~22 min. The old
        // estimator said ~38s here; anything under 5 min would still be
        // burst-poisoned.
        #expect(remaining > 300)
    }

    @Test func remainingShrinksUnderSteadyProgress() {
        var eta = ProcessingETA()
        var previous = TimeInterval.infinity
        for second in stride(from: 0.0, through: 90, by: 5) {
            eta.update(fraction: second * 0.01, at: at(second))
            if let remaining = eta.remaining {
                #expect(remaining <= previous + 0.001)
                previous = remaining
            }
        }
        #expect(previous < .infinity, "estimate should appear after warm-up")
    }

    @Test func resumedPhaseAnchorsAtItsStartingFraction() throws {
        var eta = ProcessingETA()
        // Joining at 60% must not count the first 60% as instant progress.
        for second in stride(from: 0.0, through: 30, by: 5) {
            eta.update(fraction: 0.6 + second * 0.001, at: at(second))
        }
        let remaining = try #require(eta.remaining)
        // 0.1%/s with 37% left → ~370 seconds.
        #expect(abs(remaining - 370) < 30)
    }

    @Test func resetForgetsTheOldPhase() {
        var eta = ProcessingETA()
        for second in stride(from: 0.0, through: 30, by: 5) {
            eta.update(fraction: second * 0.01, at: at(second))
        }
        #expect(eta.remaining != nil)
        eta.reset()
        #expect(eta.remaining == nil)
        eta.update(fraction: 0.1, at: at(31))
        #expect(eta.remaining == nil)   // one sample into the new phase
    }

    @Test func stalledProgressReportsNothing() {
        var eta = ProcessingETA()
        // Identical fractions → zero rate → no nonsense hours-long ETA.
        for second in stride(from: 0.0, through: 60, by: 5) {
            eta.update(fraction: 0.3, at: at(second))
        }
        #expect(eta.remaining == nil)
    }

    @Test func longStallAfterProgressDropsTheEstimate() {
        var eta = ProcessingETA()
        for second in stride(from: 0.0, through: 30, by: 5) {
            eta.update(fraction: second * 0.01, at: at(second))
        }
        #expect(eta.remaining != nil)
        // Ten minutes frozen: both the recent rate and the phase average
        // decay until no honest estimate is left.
        for second in stride(from: 40.0, through: 630, by: 10) {
            eta.update(fraction: 0.3, at: at(second))
        }
        #expect(eta.remaining == nil)
    }
}
