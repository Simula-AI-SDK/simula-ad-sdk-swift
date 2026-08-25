import Foundation
import XCTest
@testable import SimulaAdSDK

final class CreativeClickURLTests: XCTestCase {
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

    func testStructuredCTAOpenPreservesURLAndFragmentBeforeClaiming() {
        var clickClaim = CreativeClickClaim()
        let body = #"{"type":"SIMULA_CTA_OPEN","url":"https://tracker.example/click?a=1#campaign&step=2"}"#
        guard case .accepted(let url) = CreativeCTAOpenMessage.admission(
            for: body,
            destination: .appstore,
            externalClickOnly: false
        ) else { return XCTFail("expected CTA admission") }

        let interaction = clickClaim.claim(
            userActivated: true,
            source: .primaryCTA,
            now: 10.1,
            interactionId: "script-window-open"
        )

        XCTAssertEqual(url.absoluteString, "https://tracker.example/click?a=1#campaign&step=2")
        XCTAssertEqual(
            interaction,
            ClickInteraction(id: "script-window-open", source: .primaryCTA)
        )
    }

    func testStructuredCTAOpenAcceptsEveryNativeStoreAndWebScheme() {
        let values = [
            "https://example.com/path",
            "http://example.com/path",
            "itms-apps://apps.apple.com/app/id123",
            "itms://itunes.apple.com/app/id123",
        ]

        for value in values {
            let body = #"{"type":"SIMULA_CTA_OPEN","url":"\#(value)"}"#
            XCTAssertEqual(
                CreativeCTAOpenMessage.admission(
                    for: body,
                    destination: .appstore,
                    externalClickOnly: false
                ),
                .accepted(URL(string: value)!)
            )
        }
    }

    func testStructuredCTAOpenCustomSchemeFollowsDestinationPolicy() {
        let body = #"{"type":"SIMULA_CTA_OPEN","url":"advertiser-app://offer/42#details"}"#
        let url = URL(string: "advertiser-app://offer/42#details")!

        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(for: body, destination: .web, externalClickOnly: false),
            .accepted(url)
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(for: body, destination: .appstore, externalClickOnly: true),
            .accepted(url)
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(for: body, destination: .appstore, externalClickOnly: false),
            .rejected
        )
    }

    func testStructuredCTAOpenRejectsMalformedUnsafeAndRelativeDestinations() {
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: #"{"type":"SIMULA_CTA_OPEN","url":"javascript:alert(1)"}"#,
                destination: .web,
                externalClickOnly: true
            ),
            .rejected
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: #"{"type":"SIMULA_CTA_OPEN","url":"/relative"}"#,
                destination: .web,
                externalClickOnly: true
            ),
            .rejected
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: #"{"type":"SIMULA_CTA_OPEN"}"#,
                destination: .appstore,
                externalClickOnly: false
            ),
            .rejected
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: #"{"type":"OTHER","url":"https://example.com"}"#,
                destination: .appstore,
                externalClickOnly: false
            ),
            .notMessage
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: "not-json",
                destination: .appstore,
                externalClickOnly: false
            ),
            .notMessage
        )
    }

    func testStructuredAndDelegateCallbacksStillClaimExactlyOnce() {
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

    func testStorePromptGuardRejectsDuplicatesAndReleasesFailedRoute() {
        let guardState = StorePromptGestureGuard()

        XCTAssertTrue(guardState.claim())
        XCTAssertFalse(guardState.claim())
        guardState.complete(routed: false)
        XCTAssertTrue(guardState.claim())
    }

    func testStorePromptGuardHoldsSuccessfulRouteUntilExternalReturn() {
        let guardState = StorePromptGestureGuard()

        XCTAssertTrue(guardState.claim())
        guardState.releaseAfterExternalReturn()
        XCTAssertFalse(guardState.claim(), "a foreground notification must not release pending persistence")
        let generation = guardState.complete(routed: true)
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
        guard let generation = guardState.complete(routed: true) else {
            return XCTFail("successful route needs a bounded release generation")
        }
        XCTAssertFalse(guardState.claim())
        guardState.releaseRoutedFallback(generation: generation)
        XCTAssertTrue(guardState.claim())
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
