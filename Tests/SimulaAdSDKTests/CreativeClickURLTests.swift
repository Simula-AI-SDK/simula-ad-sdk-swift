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

    func testTrustedActivationAllowsWindowOpenOtherButIsSingleUseAndExpires() {
        var activation = CreativeUserActivation()
        activation.noteTrustedActivation(now: 5)

        XCTAssertTrue(activation.consume(explicitLinkActivation: false, now: 5.1))
        XCTAssertFalse(activation.consume(explicitLinkActivation: false, now: 5.2))

        activation.noteTrustedActivation(now: 10)
        XCTAssertFalse(activation.consume(explicitLinkActivation: false, now: 11.1))
        XCTAssertTrue(activation.consume(explicitLinkActivation: true, now: 20))
    }

    func testExternalWindowOpenOtherClaimsWhenTrustedMarkerProvesGesture() {
        var activation = CreativeUserActivation()
        var clickClaim = CreativeClickClaim()
        activation.noteTrustedActivation(now: 10)

        let interaction = clickClaim.claim(
            userActivated: activation.consume(explicitLinkActivation: false, now: 10.1),
            source: .primaryCTA,
            now: 10.1,
            interactionId: "trusted-window-open"
        )

        XCTAssertEqual(
            interaction,
            ClickInteraction(id: "trusted-window-open", source: .primaryCTA)
        )
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
