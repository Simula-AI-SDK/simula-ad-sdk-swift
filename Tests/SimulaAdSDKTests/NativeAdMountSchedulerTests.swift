import XCTest
@testable import SimulaAdSDK

@MainActor
final class NativeAdMountSchedulerTests: XCTestCase {
    private final class ManualFrameClock {
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var waiterCount: Int { waiters.count }

        func waitForFrame() async {
            await withCheckedContinuation { waiters.append($0) }
        }

        func advance() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume()
        }
    }

    func testAdmitsAtMostOneRequestPerFrameInQueueOrder() async {
        let clock = ManualFrameClock()
        let scheduler = NativeAdMountScheduler(waitForNextFrame: { await clock.waitForFrame() })
        var admitted: [Int] = []

        let first = Task { @MainActor in
            if await scheduler.waitForAdmission() { admitted.append(1) }
        }
        await waitUntil { scheduler.pendingCount == 1 && clock.waiterCount == 1 }

        let second = Task { @MainActor in
            if await scheduler.waitForAdmission() { admitted.append(2) }
        }
        await waitUntil { scheduler.pendingCount == 2 }

        let third = Task { @MainActor in
            if await scheduler.waitForAdmission() { admitted.append(3) }
        }
        await waitUntil { scheduler.pendingCount == 3 }

        clock.advance()
        await waitUntil { admitted == [1] && scheduler.pendingCount == 2 && clock.waiterCount == 1 }
        clock.advance()
        await waitUntil { admitted == [1, 2] && scheduler.pendingCount == 1 && clock.waiterCount == 1 }
        clock.advance()

        await first.value
        await second.value
        await third.value
        XCTAssertEqual(admitted, [1, 2, 3])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testCancellationRemovesQueuedRequestBeforeAdmission() async {
        let clock = ManualFrameClock()
        let scheduler = NativeAdMountScheduler(waitForNextFrame: { await clock.waitForFrame() })
        var admitted = false

        let request = Task { @MainActor in
            admitted = await scheduler.waitForAdmission()
        }
        await waitUntil { scheduler.pendingCount == 1 && clock.waiterCount == 1 }

        request.cancel()
        await request.value

        XCTAssertFalse(admitted)
        XCTAssertEqual(scheduler.pendingCount, 0)

        // The already-scheduled frame may still arrive, but it must not admit the canceled request.
        clock.advance()
        await Task.yield()
        XCTAssertFalse(admitted)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}
