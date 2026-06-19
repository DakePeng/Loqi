import Foundation
import Testing

@testable import Loqi

struct RefinementGateTests {
    @Test func forcedAlwaysRefines() {
        #expect(RefinementGate.shouldRefine(
            textLength: 0,
            forced: true,
            thermalState: .critical,
            reduceHeat: true))
    }

    @Test func shortUtterancesSkipWhenNotForced() {
        #expect(!RefinementGate.shouldRefine(
            textLength: 11,
            forced: false,
            thermalState: .nominal,
            reduceHeat: false))
        #expect(RefinementGate.shouldRefine(
            textLength: 12,
            forced: false,
            thermalState: .nominal,
            reduceHeat: false))
    }

    @Test func fairThermalStateRaisesThreshold() {
        #expect(!RefinementGate.shouldRefine(
            textLength: 12,
            forced: false,
            thermalState: .fair,
            reduceHeat: false))
        #expect(RefinementGate.shouldRefine(
            textLength: 24,
            forced: false,
            thermalState: .fair,
            reduceHeat: false))
    }

    @Test func reduceHeatRaisesThreshold() {
        #expect(!RefinementGate.shouldRefine(
            textLength: 12,
            forced: false,
            thermalState: .nominal,
            reduceHeat: true))
        #expect(RefinementGate.shouldRefine(
            textLength: 24,
            forced: false,
            thermalState: .nominal,
            reduceHeat: true))
    }

    @Test func seriousAndCriticalSkipUnforcedRefinement() {
        #expect(!RefinementGate.shouldRefine(
            textLength: 100,
            forced: false,
            thermalState: .serious,
            reduceHeat: false))
        #expect(!RefinementGate.shouldRefine(
            textLength: 100,
            forced: false,
            thermalState: .critical,
            reduceHeat: false))
    }
}
