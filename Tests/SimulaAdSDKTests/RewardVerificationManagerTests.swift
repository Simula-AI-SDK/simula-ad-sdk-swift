import XCTest
@testable import SimulaAdSDK

/// Tier-0 + Tier-1 tests for the reward-verification queue: the retry policy (backoff +
/// permanent-vs-retryable classification) and the draining engine (success / drop /
/// retain / in-flight routing / recovery), exercised with a fake verifier, an isolated
/// `UserDefaults`, and a controllable clock — no network, no wall-clock timing.
final class RewardVerificationManagerTests: XCTestCase {

    // Must mirror RewardVerificationManager.userDefaultsKey (private there).
    private let queueKey = "simula_pending_reward_verifications"

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "rvm-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func persistedQueue() -> [PendingVerification] {
        guard let data = defaults.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([PendingVerification].self, from: data)) ?? []
    }

    // MARK: - Tier 0: pure policy

    func testBackoffIsImmediateForFirstAttempt() {
        XCTAssertEqual(rewardVerificationBackoff(retryCount: 0), 0)
    }

    func testBackoffGrowsExponentiallyAndCapsAt60s() {
        XCTAssertEqual(rewardVerificationBackoff(retryCount: 1), 5)
        XCTAssertEqual(rewardVerificationBackoff(retryCount: 2), 10)
        XCTAssertEqual(rewardVerificationBackoff(retryCount: 3), 20)
        XCTAssertEqual(rewardVerificationBackoff(retryCount: 4), 40)
        XCTAssertEqual(rewardVerificationBackoff(retryCount: 5), 60) // 80 clamped
        XCTAssertEqual(rewardVerificationBackoff(retryCount: 10), 60)
    }

    func testPermanentClassification() {
        XCTAssertTrue(isPermanentVerificationError(SimulaAPIError.httpError(statusCode: 400)))
        XCTAssertTrue(isPermanentVerificationError(SimulaAPIError.httpError(statusCode: 403)))
        XCTAssertTrue(isPermanentVerificationError(SimulaAPIError.httpError(statusCode: 404)))
        XCTAssertFalse(isPermanentVerificationError(SimulaAPIError.httpError(statusCode: 408)))
        XCTAssertFalse(isPermanentVerificationError(SimulaAPIError.httpError(statusCode: 429)))
        XCTAssertFalse(isPermanentVerificationError(SimulaAPIError.httpError(statusCode: 500)))
        XCTAssertFalse(isPermanentVerificationError(URLError(.notConnectedToInternet)))
    }

    // MARK: - Tier 1: engine

    func testSuccessDeliversTokenAndRemovesTask() async {
        let verifier = FakeVerifier()
        verifier.setToken("tokA", for: "A")
        let mgr = RewardVerificationManager(verifier: verifier, defaults: defaults, now: { 0 })

        let exp = expectation(description: "A verified")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            XCTAssertEqual(try? result.get(), "tokA")
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertTrue(persistedQueue().isEmpty)
    }

    func testPermanentErrorDeliversFailureAndDropsTask() async {
        let verifier = FakeVerifier()
        verifier.setError(SimulaAPIError.httpError(statusCode: 400), for: "A")
        let mgr = RewardVerificationManager(verifier: verifier, defaults: defaults, now: { 0 })

        let exp = expectation(description: "A failed")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            if case .failure = result { exp.fulfill() }
        }
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertTrue(persistedQueue().isEmpty, "a permanent error must drop the task")
    }

    func testRetryableErrorKeepsTaskAndRecordsAttempt() async {
        let verifier = FakeVerifier()
        verifier.setError(SimulaAPIError.httpError(statusCode: 500), for: "A")
        let mgr = RewardVerificationManager(verifier: verifier, defaults: defaults, now: { 1000 })

        let exp = expectation(description: "A failed")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            if case .failure = result { exp.fulfill() }
        }
        await fulfillment(of: [exp], timeout: 2)

        let queue = persistedQueue()
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.retryCount, 1)
        XCTAssertEqual(queue.first?.lastAttemptTimestamp, 1000)
        XCTAssertEqual(verifier.callCount("A"), 1)
    }

    func testVerificationEnqueuedDuringInFlightDrainIsRoutedToItsOwnCaller() async {
        let verifier = FakeVerifier()
        verifier.setToken("tokA", for: "A")
        verifier.setToken("tokB", for: "B")
        verifier.gate("A") // hold A in flight while B is enqueued
        let mgr = RewardVerificationManager(verifier: verifier, defaults: defaults, now: { 0 })

        let expA = expectation(description: "A")
        let expB = expectation(description: "B")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            XCTAssertEqual(try? result.get(), "tokA") // never crossed with B
            expA.fulfill()
        }
        await verifier.waitUntilEntered("A") // drain is now inside verify(A)

        mgr.queueVerification(serveId: "B", sessionId: "s", elapsedPlayTime: 5) { result in
            XCTAssertEqual(try? result.get(), "tokB")
            expB.fulfill()
        }

        verifier.release("A")
        await fulfillment(of: [expA, expB], timeout: 2)

        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertEqual(verifier.callCount("B"), 1)
        XCTAssertTrue(persistedQueue().isEmpty)
    }

    func testDuplicateServeIdIsEnqueuedAndVerifiedOnce() async {
        let verifier = FakeVerifier()
        verifier.setToken("tokA", for: "A")
        verifier.gate("A")
        let mgr = RewardVerificationManager(verifier: verifier, defaults: defaults, now: { 0 })

        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5)
        await verifier.waitUntilEntered("A")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) // duplicate, in flight
        XCTAssertEqual(persistedQueue().count, 1)

        verifier.release("A")
        // Drain finishes asynchronously; poll the persisted queue until empty.
        try? await waitUntil(timeout: 2) { self.persistedQueue().isEmpty }
        XCTAssertEqual(verifier.callCount("A"), 1)
    }

    func testTriggerDrainsTaskLeftByPriorSession() async {
        // Seed a persisted task as if a prior process had left it pending.
        let seeded = [PendingVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5, retryCount: 0, lastAttemptTimestamp: 0)]
        defaults.set(try! JSONEncoder().encode(seeded), forKey: queueKey)

        let verifier = FakeVerifier()
        verifier.setToken("tokA", for: "A")
        let mgr = RewardVerificationManager(verifier: verifier, defaults: defaults, now: { 0 })

        mgr.triggerProcessQueue() // the app-launch recovery path (Fix C)
        try? await waitUntil(timeout: 2) { self.persistedQueue().isEmpty }
        XCTAssertEqual(verifier.callCount("A"), 1)
    }

    func testBackedOffTaskIsRetriedAfterItsDelay() async {
        let verifier = FakeVerifier()
        verifier.setError(SimulaAPIError.httpError(statusCode: 500), for: "A")
        let clock = TestClock(0)
        let mgr = RewardVerificationManager(verifier: verifier, defaults: defaults, now: { clock.time })

        let failExp = expectation(description: "first attempt fails")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            if case .failure = result { failExp.fulfill() }
        }
        await fulfillment(of: [failExp], timeout: 2)
        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertEqual(persistedQueue().first?.retryCount, 1) // recorded at t=0; backoff(1)=5s

        // After the backoff window, a retry succeeds. Re-enqueue (dedup → just registers
        // a fresh callback + triggers) to get an awaitable result.
        verifier.clearError(for: "A")
        verifier.setToken("tokA", for: "A")
        clock.time = 5
        let okExp = expectation(description: "retry succeeds")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            if case .success = result { okExp.fulfill() }
        }
        await fulfillment(of: [okExp], timeout: 2)

        XCTAssertEqual(verifier.callCount("A"), 2) // attempted again only after the delay
        XCTAssertTrue(persistedQueue().isEmpty)
    }

    // Note: Kotlin additionally tests a throwing listener not derailing the drain — not
    // applicable here, as Swift completion closures are non-throwing by type.

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }
}

