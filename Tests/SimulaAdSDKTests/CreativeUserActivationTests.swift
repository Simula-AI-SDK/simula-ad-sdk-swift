import Foundation
import XCTest
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
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
        XCTAssertTrue(source.contains("var activationNonce = 'nonce'"))
        XCTAssertTrue(source.contains("activation_nonce: activationNonce"))
    }

    func testEveryActivationFrameCarriesValidatedClickSourceForSrcdoc() {
        let source = creativeUserActivationScriptSource(
            nonce: "nonce",
            clickSource: .fallbackCTA
        )

        XCTAssertTrue(source.contains("var slotClickSource = 'fallback_cta'"))
        XCTAssertTrue(source.contains("window.simulaClickInteraction(slotClickSource, true)"))
        XCTAssertFalse(source.contains("window.__simulaNativeSlotSource"))
    }

    func testGeneratedScriptExposesStablePayloadFreeStoreAPI() {
        let source = creativeUserActivationScriptSource(nonce: "nonce")

        XCTAssertTrue(source.contains("Object.defineProperty(window, 'SimulaAd'"))
        XCTAssertTrue(source.contains("Object.defineProperty(simulaAdAPI, 'openStore'"))
        XCTAssertTrue(source.contains("Object.defineProperty(simulaAdAPI, 'dismissStore'"))
        XCTAssertTrue(source.contains("Object.defineProperty(simulaAdAPI, 'showInstallBanner'"))
        XCTAssertTrue(source.contains("function openStore()"))
        XCTAssertTrue(source.contains("Object.defineProperty(simulaAdAPI, 'openCTA'"))
        XCTAssertTrue(source.contains("function dismissStore()"))
        XCTAssertTrue(source.contains("function showInstallBanner()"))
        XCTAssertTrue(source.contains("type: 'SIMULA_INTERNAL_STORE_OPEN'"))
        XCTAssertTrue(source.contains("type: 'SIMULA_INTERNAL_STORE_DISMISS'"))
        XCTAssertTrue(source.contains("type: 'SIMULA_INTERNAL_STORE_OVERLAY_SHOW'"))
        XCTAssertTrue(source.contains("postNative(nativeStringify(withIdentity(message, identity)))"))
        XCTAssertTrue(source.contains("postNative(nativeStringify({"))
        XCTAssertTrue(source.contains("function withIdentity(message, identity)"))
        XCTAssertTrue(source.contains("window.simulaClickInteraction(slotClickSource, true)"))
        XCTAssertTrue(source.contains("typeof identity === 'string'"))
        XCTAssertFalse(source.contains("__simulaMintClickIdentity"))
        XCTAssertTrue(source.contains("type: 'SIMULA_CTA_OPEN'"))
        XCTAssertFalse(source.contains("CTA_CLICK"))
        XCTAssertFalse(source.contains("activation_nonce: 'nonce'"))
    }

    func testGeneratedScriptOmitsStoreAPIOnUnsupportedSurfaces() {
        let source = creativeUserActivationScriptSource(nonce: "nonce", exposesStoreAPI: false)

        XCTAssertFalse(source.contains("Object.defineProperty(window, 'SimulaAd'"))
        XCTAssertFalse(source.contains("SIMULA_INTERNAL_STORE_OPEN"))
        XCTAssertFalse(source.contains("SIMULA_INTERNAL_STORE_DISMISS"))
        XCTAssertFalse(source.contains("SIMULA_INTERNAL_STORE_OVERLAY_SHOW"))
        XCTAssertTrue(source.contains("window.open = function()"))
    }

    func testDocumentStartCTAInterceptionLeavesSameOriginAndInternalNavigationToWebKit() {
        let source = creativeUserActivationScriptSource(nonce: "nonce")

        XCTAssertTrue(source.contains("function documentHTTPOrigin()"))
        XCTAssertTrue(source.contains("function isSameOriginCTA(url)"))
        XCTAssertTrue(source.contains("function isInternalCTA(url)"))
        XCTAssertTrue(source.contains("function isExternalCTA(url)"))
        XCTAssertTrue(source.contains("protocol === 'http:' || protocol === 'https:'"))
        for scheme in ["about:", "data:", "blob:", "javascript:"] {
            XCTAssertTrue(source.contains("protocol === '\(scheme)'"), scheme)
        }
        XCTAssertTrue(source.contains("if (!url || !isExternalCTA(url)) { return false; }"))
        XCTAssertTrue(source.contains("return originalOpen.apply(window, arguments);"))
        XCTAssertTrue(source.contains("if (forwardCTA(anchor.href)) { event.preventDefault(); }"))
        XCTAssertFalse(source.contains("window.__simulaNativeSlotSource"), "srcdoc frames use the installed semantic source")
    }

    #if canImport(JavaScriptCore)
    private func activationContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        let resolve: @convention(block) (String, String) -> String = { value, base in
            guard let url = URL(string: value, relativeTo: URL(string: base))?.absoluteURL,
                  let scheme = url.scheme else { return "null" }
            let origin = ["http", "https"].contains(scheme)
                ? "\(scheme)://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")" : "null"
            let fields = ["href": url.absoluteString, "protocol": scheme + ":", "origin": origin]
            guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return "null" }
            return String(data: data, encoding: .utf8) ?? "null"
        }
        context.setObject(resolve, forKeyedSubscript: "resolveURL" as NSString)
        context.evaluateScript("""
        var messages = [], listeners = [], nativeOpens = 0;
        var document = {baseURI: 'https://creative.example/game'};
        var navigator = {userActivation: {isActive: false}};
        var window = {
          location: {origin: 'https://creative.example'},
          open: function() { nativeOpens++; }, setTimeout: function() {},
          webkit: {messageHandlers: {simulaSDK: {postMessage: function(value) { messages.push(JSON.parse(value)); }}}},
          addEventListener: function(type, callback, capture) { listeners.push({type:type, callback:callback, capture:capture}); }
        };
        function URL(value, base) {
          var parsed = JSON.parse(resolveURL(String(value), base || document.baseURI));
          if (!parsed) { throw Error('invalid URL'); }
          this.href = parsed.href; this.protocol = parsed.protocol; this.origin = parsed.origin;
        }
        function click(url, stoppedAtTarget, trusted) {
          var anchor = {href:url, target:'_blank'};
          var event = {type:'click', isTrusted:trusted, timeStamp:1,
            target:{closest:function() { return anchor; }}, preventDefault:function() {}};
          listeners.filter(function(l) { return l.type === 'click' && l.capture; }).forEach(function(l) { l.callback(event); });
          if (!stoppedAtTarget) {
            listeners.filter(function(l) { return l.type === 'click' && !l.capture; }).forEach(function(l) { l.callback(event); });
          }
        }
        """)
        context.evaluateScript(creativeUserActivationScriptSource(nonce: "nonce"))
        XCTAssertNil(context.exception)
        return context
    }

    func testTrustedStoreSchemeClickSurvivesCreativeStopPropagationAndDeduplicates() throws {
        for scheme in ["itms-apps", "itms-appss", "https"] {
            let context = try activationContext()
            context.evaluateScript("click('\(scheme)://apps.apple.com/app/id375380948', true, true)")
            context.evaluateScript("window.open('\(scheme)://apps.apple.com/app/id375380948')")
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("messages.length")?.toInt32(), 1)
            XCTAssertEqual(context.evaluateScript("messages[0].type")?.toString(), "SIMULA_CTA_OPEN")
            XCTAssertEqual(context.evaluateScript("nativeOpens")?.toInt32(), 0)
        }
    }

    func testUntrustedAndInternalClicksDoNotClaimNativeCTA() throws {
        for url in ["https://creative.example/next", "about:blank", "javascript:void(0)", "custom://app"] {
            let context = try activationContext()
            context.setObject(url, forKeyedSubscript: "targetURL" as NSString)
            context.evaluateScript("click(targetURL, true, true)")
            XCTAssertEqual(context.evaluateScript("messages.length")?.toInt32(), 0)
        }
        let context = try activationContext()
        context.evaluateScript("click('itms-apps://apps.apple.com/app/id375380948', false, false)")
        XCTAssertEqual(context.evaluateScript("messages.length")?.toInt32(), 0)
    }
    #endif

    func testWebViewHTTPOriginIncludesSchemeHostAndEffectivePort() throws {
        let current = try XCTUnwrap(URL(string: "https://Example.COM/path"))

        XCTAssertTrue(webViewURLsHaveSameHTTPOrigin(
            targetURL: try XCTUnwrap(URL(string: "https://example.com:443/other")),
            currentURL: current,
            currentBaseURL: nil
        ))
        XCTAssertFalse(webViewURLsHaveSameHTTPOrigin(
            targetURL: try XCTUnwrap(URL(string: "http://example.com/other")),
            currentURL: current,
            currentBaseURL: nil
        ))
        XCTAssertFalse(webViewURLsHaveSameHTTPOrigin(
            targetURL: try XCTUnwrap(URL(string: "https://example.com:444/other")),
            currentURL: current,
            currentBaseURL: nil
        ))
        XCTAssertTrue(webViewURLsHaveSameHTTPOrigin(
            targetURL: try XCTUnwrap(URL(string: "http://example.com:80/other")),
            currentURL: try XCTUnwrap(URL(string: "http://example.com/path")),
            currentBaseURL: nil
        ))
    }

    func testWebViewHTTPOriginFallsBackToCurrentBaseURL() throws {
        let target = try XCTUnwrap(URL(string: "https://creative.example:443/next"))
        let base = try XCTUnwrap(URL(string: "https://CREATIVE.example/root/"))

        XCTAssertTrue(webViewURLsHaveSameHTTPOrigin(
            targetURL: target,
            currentURL: nil,
            currentBaseURL: base
        ))
        XCTAssertFalse(webViewURLsHaveSameHTTPOrigin(
            targetURL: target,
            currentURL: try XCTUnwrap(URL(string: "https://other.example/root/")),
            currentBaseURL: base
        ), "currentURL takes precedence when both sources are present")
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
