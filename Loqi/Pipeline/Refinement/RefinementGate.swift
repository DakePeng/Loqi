import Foundation

enum RefinementGate {
    static let baseThreshold = 12
    static let throttledThreshold = 24

    static func shouldRefine(
        textLength: Int,
        forced: Bool,
        thermalState: ProcessInfo.ThermalState,
        reduceHeat: Bool
    ) -> Bool {
        if forced { return true }
        if thermalState >= .serious { return false }

        let threshold = (thermalState == .fair || reduceHeat) ? throttledThreshold : baseThreshold
        return textLength >= threshold
    }
}
