import Combine
import XCTest
@testable import SimulaAdSDK

@MainActor
final class SessionForegroundRefreshTests: XCTestCase {
    func testLifecycleRequiresBackgroundBeforeActiveAndCoalescesRepeatedNotifications() {
        let center = NotificationCenter()
        let background = Notification.Name("session-refresh-background")
        let active = Notification.Name("session-refresh-active")
        var refreshes = 0
        let observer = ApplicationSessionLifecycleObserver(
            center: center,
            didEnterBackground: background,
            didBecomeActive: active,
            refresh: { refreshes += 1 }
        )
        _ = observer

        center.post(name: active, object: nil)
        center.post(name: background, object: nil)
        center.post(name: background, object: nil)
        center.post(name: active, object: nil)
        center.post(name: active, object: nil)

        XCTAssertEqual(refreshes, 1)
    }

    func testLifecycleObserverDoesNotOutliveItsOwner() {
        let center = NotificationCenter()
        let background = Notification.Name("session-refresh-lifetime-background")
        let active = Notification.Name("session-refresh-lifetime-active")
        var refreshes = 0
        var observer: ApplicationSessionLifecycleObserver? = ApplicationSessionLifecycleObserver(
            center: center,
            didEnterBackground: background,
            didBecomeActive: active,
            refresh: { refreshes += 1 }
        )
        weak let weakObserver = observer

        center.post(name: background, object: nil)
        observer = nil
        center.post(name: active, object: nil)

        XCTAssertNil(weakObserver)
        XCTAssertEqual(refreshes, 0)
    }

    func testLifecycleCanBeSeededWhenInstalledWhileBackgrounded() {
        let center = NotificationCenter()
        let active = Notification.Name("session-refresh-seeded-active")
        var refreshes = 0
        let observer = ApplicationSessionLifecycleObserver(
            center: center,
            didEnterBackground: Notification.Name("session-refresh-seeded-background"),
            didBecomeActive: active,
            initiallyBackgrounded: true,
            refresh: { refreshes += 1 }
        )
        _ = observer

        center.post(name: active, object: nil)

        XCTAssertEqual(refreshes, 1)
    }

    func testForegroundRefreshRetainsOldPairOnFailureAndCoalescesEnsureCallers() async {
        let creator = ControlledSessionCreator()
        let provider = makeProvider(primaryUserID: "user-a", creator: creator)

        let initialSession = await provider.ensureSession()
        XCTAssertEqual(initialSession, "session-old")
        XCTAssertEqual(provider.sessionUserID, "user-a")

        provider.beginForegroundSessionRefresh()
        await creator.waitForCallCount(2)
        let waitersStarted = expectation(description: "ensure callers started")
        waitersStarted.expectedFulfillmentCount = 2
        var completedWaiters = 0
        let firstWaiter = Task {
            waitersStarted.fulfill()
            let result = await provider.ensureSession()
            completedWaiters += 1
            return result
        }
        let secondWaiter = Task {
            waitersStarted.fulfill()
            let result = await provider.ensureSession()
            completedWaiters += 1
            return result
        }
        await fulfillment(of: [waitersStarted], timeout: 1)

        XCTAssertEqual(creator.callCount, 2)
        XCTAssertEqual(completedWaiters, 0)
        creator.resolveNext(nil)

        let firstResult = await firstWaiter.value
        let secondResult = await secondWaiter.value
        XCTAssertEqual(firstResult, "session-old")
        XCTAssertEqual(secondResult, "session-old")
        XCTAssertEqual(provider.sessionId, "session-old")
        XCTAssertEqual(provider.sessionUserID, "user-a")
        XCTAssertEqual(creator.callCount, 2)
        XCTAssertEqual(completedWaiters, 2)
    }

    func testSuccessfulRefreshPublishesSessionIdentityBeforeObservableId() async {
        let creator = ControlledSessionCreator()
        let provider = makeProvider(primaryUserID: "user-a", creator: creator)
        var observedPairs: [(String?, String?)] = []
        let subscription = provider.$sessionId.dropFirst().sink { id in
            observedPairs.append((id, provider.sessionUserID))
        }

        _ = await provider.ensureSession()

        provider.beginForegroundSessionRefresh()
        await creator.waitForCallCount(2)
        creator.resolveNext("session-new")
        let refreshedSession = await provider.ensureSession()
        XCTAssertEqual(refreshedSession, "session-new")

        guard observedPairs.count == 2 else {
            return XCTFail("Expected initial and refreshed session publications")
        }
        XCTAssertEqual(observedPairs[0].0, "session-old")
        XCTAssertEqual(observedPairs[0].1, "user-a")
        XCTAssertEqual(observedPairs[1].0, "session-new")
        XCTAssertEqual(observedPairs[1].1, "user-a")
        withExtendedLifetime(subscription) {}
    }

    func testForegroundRefreshClaimsSessionTaskWhilePrivacyPreparationIsPending() async {
        let creator = ControlledSessionCreator()
        let preparation = ControlledForegroundPreparation()
        let provider = makeProvider(
            primaryUserID: "user-a",
            creator: creator,
            foregroundSessionPreparation: { await preparation.wait() }
        )
        _ = await provider.ensureSession()

        provider.beginForegroundSessionRefresh()
        await preparation.waitUntilEntered()
        let waiter = Task { await provider.ensureSession() }
        await Task.yield()

        XCTAssertEqual(creator.callCount, 1)
        preparation.finish()
        await creator.waitForCallCount(2)
        creator.resolveNext("session-new")
        let result = await waiter.value
        XCTAssertEqual(result, "session-new")
    }

    private func makeProvider(
        primaryUserID: String,
        creator: ControlledSessionCreator,
        foregroundSessionPreparation: @escaping SimulaProvider.ForegroundSessionPreparation = {}
    ) -> SimulaProvider {
        SimulaProvider(
            testApiKey: "session-refresh-key",
            apiKeyOwnership: ProcessApiKeyOwnership(),
            primaryUserID: primaryUserID,
            sessionCreation: { ppid, privacy in
                await creator.create(primaryUserID: ppid, privacy: privacy)
            },
            foregroundSessionPreparation: foregroundSessionPreparation
        )
    }
}

@MainActor
private final class ControlledForegroundPreparation {
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
    private var continuations: [CheckedContinuation<String?, Never>] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func create(primaryUserID: String?, privacy: ConsentSnapshot) async -> String? {
        _ = primaryUserID
        _ = privacy
        callCount += 1
        if callCount == 1 { return "session-old" }
        let ready = callCountWaiters.filter { $0.0 <= callCount }
        callCountWaiters.removeAll { $0.0 <= callCount }
        ready.forEach { $0.1.resume() }
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
