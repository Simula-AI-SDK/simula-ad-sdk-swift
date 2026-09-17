import Combine
import XCTest
@testable import SimulaAdSDK

@MainActor
final class SessionForegroundRefreshTests: XCTestCase {
    func testLifecycleDoesNotExpireAtTwentyNineMinutesFiftyNineSeconds() {
        let harness = makeLifecycleHarness()

        harness.center.post(name: harness.background, object: nil)
        harness.clock.advance(by: applicationSessionBackgroundExpirationInterval - 1)
        harness.center.post(name: harness.active, object: nil)

        XCTAssertEqual(harness.expirations.value, 0)
        withExtendedLifetime(harness.observer) {}
    }

    func testLifecycleExpiresAtExactlyThirtyMinutes() {
        let harness = makeLifecycleHarness()

        harness.center.post(name: harness.background, object: nil)
        harness.clock.advance(by: applicationSessionBackgroundExpirationInterval)
        harness.center.post(name: harness.active, object: nil)

        XCTAssertEqual(harness.expirations.value, 1)
        withExtendedLifetime(harness.observer) {}
    }

    func testLifecycleUsesSleepInclusiveElapsedTimeAndKeepsFirstBackgroundTimestamp() {
        let harness = makeLifecycleHarness()

        harness.center.post(name: harness.background, object: nil)
        harness.clock.advance(by: 15 * 60)
        harness.center.post(name: harness.background, object: nil)
        harness.clock.advance(by: 16 * 60)
        harness.center.post(name: harness.active, object: nil)

        XCTAssertEqual(harness.expirations.value, 1)
        withExtendedLifetime(harness.observer) {}
    }

    func testLifecycleInstallWhileBackgroundedStartsMeasuringAtInstall() {
        let center = NotificationCenter()
        let active = Notification.Name("session-expiration-seeded-active")
        let clock = LockedSessionClock(100)
        let expirations = LockedInt()
        let observer = ApplicationSessionLifecycleObserver(
            center: center,
            didEnterBackground: Notification.Name("session-expiration-seeded-background"),
            didBecomeActive: active,
            initiallyBackgrounded: true,
            now: { clock.value },
            expire: { expirations.increment() }
        )

        clock.advance(by: applicationSessionBackgroundExpirationInterval - 1)
        center.post(name: active, object: nil)

        XCTAssertEqual(expirations.value, 0)
        withExtendedLifetime(observer) {}
    }

    func testLifecycleNegativeElapsedTimeFailsSoft() {
        let harness = makeLifecycleHarness(start: 100)

        harness.center.post(name: harness.background, object: nil)
        harness.clock.set(99)
        harness.center.post(name: harness.active, object: nil)

        XCTAssertEqual(harness.expirations.value, 0)
        withExtendedLifetime(harness.observer) {}
    }

    func testQualifyingForegroundIsLazyUntilNextEnsureSession() async {
        let creator = ControlledSessionCreator()
        let provider = makeProvider(creator: creator)
        let initial = await provider.ensureSession()
        XCTAssertEqual(initial, "session-old")

        provider.markSessionStaleAfterExtendedBackground()
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(creator.callCount, 1)
        let refresh = Task { await provider.ensureSession() }
        await creator.waitForCallCount(2)
        creator.resolveNext("session-new")
        let refreshed = await refresh.value
        XCTAssertEqual(refreshed, "session-new")
    }

    func testFailedRefreshFailsOpenRemainsStaleAndRetriesOnLaterCall() async {
        let creator = ControlledSessionCreator()
        let provider = makeProvider(creator: creator)
        let initial = await provider.ensureSession()
        XCTAssertEqual(initial, "session-old")
        provider.markSessionStaleAfterExtendedBackground()

        let firstWaiter = Task { await provider.ensureSession() }
        let secondWaiter = Task { await provider.ensureSession() }
        await creator.waitForCallCount(2)
        creator.resolveNext(nil)

        let firstResult = await firstWaiter.value
        let secondResult = await secondWaiter.value
        XCTAssertEqual(firstResult, "session-old")
        XCTAssertEqual(secondResult, "session-old")
        XCTAssertEqual(provider.sessionId, "session-old")
        XCTAssertEqual(provider.sessionUserID, "user-a")
        XCTAssertEqual(creator.callCount, 2)

        let retry = Task { await provider.ensureSession() }
        await creator.waitForCallCount(3)
        creator.resolveNext("session-new")
        let retryResult = await retry.value
        XCTAssertEqual(retryResult, "session-new")
        XCTAssertEqual(creator.callCount, 3)
    }

