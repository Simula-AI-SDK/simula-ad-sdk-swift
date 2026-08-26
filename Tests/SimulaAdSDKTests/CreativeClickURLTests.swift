import Foundation
import XCTest
@testable import SimulaAdSDK

final class CreativeClickURLTests: XCTestCase {
    private let activationNonce = "activation-nonce"

    private func ctaBody(url: String, nonce: String? = "activation-nonce") -> String {
        var object: [String: Any] = ["type": CreativeCTAOpenMessage.type, "url": url]
        if let nonce { object["activation_nonce"] = nonce }
        let data = try? JSONSerialization.data(withJSONObject: object)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func testTopLevelTrackerWinsOverHTMLEscapedURL() {
        let fallback = URL(string: "https://tracker.example/click?a=1&amp;b=2")!

        let selected = preferredCreativeClickURL(
            trackingUrl: "https://tracker.example/click?a=1&b=2",
            fallback: fallback
        )

        XCTAssertEqual(selected.absoluteString, "https://tracker.example/click?a=1&b=2")
    }

    func testMissingOrBlankTrackerFallsBackToEmbeddedURL() {
        let fallback = URL(string: "https://example.com/landing")!

        XCTAssertEqual(preferredCreativeClickURL(trackingUrl: nil, fallback: fallback), fallback)
        XCTAssertEqual(preferredCreativeClickURL(trackingUrl: "", fallback: fallback), fallback)
        XCTAssertEqual(preferredCreativeClickURL(trackingUrl: "   ", fallback: fallback), fallback)
    }

    func testDualWebKitDelegatesClaimOneCallbackAndRoute() {
        var claim = CreativeClickClaim()

        let navigationDelegate = claim.claim(
            userActivated: true,
            source: .primaryCTA,
            now: 10,
            interactionId: "stable"
        )
        let uiDelegate = claim.claim(
            userActivated: true,
            source: .primaryCTA,
            now: 10.01,
            interactionId: "duplicate"
        )

        XCTAssertEqual(navigationDelegate, ClickInteraction(id: "stable", source: .primaryCTA))
        XCTAssertNil(uiDelegate)
    }

    func testProgrammaticWindowOpenCannotClaimClick() {
        var claim = CreativeClickClaim()

        XCTAssertNil(claim.claim(
            userActivated: false,
            source: .primaryCTA,
            now: 10,
            interactionId: "programmatic"
        ))
        XCTAssertEqual(
            claim.claim(
                userActivated: true,
                source: .primaryCTA,
                now: 10.01,
                interactionId: "gesture"
            ),
            ClickInteraction(id: "gesture", source: .primaryCTA)
        )
    }

    func testAuthenticatedCTAOpenPreservesURLAndFragment() {
        let body = ctaBody(url: "https://tracker.example/click?a=1#campaign&step=2")
        guard case .accepted(let url) = CreativeCTAOpenMessage.admission(
            for: body,
            expectedNonce: activationNonce,
            destination: .appstore,
            externalClickOnly: false
        ) else { return XCTFail("expected CTA admission") }

        XCTAssertEqual(url.absoluteString, "https://tracker.example/click?a=1#campaign&step=2")
    }

    func testStructuredCTAOpenAcceptsEveryNativeStoreAndWebScheme() {
        let values = [
            "https://example.com/path",
            "http://example.com/path",
            "itms-apps://apps.apple.com/app/id123",
            "itms://itunes.apple.com/app/id123",
        ]

        for value in values {
            let body = ctaBody(url: value)
            XCTAssertEqual(
                CreativeCTAOpenMessage.admission(
                    for: body,
                    expectedNonce: activationNonce,
                    destination: .appstore,
                    externalClickOnly: false
                ),
                .accepted(URL(string: value)!)
            )
        }
    }

    func testStructuredCTAOpenCustomSchemeFollowsDestinationPolicy() {
        let body = ctaBody(url: "advertiser-app://offer/42#details")
        let url = URL(string: "advertiser-app://offer/42#details")!

        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: body, expectedNonce: activationNonce, destination: .web, externalClickOnly: false
            ),
            .accepted(url)
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: body, expectedNonce: activationNonce, destination: .appstore, externalClickOnly: true
            ),
            .accepted(url)
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: body, expectedNonce: activationNonce, destination: .appstore, externalClickOnly: false
            ),
            .rejected
        )
    }

    func testStructuredCTAOpenRejectsMalformedUnsafeAndRelativeDestinations() {
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: ctaBody(url: "javascript:alert(1)"),
                expectedNonce: activationNonce,
                destination: .web,
                externalClickOnly: true
            ),
            .rejected
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: ctaBody(url: "/relative"),
                expectedNonce: activationNonce,
                destination: .web,
                externalClickOnly: true
            ),
            .rejected
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: #"{"type":"SIMULA_CTA_OPEN","activation_nonce":"activation-nonce"}"#,
                expectedNonce: activationNonce,
                destination: .appstore,
                externalClickOnly: false
            ),
            .rejected
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: #"{"type":"OTHER","url":"https://example.com"}"#,
                expectedNonce: activationNonce,
                destination: .appstore,
                externalClickOnly: false
            ),
            .notMessage
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: "not-json",
                expectedNonce: activationNonce,
                destination: .appstore,
                externalClickOnly: false
            ),
            .notMessage
        )
    }

    func testMissingAndWrongActivationNonceAreRejected() {
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: ctaBody(url: "https://example.com", nonce: nil),
                expectedNonce: activationNonce,
                destination: .web,
                externalClickOnly: false
            ),
            .rejected
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: ctaBody(url: "https://example.com", nonce: "other-webview"),
                expectedNonce: activationNonce,
                destination: .web,
                externalClickOnly: false
            ),
            .rejected
        )
    }

    func testAuthenticatedMessageAndDelegateStillClaimExactlyOnce() {
        var claim = CreativeClickClaim()

        let scriptMessage = claim.claim(
            userActivated: true,
            source: .primaryCTA,
            now: 10,
            interactionId: "script"
        )
        let lateDelegate = claim.claim(
            userActivated: true,
            source: .primaryCTA,
            now: 10.01,
            interactionId: "delegate"
        )

        XCTAssertEqual(scriptMessage, ClickInteraction(id: "script", source: .primaryCTA))
        XCTAssertNil(lateDelegate)
    }

    func testStorePromptGuardRejectsDuplicatesAndKeepsFailedBilledRouteClaimed() {
        let guardState = StorePromptGestureGuard()

        XCTAssertTrue(guardState.claim())
        XCTAssertFalse(guardState.claim())
        guard let generation = guardState.complete() else {
            return XCTFail("persisted click needs bounded release ownership")
        }
        XCTAssertFalse(guardState.claim())
        guardState.releaseRoutedFallback(generation: generation)
        XCTAssertTrue(guardState.claim())
    }

    func testStorePromptGuardHoldsSuccessfulRouteUntilExternalReturn() {
        let guardState = StorePromptGestureGuard()

        XCTAssertTrue(guardState.claim())
        guardState.releaseAfterExternalReturn()
        XCTAssertFalse(guardState.claim(), "a foreground notification must not release pending persistence")
        let generation = guardState.complete()
        XCTAssertFalse(guardState.claim())
        guardState.releaseAfterExternalReturn()
        XCTAssertTrue(guardState.claim())
        if let generation {
            guardState.releaseRoutedFallback(generation: generation)
        }
        XCTAssertFalse(guardState.claim(), "a stale fallback cannot release the next pending gesture")
    }

    func testStorePromptGuardBoundedFallbackReleasesOptimisticRoute() {
        let guardState = StorePromptGestureGuard()

        XCTAssertTrue(guardState.claim())
        guard let generation = guardState.complete() else {
            return XCTFail("successful route needs a bounded release generation")
        }
        XCTAssertFalse(guardState.claim())
        guardState.releaseRoutedFallback(generation: generation)
        XCTAssertTrue(guardState.claim())
    }

    func testAutomaticRouteClaimsExactlyOnceWithoutCreatingClickInteraction() {
        let guardState = AutomaticRouteGuard()

        XCTAssertTrue(guardState.claim())
        XCTAssertFalse(guardState.claim(), "a failed external open must not loop automatic redirects")
    }

    func testFullscreenDismissRequiresUnlockedGateAndNoPendingClick() {
        XCTAssertFalse(canDismissFullscreen(dismissUnlocked: false, clickHandoffPending: false))
        XCTAssertFalse(canDismissFullscreen(dismissUnlocked: false, clickHandoffPending: true))
        XCTAssertFalse(canDismissFullscreen(dismissUnlocked: true, clickHandoffPending: true))
        XCTAssertTrue(canDismissFullscreen(dismissUnlocked: true, clickHandoffPending: false))
    }

    func testFullscreenClickHandoffOwnersDoNotUnlockEachOther() {
        var state = FullscreenClickHandoffState()
        XCTAssertFalse(state.isPending)

        state.set(.creative, pending: true)
        state.set(.storePrompt, pending: true)
        XCTAssertTrue(state.isPending(.creative))
        XCTAssertTrue(state.isPending(.storePrompt))

        state.set(.creative, pending: false)
        XCTAssertTrue(state.isPending, "store prompt still owns close admission")
        state.set(.storePrompt, pending: false)
        XCTAssertFalse(state.isPending)

        state.set(.creative, pending: true)
        state.set(.creative, pending: true)
        state.reset()
        XCTAssertFalse(state.isPending)
    }

    func testDeferredRouteRejectsStaleCompletionAfterReplacement() {
        let guardState = DeferredRouteGuard()
        let staleGeneration = guardState.begin()
        let currentGeneration = guardState.begin()

        XCTAssertFalse(guardState.consume(staleGeneration))
        XCTAssertTrue(guardState.consume(currentGeneration))
        XCTAssertFalse(guardState.consume(currentGeneration))
    }

    func testDetachedRouteIsSuppressedAndCannotConsumeReplacementOwner() {
        let guardState = DeferredRouteGuard()
        let detached = guardState.begin()
        guardState.cancel()
        let replacement = guardState.begin()
        var routes = 0

        if guardState.consume(detached) { routes += 1 }
        XCTAssertEqual(routes, 0)
        XCTAssertTrue(guardState.consume(replacement))
    }

    func testBoundedCompletionFiresRouteOnlyOnceAfterOwnerRelease() {
        let routed = expectation(description: "route")
        routed.expectedFulfillmentCount = 1
        var owner: CreativeRouteOwner? = CreativeRouteOwner(destination: "app-store-id")
        weak var weakOwner = owner
        let destination = owner?.destination
        let gate = BoundedCompletion {
            XCTAssertEqual(destination, "app-store-id")
            routed.fulfill()
        }
        owner = nil

        gate.complete()
        gate.complete()

        XCTAssertNil(weakOwner)
        wait(for: [routed], timeout: 0.1)
    }
}

private final class CreativeRouteOwner {
    let destination: String
    init(destination: String) { self.destination = destination }
}
