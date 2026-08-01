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
