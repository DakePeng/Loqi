import Foundation
import Testing
@testable import Loqi

@MainActor
struct SerialGateTests {
    /// Spin (yielding, no fixed sleeps) until `cond` holds, so the async
    /// waiters have reached their continuation before we assert.
    private func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<10_000 {
            if cond() { return }
            await Task.yield()
        }
        Issue.record("condition never met")
    }

    @Test func runsOneAtATimeInFIFOOrder() async {
        let gate = SerialGate()
        try? await gate.acquire() // holder occupies the slot

        var order: [Int] = []
        let t1 = Task { @MainActor in
            try? await gate.acquire(); order.append(1); gate.release()
        }
        await waitUntil { gate.waiterCount == 1 }
        let t2 = Task { @MainActor in
            try? await gate.acquire(); order.append(2); gate.release()
        }
        await waitUntil { gate.waiterCount == 2 }

        #expect(order.isEmpty) // both blocked behind the holder

        gate.release()         // hand to t1, which hands to t2
        await t1.value
        await t2.value
        #expect(order == [1, 2])
    }

    @Test func cancelWhileQueuedDropsOut() async {
        let gate = SerialGate()
        try? await gate.acquire()

        var ran = false
        let queued = Task { @MainActor in
            do { try await gate.acquire(); ran = true; gate.release() }
            catch { /* cancelled before owning the slot */ }
        }
        await waitUntil { gate.waiterCount == 1 }
        queued.cancel()
        await waitUntil { gate.waiterCount == 0 } // left the line

        gate.release()         // holder releases; nothing should be waiting
        await queued.value
        #expect(ran == false)
    }

    @Test func waitUntilIdleResolvesAfterDrain() async {
        let gate = SerialGate()
        try? await gate.acquire() // busy

        var idle = false
        let waiter = Task { @MainActor in
            await gate.waitUntilIdle(); idle = true
        }
        await waitUntil { gate.waiterCount == 1 } // parked behind the holder
        #expect(idle == false)

        gate.release()         // hand to the idle-waiter, which releases at once
        await waiter.value
        #expect(idle)
    }
}