    func testFailedInitialSessionWithMultipleWaitersMakesOneAttempt() async {
        let creator = ControlledSessionCreator(firstCallIsPending: true)
        let provider = makeProvider(creator: creator)
        provider.markSessionStaleAfterExtendedBackground()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(creator.callCount, 0)

        let firstWaiter = Task { await provider.ensureSession() }
        let secondWaiter = Task { await provider.ensureSession() }
        await creator.waitForCallCount(1)
        creator.resolveNext(nil)

        let firstResult = await firstWaiter.value
        let secondResult = await secondWaiter.value
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)
        XCTAssertEqual(creator.callCount, 1)

        let retry = Task { await provider.ensureSession() }
        await creator.waitForCallCount(2)
        creator.resolveNext("session-new")
        let retryResult = await retry.value
        XCTAssertEqual(retryResult, "session-new")
    }

    func testExpirationDuringInflightInitialCreationRefreshesBeforeReturning() async {
        let creator = ControlledSessionCreator(firstCallIsPending: true)
        let provider = makeProvider(creator: creator)
        let waiter = Task { await provider.ensureSession() }
        await creator.waitForCallCount(1)

        provider.markSessionStaleAfterExtendedBackground()
        creator.resolveNext("session-before-expiration")
        await creator.waitForCallCount(2)
        creator.resolveNext("session-current")

        let result = await waiter.value
        XCTAssertEqual(result, "session-current")
        XCTAssertEqual(provider.sessionId, "session-current")
        XCTAssertEqual(creator.callCount, 2)
    }

    func testExpirationDuringInflightStaleRefreshRefreshesAgainBeforeReturning() async {
        let creator = ControlledSessionCreator()
        let provider = makeProvider(creator: creator)
        _ = await provider.ensureSession()
        provider.markSessionStaleAfterExtendedBackground()
        let waiter = Task { await provider.ensureSession() }
        await creator.waitForCallCount(2)

        provider.markSessionStaleAfterExtendedBackground()
        creator.resolveNext("session-first-epoch")
        await creator.waitForCallCount(3)
        creator.resolveNext("session-current")

        let result = await waiter.value
        XCTAssertEqual(result, "session-current")
        XCTAssertEqual(provider.sessionId, "session-current")
        XCTAssertEqual(creator.callCount, 3)
    }

    func testStaleRefreshClaimsOneTaskWhilePreparationIsPending() async {
        let creator = ControlledSessionCreator()
        let preparation = ControlledSessionPreparation()
        let provider = makeProvider(
            creator: creator,
            sessionRefreshPreparation: { await preparation.wait() }
        )
        _ = await provider.ensureSession()
        provider.markSessionStaleAfterExtendedBackground()

        let firstWaiter = Task { await provider.ensureSession() }
        await preparation.waitUntilEntered()
        let secondWaiter = Task { await provider.ensureSession() }
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(creator.callCount, 1)
        preparation.finish()
        await creator.waitForCallCount(2)
        creator.resolveNext("session-new")
        let firstResult = await firstWaiter.value
        let secondResult = await secondWaiter.value
        XCTAssertEqual(firstResult, "session-new")
        XCTAssertEqual(secondResult, "session-new")
        XCTAssertEqual(creator.callCount, 2)
    }

    func testEveryRegisteredProviderIsMarkedStaleAndSharedIsDeduplicated() async {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let outerCreator = ControlledSessionCreator()
        let currentCreator = ControlledSessionCreator()
        let outer = makeProvider(creator: outerCreator, ownership: ownership, registry: registry)
        let current = makeProvider(creator: currentCreator, ownership: ownership, registry: registry)
        _ = await outer.ensureSession()
        _ = await current.ensureSession()

        expireRegisteredApplicationSessions(registry: registry, shared: outer)

        let outerRefresh = Task { await outer.ensureSession() }
        let currentRefresh = Task { await current.ensureSession() }
        await outerCreator.waitForCallCount(2)
        await currentCreator.waitForCallCount(2)
        outerCreator.resolveNext("outer-new")
        currentCreator.resolveNext("session-new")
        let outerResult = await outerRefresh.value
        let currentResult = await currentRefresh.value
        XCTAssertEqual(outerResult, "outer-new")
        XCTAssertEqual(currentResult, "session-new")
        XCTAssertEqual(outerCreator.callCount, 2)
        XCTAssertEqual(currentCreator.callCount, 2)
    }

    func testSuccessfulRefreshPublishesSessionIdentityBeforeObservableId() async {
        let creator = ControlledSessionCreator()
        let provider = makeProvider(creator: creator)
        var observedPairs: [(String?, String?)] = []
        let subscription = provider.$sessionId.dropFirst().sink { id in
            observedPairs.append((id, provider.sessionUserID))
        }
        _ = await provider.ensureSession()
        provider.markSessionStaleAfterExtendedBackground()

        let refresh = Task { await provider.ensureSession() }
        await creator.waitForCallCount(2)
        creator.resolveNext("session-new")
        let refreshed = await refresh.value
        XCTAssertEqual(refreshed, "session-new")

        XCTAssertEqual(observedPairs.map(\.0), ["session-old", "session-new"])
        XCTAssertEqual(observedPairs.map(\.1), ["user-a", "user-a"])
        withExtendedLifetime(subscription) {}
    }

    func testStaleRefreshConsumesPrivacyChangeBeforeDebouncedDelivery() async {
        let creator = ControlledSessionCreator()
        var snapshot = ConsentSnapshot()
        let changed = ConsentSnapshot(
            hasPrivacyConsent: true,
            advertisingId: "new-idfa",
            attStatus: 3
        )
        let provider = makeProvider(
            creator: creator,
            privacySnapshotProvider: { snapshot }
        )
        _ = await provider.ensureSession()

        snapshot = changed
        provider.markSessionStaleAfterExtendedBackground()
        let refresh = Task { await provider.ensureSession() }
        await creator.waitForCallCount(2)
        creator.resolveNext("session-new")
        let refreshed = await refresh.value
        XCTAssertEqual(refreshed, "session-new")

        provider.handlePrivacySnapshotChange(changed)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(creator.callCount, 2)
        XCTAssertEqual(creator.snapshots.last, changed)
        XCTAssertEqual(provider.sessionId, "session-new")
    }

    private func makeLifecycleHarness(start: TimeInterval = 0) -> LifecycleHarness {
        let center = NotificationCenter()
        let background = Notification.Name("session-expiration-background")
        let active = Notification.Name("session-expiration-active")
        let clock = LockedSessionClock(start)
        let expirations = LockedInt()
        let observer = ApplicationSessionLifecycleObserver(
            center: center,
            didEnterBackground: background,
            didBecomeActive: active,
            now: { clock.value },
            expire: { expirations.increment() }
        )
        return LifecycleHarness(
            center: center,
            background: background,
            active: active,
            clock: clock,
            expirations: expirations,
            observer: observer
        )
    }

    private func makeProvider(
        creator: ControlledSessionCreator,
        ownership: ProcessApiKeyOwnership = ProcessApiKeyOwnership(),
        registry: ActiveSimulaProviderRegistry? = nil,
        sessionRefreshPreparation: @escaping SimulaProvider.SessionRefreshPreparation = {},
        privacySnapshotProvider: @escaping SimulaProvider.PrivacySnapshotProvider = { ConsentSnapshot() }
    ) -> SimulaProvider {
        SimulaProvider(
            testApiKey: "session-refresh-key",
            apiKeyOwnership: ownership,
            primaryUserID: "user-a",
            activeProviderRegistry: registry,
            sessionCreation: { ppid, privacy in
                await creator.create(primaryUserID: ppid, privacy: privacy)
            },
            sessionRefreshPreparation: sessionRefreshPreparation,
            privacySnapshotProvider: privacySnapshotProvider
        )
    }
}

