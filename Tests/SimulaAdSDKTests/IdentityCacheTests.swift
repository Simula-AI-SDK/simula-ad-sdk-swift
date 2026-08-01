import XCTest
@testable import SimulaAdSDK

private final class IdentityLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock(); storage = value; lock.unlock()
    }

    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}

final class IdentityCacheTests: XCTestCase {
    func testAPIReadsIdentityHeadersForEveryRequest() {
        let identityHeaders = IdentityLockedBox(["User-Agent": "fallback"])
        let api = SimulaAPI(session: URLSession(configuration: .ephemeral)) {
            identityHeaders.value
        }

        XCTAssertEqual(api.makeHeaders()["User-Agent"], "fallback")
        XCTAssertNil(api.makeHeaders()["X-Device-Id"])

        identityHeaders.set(["User-Agent": "resolved", "X-Device-Id": "device-123"])

        XCTAssertEqual(api.makeHeaders()["User-Agent"], "resolved")
        XCTAssertEqual(api.makeHeaders()["X-Device-Id"], "device-123")
    }

    func testDeviceIdSnapshotDoesNotWaitForResolver() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "resolver finished")
        let cache = SimulaDeviceIdCache {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            return "device-123"
        }

        DispatchQueue.global().async {
            _ = cache.resolve()
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        let before = DispatchTime.now().uptimeNanoseconds
        XCTAssertNil(cache.value)
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds &- before) / 1_000_000
        XCTAssertLessThan(elapsedMs, 50)

        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(cache.value, "device-123")
    }

    func testDeviceIdResolutionIsSingleFlightAndFailureIsRetryable() {
        let attempts = IdentityLockedBox(0)
        let cache = SimulaDeviceIdCache {
            let attempt = attempts.mutate { value in value += 1; return value }
            return attempt == 1 ? "" : "device-456"
        }

        XCTAssertNil(cache.resolve())
        XCTAssertEqual(cache.resolve(), "device-456")
        XCTAssertEqual(cache.resolve(), "device-456")
        XCTAssertEqual(attempts.value, 2)
    }

    // MARK: - Request-path retry (mirrors Kotlin DeviceIdPrimer cooldown semantics)

    func testRetrySchedulesResolveAfterFailureOnceCooldownElapses() {
        let now = IdentityLockedBox(TimeInterval(100))
        let attempts = IdentityLockedBox(0)
        let cache = SimulaDeviceIdCache(
            retryDelay: 30,
            now: { now.value },
            schedule: { work in work() } // synchronous: scheduled work runs inline in test
        ) {
            attempts.mutate { value in value += 1 }
            return ""
        }

        XCTAssertNil(cache.resolve()) // failed startup attempt arms the cooldown at t=130
        XCTAssertEqual(attempts.value, 1)

        now.set(160)
        cache.retryIfNeeded()
        XCTAssertEqual(attempts.value, 2)
    }

    func testRetryIsSuppressedWithinCooldownWindow() {
        let now = IdentityLockedBox(TimeInterval(100))
        let attempts = IdentityLockedBox(0)
        let cache = SimulaDeviceIdCache(
            retryDelay: 30,
            now: { now.value },
            schedule: { work in work() }
        ) {
            attempts.mutate { value in value += 1 }
            return ""
        }

        XCTAssertNil(cache.resolve()) // cooldown armed until t=130

        now.set(129)
        cache.retryIfNeeded()
        XCTAssertEqual(attempts.value, 1) // no new attempt inside the window
    }

    func testRetryNeverRunsResolverInline() {
        let attempts = IdentityLockedBox(0)
        let scheduled = IdentityLockedBox<[() -> Void]>([])
        let cache = SimulaDeviceIdCache(
            retryDelay: 30,
            now: { 0 },
            schedule: { work in scheduled.mutate { value in value.append(work) } }
        ) {
            attempts.mutate { value in value += 1 }
            return "device-789"
        }

        cache.retryIfNeeded()
        XCTAssertEqual(attempts.value, 0) // dispatch only — the caller's thread never resolves
        XCTAssertEqual(scheduled.value.count, 1)

        scheduled.value[0]()
        XCTAssertEqual(cache.value, "device-789")
    }

    func testRetryStopsAfterSuccessfulResolution() {
        let now = IdentityLockedBox(TimeInterval(100))
        let attempts = IdentityLockedBox(0)
        let cache = SimulaDeviceIdCache(
            retryDelay: 30,
            now: { now.value },
            schedule: { work in work() }
        ) {
            let attempt = attempts.mutate { value in value += 1; return value }
            return attempt == 1 ? "" : "device-abc"
        }

        XCTAssertNil(cache.resolve()) // attempt 1 fails, cooldown to t=130
        now.set(130)
        cache.retryIfNeeded() // attempt 2 succeeds
        XCTAssertEqual(cache.value, "device-abc")

        now.set(1000)
        cache.retryIfNeeded()
        cache.retryIfNeeded()
        XCTAssertEqual(attempts.value, 2) // cached value short-circuits all further retries
    }

    func testFailedStartupResolveArmsCooldownForRequestPathRetry() {
        let now = IdentityLockedBox(TimeInterval(50))
        let attempts = IdentityLockedBox(0)
        let cache = SimulaDeviceIdCache(
            retryDelay: 30,
            now: { now.value },
            schedule: { work in work() }
        ) {
            attempts.mutate { value in value += 1 }
            return ""
        }

        // Startup-style resolve fails at t=50 → next attempt allowed at t=80.
        XCTAssertNil(cache.resolve())
        now.set(79)
        cache.retryIfNeeded()
        XCTAssertEqual(attempts.value, 1)

        now.set(80)
        cache.retryIfNeeded()
        XCTAssertEqual(attempts.value, 2)
    }

    func testUserAgentSnapshotUsesFallbackWhileResolverRuns() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "UA resolver finished")
        let cache = SimulaUserAgentCache(fallback: "fallback") {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            return "full-user-agent"
        }

        DispatchQueue.global().async {
            _ = cache.resolve()
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cache.value, "fallback")
        XCTAssertEqual(cache.resolve(), "fallback")

        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(cache.value, "full-user-agent")
    }
}
