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
        await fulfillment(of: [exp], timeout: TestWait.timeout)

        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertTrue(persistedQueue().isEmpty)
    }

    func testPermanentErrorDeliversFailureAndDropsTask() async {
        let verifier = FakeVerifier()
        verifier.setError(SimulaAPIError.httpError(statusCode: 400), for: "A")
        let store = ScriptedRewardStore(saveResults: [])
        let callback = RewardCallbackRecorder()
        let mgr = RewardVerificationManager(verifier: verifier, store: store, now: { 0 })

        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            callback.record(result)
        }
        await waitUntil { callback.count == 1 && store.persisted.isEmpty }

        XCTAssertEqual(callback.failureCount, 1)
        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertTrue(store.persisted.isEmpty, "a permanent error must drop the task")
    }

    func testRetryableErrorKeepsTaskAndRecordsAttempt() async {
        let verifier = FakeVerifier()
        verifier.setError(SimulaAPIError.httpError(statusCode: 500), for: "A")
        let mgr = RewardVerificationManager(verifier: verifier, defaults: defaults, now: { 1000 })

        let exp = expectation(description: "A failed")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            if case .failure = result { exp.fulfill() }
        }
        await fulfillment(of: [exp], timeout: TestWait.timeout)

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
        await fulfillment(of: [expA, expB], timeout: TestWait.timeout)

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
        await waitUntil { self.persistedQueue().isEmpty }
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
        await waitUntil { self.persistedQueue().isEmpty }
        XCTAssertEqual(verifier.callCount("A"), 1)
    }

    func testRecoveredQueueDrainsInPersistedOrder() async {
        let seeded = [
            PendingVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 1, retryCount: 0, lastAttemptTimestamp: 0),
            PendingVerification(serveId: "B", sessionId: "s", elapsedPlayTime: 2, retryCount: 0, lastAttemptTimestamp: 0),
            PendingVerification(serveId: "C", sessionId: "s", elapsedPlayTime: 3, retryCount: 0, lastAttemptTimestamp: 0),
        ]
        defaults.set(try? JSONEncoder().encode(seeded), forKey: queueKey)
        let verifier = FakeVerifier()
        let mgr = RewardVerificationManager(verifier: verifier, defaults: defaults, now: { 0 })

        mgr.triggerProcessQueue()
        await waitUntil { verifier.callOrder.count == 3 && self.persistedQueue().isEmpty }

        XCTAssertEqual(verifier.callOrder, ["A", "B", "C"])
    }

    func testEnqueueReturnsBeforeBlockedPersistenceAndPersistsBeforeVerify() async {
        let verifier = FakeVerifier()
        let store = BlockingRewardStore()
        let mgr = RewardVerificationManager(verifier: verifier, store: store, now: { 0 })
        defer { store.release() }

        let started = ProcessInfo.processInfo.systemUptime
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(elapsed, 0.1, "enqueue must not wait for persistence")
        await waitUntil { store.saveStarted }
        XCTAssertEqual(verifier.callCount("A"), 0, "verification starts only after the durable write attempt returns")

        store.release()
        await waitUntil { verifier.callCount("A") == 1 }
    }

    func testQueuePersistsDuringQuietWindowThenVerifiesAfterGate() async {
        let verifier = FakeVerifier()
        let gate = ControllableLaunchSettledGate()
        let store = UserDefaultsRewardVerificationStore(defaults)
        let mgr = RewardVerificationManager(verifier: verifier, store: store, now: { 0 }, launchGate: gate)

        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 1)
        await waitUntil { self.persistedQueue().count == 1 }
        XCTAssertEqual(verifier.callCount("A"), 0)

        await gate.open()
        await waitUntil { verifier.callCount("A") == 1 && self.persistedQueue().isEmpty }
    }

    func testInitialSaveFailureBlocksVerifierAndCallbackUntilRetryPersists() async {
        let verifier = FakeVerifier()
        verifier.setToken("token", for: "A")
        let store = ScriptedRewardStore(saveResults: [false, true, true])
        let persistenceSleep = ControllablePersistenceSleep()
        let callback = RewardCallbackRecorder()
        let mgr = RewardVerificationManager(
            verifier: verifier,
            store: store,
            now: { 0 },
            persistenceSleep: { await persistenceSleep.sleep($0) }
        )

        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 1) {
            callback.record($0)
        }
        let initialDelay = await persistenceSleep.waitForRequest()
        XCTAssertEqual(initialDelay, 1)
        XCTAssertEqual(verifier.callCount("A"), 0)
        XCTAssertEqual(callback.count, 0)

        persistenceSleep.release()
        await waitUntil { verifier.callCount("A") == 1 && callback.count == 1 && store.persisted.isEmpty }
        XCTAssertEqual(callback.successToken, "token")
    }

    func testRemovalSaveFailureWithholdsCallbackAndQueueAdvance() async {
        let verifier = FakeVerifier()
        verifier.setToken("token", for: "A")
        let store = ScriptedRewardStore(saveResults: [true, false, true])
        let persistenceSleep = ControllablePersistenceSleep()
        let callback = RewardCallbackRecorder()
        let duplicateCallback = RewardCallbackRecorder()
        let mgr = RewardVerificationManager(
            verifier: verifier,
            store: store,
            now: { 0 },
            persistenceSleep: { await persistenceSleep.sleep($0) }
        )

        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 1) {
            callback.record($0)
        }
        let removalDelay = await persistenceSleep.waitForRequest()
        XCTAssertEqual(removalDelay, 1)
        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertEqual(callback.count, 0)
        XCTAssertEqual(store.persisted.map(\.serveId), ["A"])

        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 1) {
            duplicateCallback.record($0)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertEqual(duplicateCallback.count, 0)

        persistenceSleep.release()
        await waitUntil { callback.count == 1 && store.persisted.isEmpty }
        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertEqual(duplicateCallback.count, 0)
    }

    func testNonFiniteElapsedTimeDoesNotPoisonQueue() async {
        let verifier = FakeVerifier()
        verifier.setToken("token", for: "valid")
        let store = ScriptedRewardStore(saveResults: [])
        let invalidCallback = RewardCallbackRecorder()
        let validCallback = RewardCallbackRecorder()
        let mgr = RewardVerificationManager(verifier: verifier, store: store, now: { 0 })

        mgr.queueVerification(serveId: "invalid", sessionId: "s", elapsedPlayTime: .nan) {
            invalidCallback.record($0)
        }
        mgr.queueVerification(serveId: "valid", sessionId: "s", elapsedPlayTime: 1) {
            validCallback.record($0)
        }

        await waitUntil { invalidCallback.count == 1 && validCallback.count == 1 }
        XCTAssertEqual(verifier.callCount("invalid"), 0)
        XCTAssertEqual(verifier.callCount("valid"), 1)
        XCTAssertTrue(store.persisted.isEmpty)
    }

    func testRetryStateSaveFailureWithholdsFailureCallbackAndRetryWake() async {
        let verifier = FakeVerifier()
        verifier.setError(SimulaAPIError.httpError(statusCode: 500), for: "A")
        let store = ScriptedRewardStore(saveResults: [true, false, true])
        let persistenceSleep = ControllablePersistenceSleep()
        let retrySleep = ControllableSleep()
        let callback = RewardCallbackRecorder()
        let mgr = RewardVerificationManager(
            verifier: verifier,
            store: store,
            now: { 100 },
            sleep: { await retrySleep.sleep($0) },
            persistenceSleep: { await persistenceSleep.sleep($0) }
        )
        defer { retrySleep.release() }

        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 1) {
            callback.record($0)
        }
        let retryStateDelay = await persistenceSleep.waitForRequest()
        XCTAssertEqual(retryStateDelay, 1)
        XCTAssertEqual(callback.count, 0)
        XCTAssertFalse(retrySleep.isSleeping)
        XCTAssertEqual(store.persisted.first?.retryCount, 0)

        persistenceSleep.release()
        await waitUntil { callback.count == 1 && retrySleep.isSleeping }
        XCTAssertEqual(store.persisted.first?.retryCount, 1)
        XCTAssertEqual(store.persisted.first?.lastAttemptTimestamp, 100)
        XCTAssertEqual(verifier.callCount("A"), 1)
    }

    func testTransientLoadRecoveryMergesPendingAndKeepsLatestCallbackAssociation() async {
        let verifier = FakeVerifier()
        verifier.setToken("token-A", for: "A")
        verifier.setToken("token-B", for: "B")
        verifier.setToken("token-C", for: "C")
        let recovered = PendingVerification(
            serveId: "C", sessionId: "s", elapsedPlayTime: 1,
            retryCount: 0, lastAttemptTimestamp: 0
        )
        let store = RecoveringRewardStore(recovered: [recovered])
        let loadSleep = ControllablePersistenceSleep()
        let supersededCallback = RewardCallbackRecorder()
        let latestCallback = RewardCallbackRecorder()
        let callbackB = RewardCallbackRecorder()
        let mgr = RewardVerificationManager(
            verifier: verifier,
            store: store,
            now: { 0 },
            loadSleep: { await loadSleep.sleep($0) }
        )

        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 1) { supersededCallback.record($0) }
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 2) { latestCallback.record($0) }
        mgr.queueVerification(serveId: "B", sessionId: "s", elapsedPlayTime: 3) { callbackB.record($0) }
        _ = await loadSleep.waitForRequest()
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(verifier.callOrder, [])

        store.allowRecovery()
        loadSleep.release()
        await waitUntil {
            verifier.callOrder == ["C", "A", "B"]
                && latestCallback.count == 1
                && callbackB.count == 1
                && store.persisted.isEmpty
        }

        XCTAssertEqual(store.firstSaved.map(\.serveId), ["C", "A", "B"])
        XCTAssertEqual(supersededCallback.count, 0)
        XCTAssertEqual(latestCallback.successToken, "token-A")
        XCTAssertEqual(callbackB.successToken, "token-B")
    }

    /// Re-enqueue after the backoff window must retry — distinct from the automatic
    /// wake path below. Injected store/sleeper avoid simulator persistence and wall-clock
    /// stalls while keeping the persist-before-retry behavior under test.
    func testBackedOffTaskIsRetriedAfterItsDelay() async {
        let verifier = FakeVerifier()
        verifier.setError(SimulaAPIError.httpError(statusCode: 500), for: "A")
        let clock = TestClock(0)
        let sleeper = ControllableSleep()
        let store = ScriptedRewardStore(saveResults: [])
        let mgr = RewardVerificationManager(
            verifier: verifier,
            store: store,
            now: { clock.time },
            sleep: { await sleeper.sleep($0) }
        )
        defer { sleeper.release() }

        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5)

        // Drain finished + wake scheduled (invokeCallback happens before sleep).
        await waitUntil { sleeper.isSleeping }
        guard sleeper.isSleeping else { return }
        let requested = await sleeper.waitForSleepRequest()
        XCTAssertEqual(requested, 5, accuracy: 0.01, "backoff(1) = 5s must drive the wake delay")
        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertEqual(store.persisted.first?.retryCount, 1) // recorded at t=0; backoff(1)=5s

        // Become eligible, then re-enqueue (dedup → fresh callback + trigger). Leave
        // the wake parked so this drain is the re-enqueue path, not the scheduled wake.
        verifier.clearError(for: "A")
        verifier.setToken("tokA", for: "A")
        clock.time = 5
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5)

        await waitUntil { store.persisted.isEmpty }
        XCTAssertEqual(verifier.callCount("A"), 2) // attempted again only after the delay
        XCTAssertTrue(store.persisted.isEmpty)
        XCTAssertTrue(sleeper.isSleeping, "re-enqueue must drain without consuming the scheduled wake")
    }

    /// The retry-wake path: a 5xx bail must schedule a drain that re-fires on its own after
    /// backoff — without a new enqueue or app relaunch. Controllable sleep + clock so this
    /// doesn't wait on wall-clock 5s.
    func testRetryWakeReDrainsAfterBackoffWithoutNewEnqueue() async {
        let verifier = FakeVerifier()
        verifier.setError(SimulaAPIError.httpError(statusCode: 500), for: "A")
        let clock = TestClock(0)
        let sleeper = ControllableSleep()
        let mgr = RewardVerificationManager(
            verifier: verifier,
            defaults: defaults,
            now: { clock.time },
            sleep: { await sleeper.sleep($0) }
        )

        let failExp = expectation(description: "first attempt fails")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            if case .failure = result { failExp.fulfill() }
        }
        await fulfillment(of: [failExp], timeout: TestWait.timeout)
        XCTAssertEqual(verifier.callCount("A"), 1)

        let requested = await sleeper.waitForSleepRequest()
        XCTAssertEqual(requested, 5, accuracy: 0.01, "backoff(1) = 5s must drive the wake delay")

        // Become eligible, then release the wake — no re-enqueue / trigger from the test.
        verifier.clearError(for: "A")
        verifier.setToken("tokA", for: "A")
        clock.time = 5
        sleeper.release()

        await waitUntil { self.persistedQueue().isEmpty }
        XCTAssertEqual(verifier.callCount("A"), 2, "wake must re-drain once the backoff elapses")
        XCTAssertEqual(sleeper.count, 1, "success path must not schedule another wake")
    }

    /// A wake that finds nothing eligible (frozen clock) must terminate — not reschedule
    /// itself forever against a backend that just failed.
    func testRetryWakeDoesNotRescheduleWhenStillBackedOff() async {
        let verifier = FakeVerifier()
        verifier.setError(SimulaAPIError.httpError(statusCode: 500), for: "A")
        let clock = TestClock(0)
        let sleeper = ControllableSleep()
        let mgr = RewardVerificationManager(
            verifier: verifier,
            defaults: defaults,
            now: { clock.time },
            sleep: { await sleeper.sleep($0) }
        )

        let failExp = expectation(description: "first attempt fails")
        mgr.queueVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 5) { result in
            if case .failure = result { failExp.fulfill() }
        }
        await fulfillment(of: [failExp], timeout: TestWait.timeout)
        _ = await sleeper.waitForSleepRequest()

        // Release the wake without advancing the clock → task still ineligible.
        sleeper.release()
        await waitUntil { !sleeper.isSleeping }
        // Settle so a wrongly chained wake would have parked on sleep again.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(verifier.callCount("A"), 1)
        XCTAssertEqual(persistedQueue().count, 1)
        XCTAssertEqual(sleeper.count, 1, "ineligible wake must not chain another sleep")
    }

    // Note: Kotlin additionally tests a throwing listener not derailing the drain — not
    // applicable here, as Swift completion closures are non-throwing by type.
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