private struct LifecycleHarness {
    let center: NotificationCenter
    let background: Notification.Name
    let active: Notification.Name
    let clock: LockedSessionClock
    let expirations: LockedInt
    let observer: ApplicationSessionLifecycleObserver
}

private final class LockedSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval

    init(_ value: TimeInterval) {
        storedValue = value
    }

    var value: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: TimeInterval) {
        lock.lock(); storedValue = value; lock.unlock()
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); storedValue += interval; lock.unlock()
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock(); storedValue += 1; lock.unlock()
    }
}

@MainActor
private final class ControlledSessionPreparation {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func wait() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { finishContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

@MainActor
private final class ControlledSessionCreator {
    private(set) var callCount = 0
    private(set) var snapshots: [ConsentSnapshot] = []
    private let firstCallIsPending: Bool
    private var continuations: [CheckedContinuation<String?, Never>] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(firstCallIsPending: Bool = false) {
        self.firstCallIsPending = firstCallIsPending
    }

    func create(primaryUserID: String?, privacy: ConsentSnapshot) async -> String? {
        _ = primaryUserID
        snapshots.append(privacy)
        callCount += 1
        let ready = callCountWaiters.filter { $0.0 <= callCount }
        callCountWaiters.removeAll { $0.0 <= callCount }
        ready.forEach { $0.1.resume() }
        if callCount == 1, !firstCallIsPending { return "session-old" }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolveNext(_ result: String?) {
        guard !continuations.isEmpty else {
            XCTFail("No pending session creation")
            return
        }
        continuations.removeFirst().resume(returning: result)
    }

    func waitForCallCount(_ expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((expected, continuation))
        }
        XCTAssertEqual(callCount, expected)
    }
}
