import XCTest
@testable import SimulaAdSDK

final class TelemetryIdentityRouterTests: XCTestCase {
    func testProviderFirstIdentityUpdatesLiveUntilMatchingImperativeTakesOver() {
        let router = TelemetryIdentityRouter()
        let providerToken = TelemetryProviderIdentityToken()
        let provider = source(key: "key-a", session: "provider-session", user: "provider-user")
        router.bindProvider(token: providerToken, source: provider)

        XCTAssertEqual(
            router.identity(apiKey: "key-a"),
            TelemetryIdentity(sessionId: "provider-session", primaryUserId: "provider-user")
        )

        provider.setIdentity(sessionId: "provider-session-2", primaryUserId: "provider-user-2")
        XCTAssertEqual(
            router.identity(apiKey: "key-a"),
            TelemetryIdentity(sessionId: "provider-session-2", primaryUserId: "provider-user-2")
        )

        let imperative = source(key: "key-a", session: "imperative-session", user: "imperative-user")
        router.bindImperative(imperative)
        XCTAssertEqual(
            router.identity(apiKey: "key-a"),
            TelemetryIdentity(sessionId: "imperative-session", primaryUserId: "imperative-user")
        )
    }

    func testDistinctKeyImperativeFallsBackToLatestMatchingProvider() {
        let router = TelemetryIdentityRouter()
        let keyAToken = TelemetryProviderIdentityToken()
        let keyBToken = TelemetryProviderIdentityToken()
        router.bindProvider(token: keyAToken, source: source(key: "key-a", session: "a", user: "user-a"))
        router.bindProvider(token: keyBToken, source: source(key: "key-b", session: "b", user: "user-b"))
        router.bindImperative(source(key: "key-b", session: "imperative-b", user: "imperative-user-b"))

        XCTAssertEqual(
            router.identity(apiKey: "key-a"),
            TelemetryIdentity(sessionId: "a", primaryUserId: "user-a")
        )
        XCTAssertEqual(
            router.identity(apiKey: "key-b"),
            TelemetryIdentity(sessionId: "imperative-b", primaryUserId: "imperative-user-b")
        )
        XCTAssertEqual(
            router.identity(apiKey: "key-c"),
            TelemetryIdentity(sessionId: nil, primaryUserId: nil)
        )
    }

    func testLatestProviderSelectionAndRemovalAreScopedByKey() {
        let router = TelemetryIdentityRouter()
        let outerToken = TelemetryProviderIdentityToken()
        let otherKeyToken = TelemetryProviderIdentityToken()
        let innerToken = TelemetryProviderIdentityToken()
        router.bindProvider(token: outerToken, source: source(key: "key-a", session: "outer", user: "outer-user"))
        router.bindProvider(token: otherKeyToken, source: source(key: "key-b", session: "other", user: "other-user"))
        router.bindProvider(token: innerToken, source: source(key: "key-a", session: "inner", user: "inner-user"))

        XCTAssertEqual(
            router.identity(apiKey: "key-a"),
            TelemetryIdentity(sessionId: "inner", primaryUserId: "inner-user")
        )
        router.unbindProvider(innerToken)
        XCTAssertEqual(
            router.identity(apiKey: "key-a"),
            TelemetryIdentity(sessionId: "outer", primaryUserId: "outer-user")
        )
        XCTAssertEqual(
            router.identity(apiKey: "key-b"),
            TelemetryIdentity(sessionId: "other", primaryUserId: "other-user")
        )
    }

    func testSameTokenReplacementPreservesOriginalProviderOrder() {
        let router = TelemetryIdentityRouter()
        let firstToken = TelemetryProviderIdentityToken()
        let secondToken = TelemetryProviderIdentityToken()
        router.bindProvider(token: firstToken, source: source(key: "key-a", session: "a", user: "user-a"))
        router.bindProvider(token: secondToken, source: source(key: "key-a", session: "b", user: "user-b"))

        router.bindProvider(token: firstToken, source: source(key: "key-a", session: "a2", user: "user-a2"))
        XCTAssertEqual(
            router.identity(apiKey: "key-a"),
            TelemetryIdentity(sessionId: "b", primaryUserId: "user-b")
        )

        router.unbindProvider(secondToken)
        XCTAssertEqual(
            router.identity(apiKey: "key-a"),
            TelemetryIdentity(sessionId: "a2", primaryUserId: "user-a2")
        )
    }

    func testIdentitySourcePublishesCoherentLiveUpdatesAndClears() {
        let identitySource = source(key: "key-a", session: "session-1", user: "user-1")
        XCTAssertEqual(
            identitySource.identity(),
            TelemetryIdentity(sessionId: "session-1", primaryUserId: "user-1")
        )

        identitySource.setSessionId("session-2")
        identitySource.setPrimaryUserId("user-2")
        XCTAssertEqual(
            identitySource.identity(),
            TelemetryIdentity(sessionId: "session-2", primaryUserId: "user-2")
        )
        identitySource.setSessionId(nil)
        identitySource.setPrimaryUserId(nil)
        XCTAssertEqual(identitySource.identity(), TelemetryIdentity(sessionId: nil, primaryUserId: nil))
    }

