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

    func testResolvedOnlyAccessorCompletesBeforeInProgressResolutionIsReleased() async {
        let resolverStarted = DeviceIdSignal()
        let resolverCompleted = DeviceIdSignal()
        let releaseResolver = DispatchSemaphore(value: 0)
        let cache = SimulaDeviceIdCache {
            resolverStarted.signal()
            releaseResolver.wait()
            return "device-1"
        }
        let resolverQueue = DispatchQueue(label: "device-id-resolver")
        let accessorQueue = DispatchQueue(label: "device-id-resolved-only")
        let accessorCompleted = expectation(description: "resolved-only accessor completed")
        let result = DeviceIdResults()

        resolverQueue.async {
            _ = cache.value
            resolverCompleted.signal()
        }
        await resolverStarted.wait()
        accessorQueue.async {
            result.append(cache.valueIfResolved)
            accessorCompleted.fulfill()
        }

        await fulfillment(of: [accessorCompleted], timeout: TestWait.timeout)
        XCTAssertEqual(result.values, [nil], "resolved-only access must complete before resolver release")

        releaseResolver.signal()
        await resolverCompleted.wait()
        await drainQueue(resolverQueue)
        await drainQueue(accessorQueue)
        XCTAssertEqual(cache.valueIfResolved, "device-1")
    }

    func testForcingAccessorResolvesOnlyOnceAcrossConcurrentReaders() async {
        let resolverStarted = DeviceIdSignal()
        let releaseResolver = DispatchSemaphore(value: 0)
        let resolver = DeviceIdResolverCounter(value: "device-1")
        let cache = SimulaDeviceIdCache {
            let value = resolver.resolve()
            resolverStarted.signal()
            releaseResolver.wait()
            return value
        }
        let queue = DispatchQueue(label: "device-id-concurrent-readers", attributes: .concurrent)
        let ready = DispatchGroup()
        let completed = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let results = DeviceIdResults()

        for _ in 0..<16 {
            ready.enter()
            completed.enter()
            queue.async {
                ready.leave()
                start.wait()
                results.append(cache.value)
                completed.leave()
            }
        }

        await waitForGroup(ready, label: "device-id-readers-ready")
        for _ in 0..<16 { start.signal() }
        await resolverStarted.wait()
        releaseResolver.signal()
        await waitForGroup(completed, label: "device-id-readers-completed")
        await drainQueue(queue)

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

private final class DeviceIdSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private func waitForGroup(_ group: DispatchGroup, label: String) async {
    await withCheckedContinuation { continuation in
        group.notify(queue: DispatchQueue(label: label)) { continuation.resume() }
    }
}

private func drainQueue(_ queue: DispatchQueue) async {
    await withCheckedContinuation { continuation in
        queue.async { continuation.resume() }
    }
}
