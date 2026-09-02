import Foundation
import XCTest
@testable import SimulaAdSDK

final class CreativeUserActivationTests: XCTestCase {
    func testGeneratedFallbackUsesCapturedMacrotaskAndPrefersNavigatorActivation() {
        let source = creativeUserActivationScriptSource(nonce: "nonce")

        XCTAssertTrue(source.contains("var nativeSetTimeout = window.setTimeout.bind(window)"))
        XCTAssertTrue(source.contains("trustedEventEpoch"))
        XCTAssertTrue(source.contains("trustedEventTimestamp"))
        XCTAssertTrue(source.contains("function beginKeyboardGesture(event)"))
        XCTAssertFalse(source.contains("queueMicrotask"))
        XCTAssertFalse(source.contains("Promise.then"))
        XCTAssertFalse(source.contains("Promise.resolve"))
        let navigatorCheck = source.range(of: "capturedUserActivation.isActive === true")
        let fallbackCheck = source.range(of: "return trustedEventDispatch")
        XCTAssertNotNil(navigatorCheck)
        XCTAssertNotNil(fallbackCheck)
        if let navigatorCheck, let fallbackCheck {
            XCTAssertLessThan(navigatorCheck.lowerBound, fallbackCheck.lowerBound)
        }
        XCTAssertTrue(source.contains("activation_nonce: 'nonce'"))
    }

    func testGeneratedScriptExposesStablePayloadFreeStoreAPI() {
        let source = creativeUserActivationScriptSource(nonce: "nonce")

        XCTAssertTrue(source.contains("Object.defineProperty(window, 'SimulaAd'"))
        XCTAssertTrue(source.contains("Object.defineProperty(simulaAdAPI, 'openStore'"))
        XCTAssertTrue(source.contains("Object.defineProperty(simulaAdAPI, 'dismissStore'"))
        XCTAssertTrue(source.contains("function openStore()"))
        XCTAssertTrue(source.contains("function dismissStore()"))
        XCTAssertTrue(source.contains("type: 'SIMULA_INTERNAL_STORE_OPEN'"))
        XCTAssertTrue(source.contains("type: 'SIMULA_INTERNAL_STORE_DISMISS'"))
        XCTAssertFalse(source.contains("function openStore(value"))
    }

    func testOpenStoreSharesWindowOpenGestureClaimWhileDismissDoesNotClaim() {
        let source = creativeUserActivationScriptSource(nonce: "nonce")
        let openStore = source.range(of: "function openStore()")
        let dismissStore = source.range(of: "function dismissStore()")
        let windowOpen = source.range(of: "window.open = function()")

        XCTAssertNotNil(openStore)
        XCTAssertNotNil(dismissStore)
        XCTAssertNotNil(windowOpen)
        if let openStore, let dismissStore {
            let body = String(source[openStore.lowerBound..<dismissStore.lowerBound])
            XCTAssertTrue(body.contains("claimGesture"))
        }
        if let dismissStore, let windowOpen {
            let body = String(source[dismissStore.lowerBound..<windowOpen.lowerBound])
            XCTAssertFalse(body.contains("claimGesture"))
            XCTAssertTrue(body.contains("postNative"))
        }
    }

    func testPre164FallbackSurvivesLaterListenerAndClaimsPhysicalGestureOnce() {
        var state = CreativeUserActivationState()
        state.observe(.pointerDown(type: "mouse", trusted: true))
        state.observe(.mouseDown(trusted: true))

        XCTAssertEqual(state.claim(navigatorIsActive: false), .newGesture)
        XCTAssertEqual(state.claim(navigatorIsActive: false), .duplicateGesture)
        state.observe(.click(trusted: true))
        XCTAssertEqual(state.claim(navigatorIsActive: false), .duplicateGesture)

        state.expireMacrotask()
        XCTAssertEqual(state.claim(navigatorIsActive: false), .duplicateGesture)
    }

    func testTouchAndPenRequireCompletionAndPointerCancelDisarms() {
        for pointerType in ["touch", "pen"] {
            var completed = CreativeUserActivationState()
            completed.observe(.pointerDown(type: pointerType, trusted: true))
            XCTAssertEqual(completed.claim(navigatorIsActive: true), .none)
            completed.observe(.pointerUp(type: pointerType, trusted: true))
            XCTAssertEqual(completed.claim(navigatorIsActive: false), .newGesture)

            var cancelled = CreativeUserActivationState()
            cancelled.observe(.pointerDown(type: pointerType, trusted: true))
            cancelled.observe(.pointerCancel(trusted: true))
            XCTAssertEqual(cancelled.claim(navigatorIsActive: true), .none)
            cancelled.observe(.click(trusted: true))
            XCTAssertEqual(cancelled.claim(navigatorIsActive: true), .none)
        }
    }

