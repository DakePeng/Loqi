import Foundation
import Testing

@testable import Loqi

struct ThermalMonitorTests {
    @Test func appendKeepsNewestWithinLimit() {
        var log: [ThermalMonitor.Transition] = []
        let base = Date(timeIntervalSince1970: 0)
        for i in 0..<25 {
            log = ThermalMonitor.appendTransition(
                .init(state: .nominal, at: base.addingTimeInterval(Double(i))),
                to: log, limit: 20)
        }
        #expect(log.count == 20)
        #expect(log.first?.at == base.addingTimeInterval(5))
        #expect(log.last?.at == base.addingTimeInterval(24))
    }

    @Test func appendUnderLimitGrows() {
        var log: [ThermalMonitor.Transition] = []
        log = ThermalMonitor.appendTransition(
            .init(state: .serious, at: Date(timeIntervalSince1970: 1)), to: log, limit: 20)
        #expect(log.count == 1)
        #expect(log.first?.state == .serious)
    }
}
