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

    func testFallbackNativeBeaconOwnershipRequiresClientSupportServerEnablementAndAdId() {
        let capable = DeviceCapabilities(
            osVersion: "test", storekitAvailable: true, skanVersion: "4.0",
            adAttributionKitAvailable: true, nativeClickBeaconV1: true
        )
        let legacy = DeviceCapabilities(
            osVersion: "test", storekitAvailable: true, skanVersion: "4.0",
            adAttributionKitAvailable: true, nativeClickBeaconV1: false
        )

        XCTAssertEqual(
            fallbackNativeClickBeaconImpressionId(
                adId: "fallback-ad",
                capabilities: capable,
                nativeClickBeaconV1Enabled: true
            ),
            "fallback-ad"
        )
        XCTAssertNil(fallbackNativeClickBeaconImpressionId(
            adId: "fallback-ad", capabilities: capable, nativeClickBeaconV1Enabled: false
        ))
        XCTAssertNil(fallbackNativeClickBeaconImpressionId(
            adId: "fallback-ad", capabilities: legacy, nativeClickBeaconV1Enabled: true
        ))
        XCTAssertNil(fallbackNativeClickBeaconImpressionId(
            adId: "", capabilities: capable, nativeClickBeaconV1Enabled: true
        ))

        let interaction = ClickInteraction(id: "interaction", source: .fallbackCTA)
        XCTAssertEqual(
            fallbackNativeClickBeaconClaim(
                adId: "fallback-ad", interaction: interaction, capabilities: capable,
                nativeClickBeaconV1Enabled: true
            ),
            FallbackNativeClickBeaconClaim(
                impressionId: "fallback-ad",
                interactionId: "interaction",
                clickSource: "fallback_cta"
            )
        )
        XCTAssertNil(fallbackNativeClickBeaconClaim(
            adId: "fallback-ad", interaction: interaction, capabilities: capable,
            nativeClickBeaconV1Enabled: false
        ))
        XCTAssertNil(fallbackNativeClickBeaconClaim(
            adId: "fallback-ad", interaction: interaction, capabilities: legacy,
            nativeClickBeaconV1Enabled: true
        ))
    }

    func testFallbackClickAccountingUsesFallbackIdentityExactlyOnce() {
        let capable = DeviceCapabilities(
            osVersion: "test", storekitAvailable: true, skanVersion: "4.0",
            adAttributionKitAvailable: true, nativeClickBeaconV1: true
        )
        let interaction = ClickInteraction(id: "interaction", source: .fallbackCTA)
        var telemetry: [(FallbackClickTelemetryContext, ClickInteraction)] = []
        var beacons: [(FallbackNativeClickBeaconClaim, FallbackClickTelemetryContext)] = []
        var publisher: [ClickInteraction] = []

        accountFallbackClick(
            adId: "fallback-ad",
            interaction: interaction,
            capabilities: capable,
            nativeClickBeaconV1Enabled: true,
            adFormat: "rewarded",
            adUnitId: "unit",
            serveId: "parent-serve",
            recordTelemetry: { telemetry.append(($0, $1)) },
            enqueueBeacon: { beacons.append(($0, $1)) },
            notifyPublisher: { publisher.append($0) }
        )

        XCTAssertEqual(telemetry.count, 1)
        XCTAssertEqual(
            telemetry.first?.0,
            FallbackClickTelemetryContext(
                adFormat: "rewarded", adUnitId: "unit", adId: "fallback-ad",
                serveId: "parent-serve"
            )
        )
        XCTAssertEqual(telemetry.first?.1, interaction)
        XCTAssertEqual(beacons.count, 1)
        XCTAssertEqual(beacons.first?.0.impressionId, "fallback-ad")
        XCTAssertEqual(beacons.first?.0.interactionId, interaction.id)
        XCTAssertEqual(beacons.first?.0.clickSource, interaction.source.rawValue)
        XCTAssertEqual(beacons.first?.1, telemetry.first?.0)
        XCTAssertEqual(publisher, [interaction])
    }

    func testFallbackClickAccountingKeepsTelemetryAndPublisherWhenServerOwnsNoBeacon() {
        let capable = DeviceCapabilities(
            osVersion: "test", storekitAvailable: true, skanVersion: "4.0",
            adAttributionKitAvailable: true, nativeClickBeaconV1: true
        )
        let interaction = ClickInteraction(id: "interaction", source: .fallbackCTA)
        var telemetryCount = 0
        var beaconCount = 0
        var publisherCount = 0

        accountFallbackClick(
            adId: "fallback-ad",
            interaction: interaction,
            capabilities: capable,
            nativeClickBeaconV1Enabled: false,
            adFormat: "interstitial",
            adUnitId: nil,
            serveId: nil,
            recordTelemetry: { _, _ in telemetryCount += 1 },
            enqueueBeacon: { _, _ in beaconCount += 1 },
            notifyPublisher: { _ in publisherCount += 1 }
        )

        XCTAssertEqual(telemetryCount, 1)
        XCTAssertEqual(beaconCount, 0)
        XCTAssertEqual(publisherCount, 1)
    }

    func testTopLevelTrackerWinsOverHTMLEscapedURL() {
        let fallback = URL(string: "https://tracker.example/click?a=1&amp;b=2")!

        let selected = preferredCreativeClickURL(
            trackingUrl: "https://tracker.example/click?a=1&b=2",
            fallback: fallback
        )

        XCTAssertEqual(selected?.absoluteString, "https://tracker.example/click?a=1&b=2")
    }

    func testMissingOrBlankTrackerFallsBackToEmbeddedURL() {
        let fallback = URL(string: "https://example.com/landing")!

        XCTAssertEqual(preferredCreativeClickURL(trackingUrl: nil, fallback: fallback), fallback)
        XCTAssertEqual(preferredCreativeClickURL(trackingUrl: "", fallback: fallback), fallback)
        XCTAssertEqual(preferredCreativeClickURL(trackingUrl: "   ", fallback: fallback), fallback)
    }

    func testUnsafeOrNonAbsoluteTopLevelTrackersFallBackToAdmittedTap() {
        let fallback = URL(string: "https://safe.example/click?from=creative")!
        let invalid = [
            "/relative/path",
            "javascript:alert(1)",
            "data:text/plain,click",
            "https:///missing-host",
            "https://:443/malformed-host",
            "not a url",
        ]

        for tracker in invalid {
            XCTAssertEqual(
                preferredCreativeClickURL(trackingUrl: tracker, fallback: fallback),
                fallback,
                "unexpectedly admitted \(tracker)"
            )
        }
    }

    func testValidTopLevelTrackerPreservesEncodedQueryByteForByte() {
        let fallback = URL(string: "https://safe.example/fallback")!
        let value = "https://tracker.example/click?redirect=https%3A%2F%2Fapps.apple.com%2Fapp%2Fid123&a=1%26b%3D2"

        XCTAssertEqual(
            preferredCreativeClickURL(trackingUrl: "  \(value)  ", fallback: fallback)?.absoluteString,
            value
        )
        XCTAssertEqual(validatedMMPTrackingURL(value)?.absoluteString, value)
        XCTAssertNotEqual(preferredCreativeClickURL(trackingUrl: value, fallback: fallback), fallback)
    }

    func testDirectStoreSchemesRequireExtractableAppId() {
        let fallback = URL(string: "https://safe.example/fallback")!
        let valid = [
            "itms-apps://apps.apple.com/app/id123456789",
            "itms-appss://apps.apple.com/app/id246813579",
            "itms://itunes.apple.com/app/id987654321",
        ]
        for value in valid {
            XCTAssertEqual(validatedDirectAppStoreURL(value)?.absoluteString, value)
            XCTAssertEqual(
                preferredCreativeClickURL(trackingUrl: value, fallback: fallback)?.absoluteString,
                value
            )
        }

        XCTAssertNil(validatedDirectAppStoreURL("itms-apps://apps.apple.com/app/no-id"))
        XCTAssertNil(validatedDirectAppStoreURL("itms-appss://apps.apple.com/app/no-id"))
        XCTAssertNil(validatedDirectAppStoreURL("itms://example.com/not-a-store-route"))
        XCTAssertNil(validatedDirectAppStoreURL("https://apps.apple.com.evil.example/app/id123"))
        XCTAssertNil(validatedDirectAppStoreURL("https://evilapps.apple.com/app/id123"))
        XCTAssertEqual(
            preferredCreativeClickURL(
                trackingUrl: "itms-apps://apps.apple.com/app/no-id",
                fallback: fallback
            ),
            fallback
        )
    }

    func testDirectStoreNormalizationTrimsWhitespaceAcrossHelpersAndExternalPlans() {
        let raw = "  itms-apps://apps.apple.com/app/id123456789  "
        XCTAssertEqual(
            validatedDirectAppStoreURL(raw)?.absoluteString,
            "itms-apps://apps.apple.com/app/id123456789"
        )
        #if os(iOS)
        XCTAssertEqual(CreativeCTARouter.appStoreID(fromString: raw), "123456789")
        #endif

        let tracker = URL(string: "https://tracker.example/click")!
        XCTAssertEqual(
            creativeRoutePlan(
                selectedURL: tracker,
                destination: .appstore,
                storeOpen: .external,
                campaignStoreURL: "  https://apps.apple.com/app/id987654321  ",
                fallbackStoreURL: nil,
                externalClickOnly: false
            ),
            .trackerWithStore(
                tracker: tracker,
                storeURL: URL(string: "https://apps.apple.com/app/id987654321")!,
                appID: "987654321",
                storeOpen: .external
            )
        )
    }

    func testDirectStoreNormalizationRejectsMalformedHostsPathsAndSchemes() {
        for value in [
            "https://apps.apple.com.evil.example/app/id123",
            "itms-apps://evil.example/app/id123",
            "itms-appss://evil.example/app/id123",
            "itms-apps://apps.apple.com/app/no-id",
            "javascript://apps.apple.com/app/id123",
            "ftp://apps.apple.com/app/id123",
        ] {
            XCTAssertNil(validatedDirectAppStoreURL(value), "unexpected store URL: \(value)")
            #if os(iOS)
            XCTAssertNil(CreativeCTARouter.appStoreID(fromString: value))
            #endif
        }
    }

    func testSceneSelectionPrefersOriginThenActiveKeyThenAnyActive() {
        final class Scene {
            let name: String
            let active: Bool
            let key: Bool
            init(_ name: String, active: Bool, key: Bool) {
                self.name = name
                self.active = active
                self.key = key
            }
        }
        let inactiveOrigin = Scene("inactive", active: false, key: true)
        let activeNoKey = Scene("active-no-key", active: true, key: false)
        let activeKey = Scene("active-key", active: true, key: true)
        let activeOrigin = Scene("origin", active: true, key: false)

        XCTAssertTrue(preferredActiveScene(
            originating: activeOrigin,
            scenes: [activeKey, activeNoKey],
            isActive: { $0.active },
            hasKeyWindow: { $0.key }
        ) === activeOrigin)
        XCTAssertTrue(preferredActiveScene(
            originating: inactiveOrigin,
            scenes: [activeNoKey, activeKey],
            isActive: { $0.active },
            hasKeyWindow: { $0.key }
        ) === activeKey)
        XCTAssertTrue(preferredActiveScene(
            originating: nil,
            scenes: [inactiveOrigin, activeNoKey],
            isActive: { $0.active },
            hasKeyWindow: { $0.key }
        ) === activeNoKey)
        XCTAssertNil(preferredActiveScene(
            originating: inactiveOrigin,
            scenes: [inactiveOrigin],
            isActive: { $0.active },
            hasKeyWindow: { $0.key }
        ))
    }

    func testSelectedCreativeFallbackRequiresSafeDestinationURL() {
        let safe = URL(string: "https://advertiser.example/landing")!
        XCTAssertEqual(
            preferredCreativeClickURL(trackingUrl: nil, fallback: safe),
            safe
        )

        let invalid = [
            URL(string: "https:///missing-host")!,
            URL(string: "itms-apps://apps.apple.com/app/no-id")!,
            URL(string: "javascript:alert(1)")!,
            URL(string: "data:text/plain,click")!,
        ]
        for fallback in invalid {
            XCTAssertNil(
                preferredCreativeClickURL(trackingUrl: nil, fallback: fallback),
                "unexpectedly admitted \(fallback)"
            )
        }

        let custom = URL(string: "advertiser-app://offer/42")!
        XCTAssertNil(preferredCreativeClickURL(
            trackingUrl: nil,
            fallback: custom,
            destination: .appstore,
            externalClickOnly: false
        ))
        XCTAssertEqual(
            preferredCreativeClickURL(
                trackingUrl: nil,
                fallback: custom,
                destination: .web,
                externalClickOnly: false
            ),
            custom
        )
        XCTAssertEqual(
            preferredCreativeClickURL(
                trackingUrl: nil,
                fallback: custom,
                destination: .appstore,
                externalClickOnly: true
            ),
            custom
        )
    }

    func testResolverTerminalURLRequiresHTTPHostOrValidDirectStoreID() {
        let valid = [
            "https://advertiser.example/landing",
            "http://tracker.example/click",
            "itms-apps://apps.apple.com/app/id123456789",
            "itms-appss://apps.apple.com/app/id246813579",
            "itms://itunes.apple.com/app/id987654321",
        ]
        for value in valid {
            XCTAssertEqual(
                validatedResolverRedirectURL(URL(string: value))?.absoluteString,
                value
            )
        }

        let invalid = [
            "/relative/path",
            "https:///missing-host",
            "https://:443/malformed-host",
            "itms-apps://apps.apple.com/app/no-id",
            "itms-appss://apps.apple.com/app/no-id",
            "advertiser-app://offer/42",
            "about:blank",
            "blob:https://advertiser.example/id",
            "file:///tmp/landing.html",
            "javascript:alert(1)",
            "data:text/plain,click",
        ]
        for value in invalid {
            XCTAssertNil(
                validatedResolverRedirectURL(URL(string: value)),
                "unexpectedly admitted terminal redirect \(value)"
            )
        }
    }

    func testRedirectResolverStopsAtEveryCanonicalStoreScheme() {
        for value in [
            "itms://itunes.apple.com/app/id123",
            "itms-apps://apps.apple.com/app/id123",
            "itms-appss://apps.apple.com/app/id123",
            "https://apps.apple.com/app/id123",
        ] {
            XCTAssertTrue(shouldStopRedirectResolution(at: URL(string: value)!))
        }
        XCTAssertFalse(shouldStopRedirectResolution(
            at: URL(string: "https://tracker.example/click")!
        ))
        XCTAssertFalse(shouldStopRedirectResolution(
            at: URL(string: "advertiser-app://offer/42")!
        ))
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
            "itms-appss://apps.apple.com/app/id456",
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
                for: ctaBody(url: "https:///missing-host"),
                expectedNonce: activationNonce,
                destination: .web,
                externalClickOnly: true
            ),
            .rejected
        )
        XCTAssertEqual(
            CreativeCTAOpenMessage.admission(
                for: ctaBody(url: "itms-apps://apps.apple.com/app/no-id"),
                expectedNonce: activationNonce,
                destination: .appstore,
                externalClickOnly: false
            ),
            .rejected
        )
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

    @MainActor
    func testNeverCompletingResolverCannotHoldFullscreenDismissal() {
        var clickHandoffPending = true
        var outcomes: [AttributionRouteOutcome] = []
        var started = false
        let execution = AttributionRouteExecution(
            isActive: { true },
            onUIHandoffReleased: { clickHandoffPending = false },
            onOutcome: { outcomes.append($0) }
        )

        startAsynchronousAttributionRoute(execution: execution) {
            started = true
            // Intentionally never completes, matching a stalled redirect resolver.
        }

        XCTAssertTrue(started)
        XCTAssertFalse(clickHandoffPending)
        XCTAssertTrue(canDismissFullscreen(
            dismissUnlocked: true,
            clickHandoffPending: clickHandoffPending
        ))
        XCTAssertTrue(outcomes.isEmpty, "UI handoff release must not manufacture terminal telemetry")
    }

    @MainActor
    func testAcceptedSlowRouteSurvivesWebViewDetachAndRebindUntilTerminalOutcome() {
        let lifecycle = AttributionRouteLifecycle()
        lifecycle.activate()
        var outcomes: [AttributionRouteOutcome] = []
        var routes = 0
        let execution = AttributionRouteExecution(
            isActive: { lifecycle.isActive },
            onOutcome: { outcomes.append($0) }
        )

        XCTAssertTrue(execution.begin(path: .mmpRedirect))
        // Simulated WebView teardown/rebind: the presentation lifecycle remains active.
        execution.complete { routes += 1; return true }
        execution.complete { routes += 1; return true }

        XCTAssertEqual(routes, 1)
        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .mmpRedirect,
            success: true,
            failureClass: nil
        )])
    }

    @MainActor
    func testCommittedSlowResolverCompletionSurvivesPresentationTeardown() {
        let lifecycle = AttributionRouteLifecycle()
        lifecycle.activate()
        var outcomes: [AttributionRouteOutcome] = []
        var routes = 0
        var clickHandoffPending = true
        let execution = AttributionRouteExecution(
            isActive: { lifecycle.isActive },
            survivesPresentationTeardownAfterBegin: true,
            onUIHandoffReleased: { clickHandoffPending = false },
            onOutcome: { outcomes.append($0) }
        )
        startAsynchronousAttributionRoute(execution: execution) {}
        XCTAssertFalse(clickHandoffPending)
        lifecycle.deactivate()

        execution.complete { routes += 1; return true }

        XCTAssertEqual(routes, 1)
        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .mmpRedirect,
            success: true,
            failureClass: nil
        )])
    }

    @MainActor
    func testTerminalOutcomeSurvivesCoordinatorDeallocationAfterTeardown() {
        let lifecycle = AttributionRouteLifecycle()
        lifecycle.activate()
        var outcomes: [AttributionRouteOutcome] = []
        var routes = 0
        var coordinator: CreativeRouteOwner? = CreativeRouteOwner(destination: "cleanup-owner")
        weak var weakCoordinator = coordinator
        let execution = makeCreativeAttributionRouteExecution(
            id: UUID(),
            source: .primaryCTA,
            isActive: { lifecycle.isActive },
            canCompleteAfterPresentationTeardown: { true },
            onUIHandoffReleased: {},
            onTerminalOutcome: { outcomes.append($0) },
            onFinished: { [weak coordinator] _ in
                _ = coordinator?.destination
            }
        )

        startAsynchronousAttributionRoute(execution: execution) {}
        coordinator = nil
        lifecycle.deactivate()
        execution.complete { routes += 1; return true }

        XCTAssertNil(weakCoordinator)
        XCTAssertEqual(routes, 1, "a committed user route must survive its WebView owner")
        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .mmpRedirect,
            success: true,
            failureClass: nil
        )])
    }

    @MainActor
    func testPresentationBoundAutomaticRouteStillStopsAfterTeardown() {
        let lifecycle = AttributionRouteLifecycle()
        lifecycle.activate()
        var outcomes: [AttributionRouteOutcome] = []
        var routes = 0
        let execution = AttributionRouteExecution(
            isActive: { lifecycle.isActive },
            onOutcome: { outcomes.append($0) }
        )
        startAsynchronousAttributionRoute(execution: execution) {}
        lifecycle.deactivate()

        execution.complete { routes += 1; return true }

        XCTAssertEqual(routes, 0)
        XCTAssertEqual(outcomes.first?.failureClass, "inactive_presentation")
    }

    @MainActor
    func testCommittedUserDeterministicTrackerSurvivesInactivePresentationExactlyOnce() {
        var outcomes: [AttributionRouteOutcome] = []
        var sent: [URL] = []
        let tracker = URL(string: "https://tracker.example/click")!
        let execution = makeCreativeAttributionRouteExecution(
            id: UUID(),
            source: .primaryCTA,
            isActive: { false },
            onUIHandoffReleased: {},
            onTerminalOutcome: { outcomes.append($0) },
            onFinished: { _ in }
        )

        execution.deliverDeterministicTracker(tracker) { sent.append($0) }
        execution.deliverDeterministicTracker(tracker) { sent.append($0) }
        XCTAssertFalse(execution.begin(path: .rawStoreFallback))

        XCTAssertEqual(sent, [tracker])
        XCTAssertEqual(outcomes.first?.failureClass, "inactive_presentation")
    }

    @MainActor
    func testAutomaticAndPreCommitCancelledRoutesDoNotDetachTrackerDelivery() {
        let tracker = URL(string: "https://tracker.example/click")!
        var automaticSends = 0
        let automatic = AttributionRouteExecution(
            isActive: { false },
            onOutcome: { _ in }
        )
        automatic.deliverDeterministicTracker(tracker) { _ in automaticSends += 1 }
        XCTAssertFalse(automatic.begin(path: .rawStoreFallback))
        XCTAssertEqual(automaticSends, 0)

        var cancelledSends = 0
        let cancelled = AttributionRouteExecution(
            isActive: { true },
            allowsDetachedDeterministicAttribution: true,
            onOutcome: { _ in }
        )
        cancelled.cancel()
        cancelled.deliverDeterministicTracker(tracker) { _ in cancelledSends += 1 }
        XCTAssertEqual(cancelledSends, 0)
    }

    @MainActor
    func testStaleWebViewOrStorePromptHandoffNeverReachesCommittedRouteSender() throws {
        let coordinator = AutomaticRouteCoordinator()
        let scope = AnyHashable("stale-surface")
        coordinator.activate(scope: scope)
        let handoff = try XCTUnwrap(coordinator.beginUserHandoff(scope: scope))
        coordinator.deactivate(scope: scope)
        var sends = 0
        var outcomes: [AttributionRouteOutcome] = []
        let execution = AttributionRouteExecution(
            isActive: { false },
            allowsDetachedDeterministicAttribution: true,
            onOutcome: { outcomes.append($0) }
        )

        XCTAssertFalse(routeCommittedUserHandoff(
            coordinator: coordinator,
            handoff: handoff,
            scope: scope,
            execution: execution,
            route: { execution in
                execution.deliverDeterministicTracker(
                    URL(string: "https://tracker.example/click")!
                ) { _ in sends += 1 }
            }
        ))

        XCTAssertEqual(sends, 0)
        XCTAssertEqual(outcomes.first?.failureClass, "cancelled")
    }

    @MainActor
    func testCommittedRouteDoesNotCompleteWhenCapturedSceneBecomesUnavailable() {
        var outcomes: [AttributionRouteOutcome] = []
        var routes = 0
        var presentationActive = true
        let execution = AttributionRouteExecution(
            isActive: { presentationActive },
            survivesPresentationTeardownAfterBegin: true,
            canCompleteAfterPresentationTeardown: { false },
            onOutcome: { outcomes.append($0) }
        )
        startAsynchronousAttributionRoute(execution: execution) {}
        presentationActive = false

        execution.complete { routes += 1; return true }

        XCTAssertEqual(routes, 0)
        XCTAssertEqual(outcomes.first?.failureClass, "inactive_presentation")
    }

    @MainActor
    func testExplicitCancellationSuppressesCommittedRouteCompletion() {
        var outcomes: [AttributionRouteOutcome] = []
        var routes = 0
        let execution = AttributionRouteExecution(
            isActive: { true },
            survivesPresentationTeardownAfterBegin: true,
            onOutcome: { outcomes.append($0) }
        )
        startAsynchronousAttributionRoute(execution: execution) {}

        execution.cancel()
        execution.complete { routes += 1; return true }

        XCTAssertEqual(routes, 0)
        XCTAssertEqual(outcomes.first?.failureClass, "cancelled")
    }

    @MainActor
    func testResolverFailureCompletesCommittedRouteExactlyOnceWithoutLaunching() {
        var outcomes: [AttributionRouteOutcome] = []
        var routes = 0
        let execution = AttributionRouteExecution(
            isActive: { true },
            survivesPresentationTeardownAfterBegin: true,
            onOutcome: { outcomes.append($0) }
        )
        startAsynchronousAttributionRoute(execution: execution) {}

        execution.fail("resolve_failed")
        execution.complete { routes += 1; return true }
        execution.fail("resolve_failed")

        XCTAssertEqual(routes, 0)
        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .mmpRedirect,
            success: false,
            failureClass: "resolve_failed"
        )])
    }

    func testWeakSceneReferenceRetainsIdentityWithoutOwningSceneLifetime() {
        final class Scene {}
        var scene: Scene? = Scene()
        let reference = WeakObjectReference(scene)

        XCTAssertTrue(reference.value === scene)
        scene = nil
        XCTAssertNil(reference.value)
    }

    @MainActor
    func testLostCapturedSceneCannotFallThroughToAnotherPresentationContext() {
        final class Scene {}
        var scene: Scene? = Scene()
        var outcomes: [AttributionRouteOutcome] = []
        let execution = AttributionRouteExecution(
            originatingScene: scene,
            isActive: { true },
            onOutcome: { outcomes.append($0) }
        )
        scene = nil

        XCTAssertFalse(execution.begin(path: .directStore))
        XCTAssertEqual(outcomes.first?.failureClass, "inactive_presentation")
    }

    @MainActor
    func testInvalidTerminalRedirectEmitsLowCardinalityFailure() {
        var outcomes: [AttributionRouteOutcome] = []
        let execution = AttributionRouteExecution(
            isActive: { true },
            onOutcome: { outcomes.append($0) }
        )
        startAsynchronousAttributionRoute(execution: execution) {}

        XCTAssertNil(terminalResolverRedirectURL(
            URL(string: "advertiser-app://offer/42"),
            execution: execution
        ))
        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .mmpRedirect,
            success: false,
            failureClass: "invalid_redirect_url"
        )])
    }

    @MainActor
    func testPrimaryStoreOpenIsRecordedOnlyForSuccessfulTerminalOutcome() {
        var storeOpens = 0
        let recordSuccessfulOpen: (AttributionRouteOutcome) -> Void = { outcome in
            if outcome.success { storeOpens += 1 }
        }

        let invalid = AttributionRouteExecution(
            isActive: { true },
            onOutcome: recordSuccessfulOpen
        )
        XCTAssertTrue(invalid.begin(path: .mmpRedirect))
        invalid.fail("invalid_url")

        let unavailable = AttributionRouteExecution(
            isActive: { true },
            onOutcome: recordSuccessfulOpen
        )
        XCTAssertTrue(unavailable.begin(path: .directStore))
        unavailable.complete { false }

        let inactive = AttributionRouteExecution(
            isActive: { false },
            onOutcome: recordSuccessfulOpen
        )
        XCTAssertFalse(inactive.begin(path: .directStore))
        XCTAssertEqual(storeOpens, 0)

        let successful = AttributionRouteExecution(
            isActive: { true },
            onOutcome: recordSuccessfulOpen
        )
        XCTAssertTrue(successful.begin(path: .directStore))
        successful.complete { true }
        XCTAssertEqual(storeOpens, 1)
    }

    @MainActor
    func testLifecycleLessRouteCanBeCancelledForNativeAdRebind() {
        var outcomes: [AttributionRouteOutcome] = []
        let execution = AttributionRouteExecution(
            isActive: { true },
            onOutcome: { outcomes.append($0) }
        )
        XCTAssertTrue(execution.begin(path: .mmpRedirect))
        execution.cancel()
        execution.complete { true }

        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .mmpRedirect,
            success: false,
            failureClass: "cancelled"
        )])
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