    func testKeyboardAXAndSyntheticActivationRules() {
        for event in [
            CreativeActivationEvent.keyDown(key: "Escape", repeatKey: false, trusted: true),
            .keyDown(key: "Shift", repeatKey: false, trusted: true),
            .keyDown(key: "Enter", repeatKey: true, trusted: true),
            .keyDown(key: "Enter", repeatKey: false, trusted: false),
            .click(trusted: false),
        ] {
            var rejected = CreativeUserActivationState()
            rejected.observe(event)
            XCTAssertEqual(rejected.claim(navigatorIsActive: false), .none)
        }

        var keyboard = CreativeUserActivationState()
        keyboard.observe(.keyDown(key: "Enter", repeatKey: false, trusted: true))
        XCTAssertEqual(keyboard.claim(navigatorIsActive: false), .newGesture)
        keyboard.observe(.keyDown(key: " ", repeatKey: false, trusted: true))
        XCTAssertEqual(
            keyboard.claim(navigatorIsActive: false),
            .newGesture,
            "a prevented key activation with no compatibility click must not consume the next keydown"
        )

        var accessibility = CreativeUserActivationState()
        accessibility.observe(.click(trusted: true))
        XCTAssertEqual(accessibility.claim(navigatorIsActive: false), .newGesture)
    }

    func testProgrammaticPopupIsAutomaticWithoutClickForEveryCampaignShape() {
        let popup = URL(string: "https://tracker.example/click")!
        let direct = URL(string: "itms-apps://apps.apple.com/app/id375380948")!
        let rawStore = "https://apps.apple.com/app/id375380948"
        let cases: [(CreativeRoutePlan, CreativeRoutePlan)] = [
            (
                creativeRoutePlan(
                    selectedURL: direct,
                    destination: .appstore,
                    storeOpen: .skstoreproduct,
                    campaignStoreURL: nil,
                    fallbackStoreURL: nil,
                    externalClickOnly: false
                ),
                .directStore(url: direct, appID: "375380948", storeOpen: .skstoreproduct)
            ),
            (
                creativeRoutePlan(
                    selectedURL: popup,
                    destination: .appstore,
                    storeOpen: .skstoreproduct,
                    campaignStoreURL: nil,
                    fallbackStoreURL: nil,
                    externalClickOnly: false
                ),
                .resolveTracker(url: popup, storeOpen: .skstoreproduct)
            ),
            (
                creativeRoutePlan(
                    selectedURL: popup,
                    destination: .appstore,
                    storeOpen: .external,
                    campaignStoreURL: rawStore,
                    fallbackStoreURL: nil,
                    externalClickOnly: false
                ),
                .trackerWithStore(
                    tracker: popup,
                    storeURL: URL(string: rawStore)!,
                    appID: "375380948",
                    storeOpen: .external
                )
            ),
        ]

        for (actual, expected) in cases {
            let automaticGuard = AutomaticRouteGuard()
            XCTAssertEqual(
                creativeAutomaticRouteAdmission(
                    isPopup: true,
                    userActivated: false,
                    sameOriginHTTP: false,
                    isDirectStoreNavigation: false,
                    automaticGuard: automaticGuard
                ),
                .automatic
            )
            var clickClaim = CreativeClickClaim()
            XCTAssertNil(clickClaim.claim(
                userActivated: false,
                source: .primaryCTA,
                now: 1
            ))
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(
                creativeAutomaticRouteAdmission(
                    isPopup: true,
                    userActivated: false,
                    sameOriginHTTP: false,
                    isDirectStoreNavigation: false,
                    automaticGuard: automaticGuard
                ),
                .ignored
            )
        }
    }

    func testRealLinkPopupRemainsBillableOnceAndSameOriginAutomaticIsIgnored() {
        let automaticGuard = AutomaticRouteGuard()
        XCTAssertEqual(
            creativeAutomaticRouteAdmission(
                isPopup: true,
                userActivated: true,
                sameOriginHTTP: false,
                isDirectStoreNavigation: false,
                automaticGuard: automaticGuard
            ),
            .billable
        )
        var clickClaim = CreativeClickClaim()
        XCTAssertNotNil(clickClaim.claim(
            userActivated: true,
            source: .primaryCTA,
            now: 1,
            interactionId: "physical"
        ))
        XCTAssertNil(clickClaim.claim(
            userActivated: true,
            source: .primaryCTA,
            now: 1.01,
            interactionId: "duplicate-delegate"
        ))

        XCTAssertEqual(
            creativeAutomaticRouteAdmission(
                isPopup: true,
                userActivated: false,
                sameOriginHTTP: true,
                isDirectStoreNavigation: false,
                automaticGuard: AutomaticRouteGuard()
            ),
            .ignored
        )
        XCTAssertEqual(
            creativeAutomaticRouteAdmission(
                isPopup: false,
                userActivated: false,
                sameOriginHTTP: false,
                isDirectStoreNavigation: false,
                automaticGuard: AutomaticRouteGuard()
            ),
            .ignored,
            "non-popup .other navigation must never become a click or automatic route"
        )
    }