// MARK: - Test doubles

/// Controllable clock for deterministic backoff tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(_ t: TimeInterval) { self.t = t }
    var time: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return t }
        set { lock.lock(); t = newValue; lock.unlock() }
    }
}

/// Programmable verifier: per-`serveId` token (success) or error (throw), with an
/// optional gate so a test can hold a verify "in flight" while it enqueues more work.
private final class FakeVerifier: RewardVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String?] = [:]
    private var errors: [String: Error] = [:]
    private var counts: [String: Int] = [:]
    private var gated: Set<String> = []
    private var releaseConts: [String: CheckedContinuation<Void, Never>] = [:]
    private var enteredFlags: Set<String> = []
    private var enteredWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    func setToken(_ token: String?, for serveId: String) { lock.lock(); tokens[serveId] = token; lock.unlock() }
    func setError(_ error: Error, for serveId: String) { lock.lock(); errors[serveId] = error; lock.unlock() }
    func clearError(for serveId: String) { lock.lock(); errors[serveId] = nil; lock.unlock() }
    func gate(_ serveId: String) { lock.lock(); gated.insert(serveId); lock.unlock() }
    func callCount(_ serveId: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[serveId] ?? 0 }

    func verifyReward(serveId: String, sessionId: String, elapsedPlayTime: Double, adUnitId: String) async throws -> VerifyRewardResponse {
        lock.lock()
        counts[serveId, default: 0] += 1
        let isGated = gated.contains(serveId)
        lock.unlock()

        if isGated {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                enteredFlags.insert(serveId)
                let waiter = enteredWaiters.removeValue(forKey: serveId)
                releaseConts[serveId] = cont
                lock.unlock()
                waiter?.resume()
            }
        }

        lock.lock()
        let error = errors[serveId]
        let token = tokens[serveId] ?? nil
        lock.unlock()

        if let error { throw error }
        return VerifyRewardResponse(verified: true, token: token)
    }

    /// Suspends until verify(serveId) has been entered (used to sequence the in-flight tests).
    func waitUntilEntered(_ serveId: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if enteredFlags.contains(serveId) {
                lock.unlock()
                cont.resume()
                return
            }
            enteredWaiters[serveId] = cont
            lock.unlock()
        }
    }

    func release(_ serveId: String) {
        lock.lock()
        let cont = releaseConts.removeValue(forKey: serveId)
        gated.remove(serveId)
        lock.unlock()
        cont?.resume()
    }
}
