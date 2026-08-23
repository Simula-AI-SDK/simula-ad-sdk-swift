import XCTest
@testable import SimulaAdSDK

final class SimulaDeviceIdTests: XCTestCase {
    func testResolvedOnlyAccessorDoesNotForceUnresolvedCache() {
        let resolver = DeviceIdResolverCounter(value: "device-1")
        let cache = SimulaDeviceIdCache { resolver.resolve() }

        XCTAssertNil(cache.valueIfResolved)
        XCTAssertEqual(resolver.count, 0)
    }

    func testResolvedOnlyAccessorReturnsCachedValue() {
        let resolver = DeviceIdResolverCounter(value: "device-1")
        let cache = SimulaDeviceIdCache { resolver.resolve() }

        XCTAssertEqual(cache.value, "device-1")
        XCTAssertEqual(cache.valueIfResolved, "device-1")
        XCTAssertEqual(resolver.count, 1)
    }

    func testResolvedOnlyAccessorDoesNotWaitForInProgressResolution() {
        let started = expectation(description: "resolver started")
        let completed = expectation(description: "forcing read completed")
        let release = DispatchSemaphore(value: 0)
        let cache = SimulaDeviceIdCache {
            started.fulfill()
            release.wait()
            return "device-1"
        }
        DispatchQueue.global(qos: .utility).async {
            _ = cache.value
            completed.fulfill()
        }
        wait(for: [started], timeout: 1)

        let before = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(cache.valueIfResolved)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - before, 0.1)

        release.signal()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(cache.valueIfResolved, "device-1")
    }

    func testForcingAccessorResolvesOnlyOnceAcrossConcurrentReaders() {
        let started = expectation(description: "resolver started")
        let release = DispatchSemaphore(value: 0)
        let resolver = DeviceIdResolverCounter(value: "device-1")
        let cache = SimulaDeviceIdCache {
            let value = resolver.resolve()
            started.fulfill()
            release.wait()
            return value
        }
        let group = DispatchGroup()
        let results = DeviceIdResults()
        for _ in 0..<16 {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                results.append(cache.value)
                group.leave()
            }
        }
        wait(for: [started], timeout: 1)
        release.signal()

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(resolver.count, 1)
        XCTAssertEqual(results.values, Array(repeating: "device-1", count: 16))
    }
}

private final class DeviceIdResolverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let value: String?
    private var resolutions = 0

    init(value: String?) { self.value = value }

    func resolve() -> String? {
        lock.lock(); resolutions += 1; let value = value; lock.unlock()
        return value
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return resolutions }
}

private final class DeviceIdResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    func append(_ value: String?) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
}