    func testSameFrameProgrammaticStoreNavigationIsAutomaticAndHonorsStoreOpen() {
        let storeURL = URL(string: "itms-apps://apps.apple.com/app/id375380948")!
        let automaticGuard = AutomaticRouteGuard()
        XCTAssertEqual(
            creativeAutomaticRouteAdmission(
                isPopup: false,
                userActivated: false,
                sameOriginHTTP: false,
                isDirectStoreNavigation: true,
                automaticGuard: automaticGuard
            ),
            .automatic
        )
        var clickClaim = CreativeClickClaim()
        XCTAssertNil(clickClaim.claim(
            userActivated: false,
            source: .primaryCTA,
            now: 1
        ))

        XCTAssertEqual(
            creativeRoutePlan(
                selectedURL: storeURL,
                destination: .appstore,
                storeOpen: .skstoreproduct,
                campaignStoreURL: nil,
                fallbackStoreURL: nil,
                externalClickOnly: false
            ),
            .directStore(url: storeURL, appID: "375380948", storeOpen: .skstoreproduct)
        )
        XCTAssertEqual(
            creativeRoutePlan(
                selectedURL: storeURL,
                destination: .appstore,
                storeOpen: .external,
                campaignStoreURL: nil,
                fallbackStoreURL: nil,
                externalClickOnly: false
            ),
            .directStore(url: storeURL, appID: "375380948", storeOpen: .external)
        )
        XCTAssertEqual(
            creativeAutomaticRouteAdmission(
                isPopup: false,
                userActivated: false,
                sameOriginHTTP: false,
                isDirectStoreNavigation: true,
                automaticGuard: automaticGuard
            ),
            .ignored,
            "one document can route at most one automatic store navigation"
        )
    }

    func testFallbackStorePrecedenceAndExternalBranchAreReachable() {
        let tracker = URL(string: "https://tracker.example/click")!
        let campaignStore = URL(string: "https://apps.apple.com/app/id111")!
        let fallbackStore = URL(string: "itms-apps://apps.apple.com/app/id222")!

        XCTAssertEqual(
            creativeRoutePlan(
                selectedURL: tracker,
                destination: .appstore,
                storeOpen: .external,
                campaignStoreURL: campaignStore.absoluteString,
                fallbackStoreURL: fallbackStore,
                externalClickOnly: false
            ),
            .trackerWithStore(
                tracker: tracker,
                storeURL: campaignStore,
                appID: "111",
                storeOpen: .external
            )
        )
        XCTAssertEqual(
            creativeRoutePlan(
                selectedURL: tracker,
                destination: .appstore,
                storeOpen: .skstoreproduct,
                campaignStoreURL: nil,
                fallbackStoreURL: fallbackStore,
                externalClickOnly: false
            ),
            .trackerWithStore(
                tracker: tracker,
                storeURL: fallbackStore,
                appID: "222",
                storeOpen: .skstoreproduct
            )
        )
    }

    func testDirectStoreValidationRequiresAppleHostAndPathID() {
        XCTAssertEqual(
            directAppStoreID(from: URL(string: "itms-apps://apps.apple.com/app/id375380948")!),
            "375380948"
        )
        XCTAssertEqual(
            directAppStoreID(from: URL(string: "itms-appss://itunes.apple.com/app/id246813579")!),
            "246813579"
        )
        XCTAssertTrue(isDirectAppStoreScheme("ITMS-APPSS"))
        for value in [
            "itms-apps://evil.example/app/id375380948",
            "itms-appss://evil.example/app/id375380948",
            "itms-apps://apps.apple.com.evil.example/app/id375380948",
            "itms-appss://apps.apple.com/app/no-id",
            "itms-apps://apps.apple.com/app?item=id375380948",
            "itms-apps://apps.apple.com/app/id375380948evil",
        ] {
            XCTAssertNil(directAppStoreID(from: URL(string: value)!))
        }
    }
}