    func testFlushIdentityUsesOnePrivacySnapshotAcrossConcurrentTransition() {
        let router = TelemetryIdentityRouter()
        let token = TelemetryProviderIdentityToken()
        router.bindProvider(token: token, source: source(key: "key-a", session: "session", user: "user"))
        let privacy = TransitioningPrivacySnapshot()

        let identity = Telemetry.resolveFlushIdentity(
            apiKey: "key-a",
            router: router,
            privacySnapshot: { privacy.snapshot() }
        )

        XCTAssertEqual(
            identity,
            TelemetryIdentity(sessionId: "session", primaryUserId: "user", advertisingId: "old-idfa")
        )
        XCTAssertEqual(privacy.readCount, 1)
    }

    func testConcurrentRouterAccessKeepsSessionAndPpidFromOneMatchingSource() async {
        let router = TelemetryIdentityRouter()
        let tokens = [TelemetryProviderIdentityToken(), TelemetryProviderIdentityToken()]
        router.bindProvider(token: tokens[0], source: source(key: "key-a", session: "session-0", user: "user-0"))
        let failures = LockedIdentityFailures()

        await runCoordinatedWorkers(count: 8) { worker in
            for iteration in 0..<2_000 {
                if worker < 2 {
                    let suffix = worker * 2_000 + iteration + 1
                    router.bindProvider(
                        token: tokens[worker],
                        source: self.source(
                            key: "key-a",
                            session: "session-\(suffix)",
                            user: "user-\(suffix)"
                        )
                    )
                    if iteration.isMultiple(of: 5) { router.unbindProvider(tokens[worker]) }
                } else {
                    failures.check(router.identity(apiKey: "key-a"))
                }
            }
        }

        XCTAssertTrue(failures.isEmpty)
    }

    func testConcurrentSourceUpdatesRemainCoherent() async {
        let identitySource = source(key: "key-a", session: "session-0", user: "user-0")
        let failures = LockedIdentityFailures()

        await runCoordinatedWorkers(count: 8) { worker in
            for iteration in 0..<2_000 {
                if worker < 2 {
                    let suffix = worker * 2_000 + iteration + 1
                    identitySource.setIdentity(sessionId: "session-\(suffix)", primaryUserId: "user-\(suffix)")
                } else {
                    failures.check(identitySource.identity())
                }
            }
        }

        XCTAssertTrue(failures.isEmpty)
    }

    private func source(key: String, session: String?, user: String?) -> TelemetryIdentitySource {
        TelemetryIdentitySource(apiKey: key, sessionId: session, primaryUserId: user)
    }
}

private final class TransitioningPrivacySnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private let transitionQueue = DispatchQueue(label: "telemetry-privacy-transition")
    private var current = ConsentSnapshot(
        hasPrivacyConsent: true,
        advertisingId: "old-idfa"
    )
    private var reads = 0

    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }

    func snapshot() -> ConsentSnapshot {
        lock.lock()
        reads += 1
        let result = current
        lock.unlock()
        transitionQueue.sync {
            lock.lock()
            current = ConsentSnapshot(hasPrivacyConsent: false)
            lock.unlock()
        }
        return result
    }
}

private final class LockedIdentityFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TelemetryIdentity] = []

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return values.isEmpty }

    func check(_ identity: TelemetryIdentity) {
        let session = identity.sessionId?.replacingOccurrences(of: "session-", with: "")
        let user = identity.primaryUserId?.replacingOccurrences(of: "user-", with: "")
        guard session != user else { return }
        lock.lock(); values.append(identity); lock.unlock()
    }
}

private func runCoordinatedWorkers(
    count: Int,
    work: @escaping @Sendable (Int) -> Void
) async {
    let queue = DispatchQueue(label: "telemetry-identity-workers", attributes: .concurrent)
    let ready = DispatchGroup()
    let completed = DispatchGroup()
    let start = DispatchSemaphore(value: 0)
    for worker in 0..<count {
        ready.enter()
        completed.enter()
        queue.async {
            ready.leave()
            start.wait()
            work(worker)
            completed.leave()
        }
    }
    await waitForDispatchGroup(ready, queueLabel: "telemetry-identity-ready")
    for _ in 0..<count { start.signal() }
    await waitForDispatchGroup(completed, queueLabel: "telemetry-identity-completed")
}

private func waitForDispatchGroup(_ group: DispatchGroup, queueLabel: String) async {
    await withCheckedContinuation { continuation in
        group.notify(queue: DispatchQueue(label: queueLabel)) { continuation.resume() }
    }
}