/// Parks the retry-wake until the test advances the fake clock and calls [release].
private final class ControllableSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingDelay: TimeInterval?
    private var delayWaiter: CheckedContinuation<TimeInterval, Never>?
    private var releaseCont: CheckedContinuation<Void, Never>?
    private var _count = 0
    private var sleeping = false

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    var isSleeping: Bool {
        lock.lock(); defer { lock.unlock() }
        return sleeping
    }

    func sleep(_ delay: TimeInterval) async {
        lock.lock()
        _count += 1
        sleeping = true
        pendingDelay = delay
        let waiter = delayWaiter
        delayWaiter = nil
        lock.unlock()
        waiter?.resume(returning: delay)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            releaseCont = cont
            lock.unlock()
        }

        lock.lock()
        sleeping = false
        pendingDelay = nil
        lock.unlock()
    }

    func waitForSleepRequest() async -> TimeInterval {
        await withCheckedContinuation { cont in
            lock.lock()
            if let delay = pendingDelay {
                lock.unlock()
                cont.resume(returning: delay)
                return
            }
            delayWaiter = cont
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let cont = releaseCont
        releaseCont = nil
        lock.unlock()
        cont?.resume()
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
    private var orderedCalls: [String] = []

    func setToken(_ token: String?, for serveId: String) { lock.lock(); tokens[serveId] = token; lock.unlock() }
    func setError(_ error: Error, for serveId: String) { lock.lock(); errors[serveId] = error; lock.unlock() }
    func clearError(for serveId: String) { lock.lock(); errors[serveId] = nil; lock.unlock() }
    func gate(_ serveId: String) { lock.lock(); gated.insert(serveId); lock.unlock() }
    func callCount(_ serveId: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[serveId] ?? 0 }
    var callOrder: [String] { lock.lock(); defer { lock.unlock() }; return orderedCalls }

    func verifyReward(serveId: String, sessionId: String, elapsedPlayTime: Double, adUnitId: String) async throws -> VerifyRewardResponse {
        lock.lock()
        counts[serveId, default: 0] += 1
        orderedCalls.append(serveId)
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

private final class BlockingRewardStore: RewardVerificationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var didRelease = false
    private var _saveStarted = false

    var saveStarted: Bool { lock.lock(); defer { lock.unlock() }; return _saveStarted }
    func load() -> DurableQueueLoad<PendingVerification> { .missing }
    func save(_ records: [PendingVerification]) -> Bool {
        lock.lock()
        _saveStarted = true
        let shouldWait = !didRelease
        lock.unlock()
        if shouldWait { gate.wait() }
        return true
    }
    func release() {
        lock.lock()
        let shouldSignal = !didRelease
        didRelease = true
        lock.unlock()
        if shouldSignal { gate.signal() }
    }
}

private final class ScriptedRewardStore: RewardVerificationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    private var durable: [PendingVerification] = []

    init(saveResults: [Bool]) { results = saveResults }
    func load() -> DurableQueueLoad<PendingVerification> { .missing }
    func save(_ records: [PendingVerification]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let succeeds = results.isEmpty ? true : results.removeFirst()
        if succeeds { durable = records }
        return succeeds
    }
    var persisted: [PendingVerification] { lock.lock(); defer { lock.unlock() }; return durable }
}

private final class RewardCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String?, Error>] = []
    func record(_ result: Result<String?, Error>) { lock.lock(); results.append(result); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return results.count }
    var failureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return results.filter { if case .failure = $0 { return true }; return false }.count
    }
    var successToken: String? {
        lock.lock(); defer { lock.unlock() }
        guard let first = results.first else { return nil }
        return try? first.get()
    }
}

private final class RecoveringRewardStore: RewardVerificationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let recovered: [PendingVerification]
    private var recoveryAllowed = false
    private var loads = 0
    private var saves: [[PendingVerification]] = []
    private var durable: [PendingVerification] = []

    init(recovered: [PendingVerification]) { self.recovered = recovered }
    func load() -> DurableQueueLoad<PendingVerification> {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        return recoveryAllowed ? .loaded(recovered) : .failed
    }
    func save(_ records: [PendingVerification]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        saves.append(records)
        durable = records
        return true
    }
    func allowRecovery() { lock.lock(); recoveryAllowed = true; lock.unlock() }
    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return loads }
    var firstSaved: [PendingVerification] { lock.lock(); defer { lock.unlock() }; return saves.first ?? [] }
    var persisted: [PendingVerification] { lock.lock(); defer { lock.unlock() }; return durable }
}
