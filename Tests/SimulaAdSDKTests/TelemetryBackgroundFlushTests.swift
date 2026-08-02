import XCTest
@testable import SimulaAdSDK

final class TelemetryBackgroundFlushTests: XCTestCase {
    func testFlushRunsWhenTheNotificationFires() {
        let center = NotificationCenter()
        let flushes = LockedFlushCounter()
        let hook = TelemetryBackgroundFlush()
        hook.install(center: center, name: .init("test.background"), flush: { request in
            flushes.increment()
            request.finish()
        })

        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(flushes.value, 1)

        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(flushes.value, 2)
    }

    func testInstallIsIdempotent() {
        let center = NotificationCenter()
        let flushes = LockedFlushCounter()
        let hook = TelemetryBackgroundFlush()
        hook.install(center: center, name: .init("test.background"), flush: { flushes.increment(); $0.finish() })
        hook.install(center: center, name: .init("test.background"), flush: { flushes.increment(); $0.finish() })

        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(flushes.value, 1) // first-wins: exactly one observer registered
    }

    func testUnrelatedNotificationsDoNotFlush() {
        let center = NotificationCenter()
        let flushes = LockedFlushCounter()
        let hook = TelemetryBackgroundFlush()
        hook.install(center: center, name: .init("test.background"), flush: { flushes.increment(); $0.finish() })

        center.post(name: .init("test.foreground"), object: nil)
        XCTAssertEqual(flushes.value, 0)
    }

    func testBackgroundTaskEndsOnceWhenCompletionAndExpirationRace() {
        let center = NotificationCenter()
        let callbacks = LockedBackgroundCallbacks()
        let ends = LockedFlushCounter()
        let hook = TelemetryBackgroundFlush()
        hook.install(
            center: center,
            name: .init("test.background"),
            beginBackgroundTask: { expiration in
                callbacks.setExpiration(expiration)
                return { ends.increment() }
            },
            flush: { request in callbacks.setCompletion { request.finish() } }
        )

        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(ends.value, 0)

        callbacks.complete()
        callbacks.complete()
        callbacks.expire()
        XCTAssertEqual(ends.value, 1)
    }

    func testExpirationBeforeBeginReturnsStillEndsOnce() {
        let center = NotificationCenter()
        let ends = LockedFlushCounter()
        let hook = TelemetryBackgroundFlush()
        hook.install(
            center: center,
            name: .init("test.background"),
            beginBackgroundTask: { expiration in
                expiration()
                return { ends.increment() }
            },
            flush: { $0.finish() }
        )

        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(ends.value, 1)
    }

    func testRepeatedNotificationsCoalesceWhileAFlushIsPending() {
        let center = NotificationCenter()
        let begins = LockedFlushCounter()
        let flushes = LockedFlushCounter()
        let callbacks = LockedBackgroundCallbacks()
        let hook = TelemetryBackgroundFlush()
        hook.install(
            center: center,
            name: .init("test.background"),
            beginBackgroundTask: { _ in
                begins.increment()
                return {}
            },
            flush: { request in
                flushes.increment()
                callbacks.setCompletion { request.finish() }
            }
        )

        center.post(name: .init("test.background"), object: nil)
        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(begins.value, 1)
        XCTAssertEqual(flushes.value, 1)

        callbacks.complete()
        center.post(name: .init("test.background"), object: nil)
        XCTAssertEqual(begins.value, 2)
        XCTAssertEqual(flushes.value, 2)
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

private final class LockedBackgroundCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var expiration: (@Sendable () -> Void)?
    private var completion: (@Sendable () -> Void)?

    func setExpiration(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); expiration = callback; lock.unlock()
    }

    func setCompletion(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); completion = callback; lock.unlock()
    }

    func expire() {
        lock.lock(); let callback = expiration; lock.unlock()
        callback?()
    }

    func complete() {
        lock.lock(); let callback = completion; lock.unlock()
        callback?()
    }
}
