import XCTest
@testable import SimulaAdSDK

final class TelemetryBackgroundFlushTests: XCTestCase {
    func testFlushRunsWhenTheNotificationFires() {
        let center = NotificationCenter()
        let flushes = LockedFlushCounter()
        let hook = TelemetryBackgroundFlush()
        hook.install(center: center, name: .init("test.background"), flush: { flushes.increment() })

        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(flushes.value, 1)

        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(flushes.value, 2)
    }

    func testInstallIsIdempotent() {
        let center = NotificationCenter()
        let flushes = LockedFlushCounter()
        let hook = TelemetryBackgroundFlush()
        hook.install(center: center, name: .init("test.background"), flush: { flushes.increment() })
        hook.install(center: center, name: .init("test.background"), flush: { flushes.increment() })

        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(flushes.value, 1) // first-wins: exactly one observer registered
    }

    func testUnrelatedNotificationsDoNotFlush() {
        let center = NotificationCenter()
        let flushes = LockedFlushCounter()
        let hook = TelemetryBackgroundFlush()
        hook.install(center: center, name: .init("test.background"), flush: { flushes.increment() })

        center.post(name: .init("test.foreground"), object: nil)
        XCTAssertEqual(flushes.value, 0)
    }
}

private final class LockedFlushCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}
