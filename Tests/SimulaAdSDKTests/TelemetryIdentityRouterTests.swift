import XCTest
@testable import SimulaAdSDK

final class TelemetryIdentityRouterTests: XCTestCase {
    func testProviderFirstIdentityUpdatesLiveUntilImperativeTakesOver() {
        let router = TelemetryIdentityRouter()
        let providerToken = TelemetryProviderIdentityToken()
        let provider = TelemetryIdentitySource(sessionId: "provider-session", primaryUserId: "provider-user")
        router.bindProvider(token: providerToken, source: provider)

        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "provider-session", primaryUserId: "provider-user"))

        provider.setIdentity(sessionId: "provider-session-2", primaryUserId: "provider-user-2")
        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "provider-session-2", primaryUserId: "provider-user-2"))

        let imperative = TelemetryIdentitySource(sessionId: "imperative-session", primaryUserId: "imperative-user")
        router.bindImperative(imperative)
        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "imperative-session", primaryUserId: "imperative-user"))

        let replacementToken = TelemetryProviderIdentityToken()
        router.bindProvider(
            token: replacementToken,
            source: TelemetryIdentitySource(sessionId: "replacement", primaryUserId: "replacement-user")
        )
        router.unbindProvider(providerToken)
        router.unbindProvider(replacementToken)
        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "imperative-session", primaryUserId: "imperative-user"))
    }

    func testNestedProviderRemovalRestoresPreviousActiveProvider() {
        let router = TelemetryIdentityRouter()
        let outerToken = TelemetryProviderIdentityToken()
        let innerToken = TelemetryProviderIdentityToken()
        router.bindProvider(
            token: outerToken,
            source: TelemetryIdentitySource(sessionId: "outer-session", primaryUserId: "outer-user")
        )
        router.bindProvider(
            token: innerToken,
            source: TelemetryIdentitySource(sessionId: "inner-session", primaryUserId: "inner-user")
        )

        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "inner-session", primaryUserId: "inner-user"))

        router.unbindProvider(innerToken)
        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "outer-session", primaryUserId: "outer-user"))
    }

    func testRemovingFinalProviderYieldsEmptyIdentity() {
        let router = TelemetryIdentityRouter()
        let token = TelemetryProviderIdentityToken()
        router.bindProvider(
            token: token,
            source: TelemetryIdentitySource(sessionId: "session", primaryUserId: "user")
        )

        router.unbindProvider(token)

        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: nil, primaryUserId: nil))
    }

    func testSameTokenReplacementBecomesLatestAndPreservesOtherProviderOrdering() {
        let router = TelemetryIdentityRouter()
        let firstToken = TelemetryProviderIdentityToken()
        let secondToken = TelemetryProviderIdentityToken()
        router.bindProvider(
            token: firstToken,
            source: TelemetryIdentitySource(sessionId: "session-a", primaryUserId: "user-a")
        )
        router.bindProvider(
            token: secondToken,
            source: TelemetryIdentitySource(sessionId: "session-b", primaryUserId: "user-b")
        )

        router.bindProvider(
            token: firstToken,
            source: TelemetryIdentitySource(sessionId: "session-a2", primaryUserId: "user-a2")
        )
        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "session-a2", primaryUserId: "user-a2"))

        router.unbindProvider(firstToken)
        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "session-b", primaryUserId: "user-b"))
    }

    func testImperativePrecedenceSurvivesProviderBindingAndRemoval() {
        let router = TelemetryIdentityRouter()
        let providerToken = TelemetryProviderIdentityToken()
        let imperative = TelemetryIdentitySource(sessionId: "imperative-session", primaryUserId: "imperative-user")
        router.bindImperative(imperative)
        router.bindProvider(
            token: providerToken,
            source: TelemetryIdentitySource(sessionId: "provider-session", primaryUserId: "provider-user")
        )

        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "imperative-session", primaryUserId: "imperative-user"))
        router.unbindProvider(providerToken)
        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "imperative-session", primaryUserId: "imperative-user"))

        imperative.setIdentity(sessionId: "imperative-session-2", primaryUserId: "imperative-user-2")
        XCTAssertEqual(router.identity(), TelemetryIdentity(sessionId: "imperative-session-2", primaryUserId: "imperative-user-2"))
    }

    func testIdentitySourcePublishesCoherentLiveUpdatesAndClears() {
        let source = TelemetryIdentitySource(sessionId: "session-1", primaryUserId: "user-1")
        XCTAssertEqual(source.identity(), TelemetryIdentity(sessionId: "session-1", primaryUserId: "user-1"))

        source.setSessionId("session-2")
        XCTAssertEqual(source.identity(), TelemetryIdentity(sessionId: "session-2", primaryUserId: "user-1"))
        source.setPrimaryUserId("user-2")
        XCTAssertEqual(source.identity(), TelemetryIdentity(sessionId: "session-2", primaryUserId: "user-2"))
        source.setSessionId(nil)
        source.setPrimaryUserId(nil)
        XCTAssertEqual(source.identity(), TelemetryIdentity(sessionId: nil, primaryUserId: nil))
    }

    func testConcurrentRouterAccessKeepsSessionAndPpidFromOneSnapshot() {
        let router = TelemetryIdentityRouter()
        let tokens = [TelemetryProviderIdentityToken(), TelemetryProviderIdentityToken()]
        router.bindProvider(
            token: tokens[0],
            source: TelemetryIdentitySource(sessionId: "session-0", primaryUserId: "user-0")
        )
        let failures = LockedIdentityFailures()

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for iteration in 0..<2_000 {
                if worker < 2 {
                    let suffix = worker * 2_000 + iteration + 1
                    router.bindProvider(
                        token: tokens[worker],
                        source: TelemetryIdentitySource(
                            sessionId: "session-\(suffix)", primaryUserId: "user-\(suffix)"
                        )
                    )
                    if iteration.isMultiple(of: 5) { router.unbindProvider(tokens[worker]) }
                } else {
                    let identity = router.identity()
                    if identity.sessionId?.replacingOccurrences(of: "session-", with: "")
                        != identity.primaryUserId?.replacingOccurrences(of: "user-", with: "") {
                        failures.append(identity)
                    }
                }
            }
        }

        XCTAssertTrue(failures.isEmpty)
    }

    func testConcurrentSourceUpdatesRemainCoherent() {
        let source = TelemetryIdentitySource(sessionId: "session-0", primaryUserId: "user-0")
        let failures = LockedIdentityFailures()

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for iteration in 0..<2_000 {
                if worker < 2 {
                    let suffix = worker * 2_000 + iteration + 1
                    source.setIdentity(sessionId: "session-\(suffix)", primaryUserId: "user-\(suffix)")
                } else {
                    let identity = source.identity()
                    if identity.sessionId?.replacingOccurrences(of: "session-", with: "")
                        != identity.primaryUserId?.replacingOccurrences(of: "user-", with: "") {
                        failures.append(identity)
                    }
                }
            }
        }

        XCTAssertTrue(failures.isEmpty)
    }
}

private final class LockedIdentityFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TelemetryIdentity] = []

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return values.isEmpty }
    func append(_ value: TelemetryIdentity) { lock.lock(); values.append(value); lock.unlock() }
}
