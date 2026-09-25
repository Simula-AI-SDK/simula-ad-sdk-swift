#if os(iOS)
import StoreKit
import UIKit
import XCTest
@testable import SimulaAdSDK

final class StoreProductPresentationTests: XCTestCase {
    private func attribution(
        version: String,
        campaignID: Int? = nil,
        sourceID: Int? = nil
    ) throws -> AdAttribution {
        var skan: [String: Any] = [
            "version": version,
            "ad_network_id": "net123.skadnetwork",
            "source_app_store_id": 987_654_321,
            "nonce": "00000000-0000-0000-0000-000000000001",
            "timestamp": 1_700_000_000_000,
            "attribution_signature": "sig==",
        ]
        if let campaignID { skan["campaign_id"] = campaignID }
        if let sourceID { skan["source_id"] = sourceID }
        let data = try JSONSerialization.data(withJSONObject: ["skan": skan])
        return try JSONDecoder().decode(AdAttribution.self, from: data)
    }

    @MainActor
    @available(iOS 16.1, *)
    func testStoreParametersSelectIdentifierFromSkanVersion() throws {
        let v3 = CreativeCTARouter.skanAdditionalValues(try attribution(
            version: "3.0", campaignID: 42, sourceID: 1_234
        ))
        XCTAssertEqual(
            (v3[SKStoreProductParameterAdNetworkCampaignIdentifier] as? NSNumber)?.intValue,
            42
        )
        XCTAssertNil(v3[SKStoreProductParameterAdNetworkSourceIdentifier])

        let v4 = CreativeCTARouter.skanAdditionalValues(try attribution(
            version: "4.0", campaignID: 42, sourceID: 1_234
        ))
        XCTAssertEqual(
            (v4[SKStoreProductParameterAdNetworkSourceIdentifier] as? NSNumber)?.intValue,
            1_234
        )
        XCTAssertNil(v4[SKStoreProductParameterAdNetworkCampaignIdentifier])
    }

    @MainActor
    func testStoreParametersDropIncompleteSignedSet() throws {
        XCTAssertTrue(CreativeCTARouter.skanAdditionalValues(
            try attribution(version: "3.0", sourceID: 1_234)
        ).isEmpty)
        XCTAssertTrue(CreativeCTARouter.skanAdditionalValues(
            try attribution(version: "4.0", campaignID: 42)
        ).isEmpty)
    }

    @MainActor
    func testCurrentHiddenHandoffCommitsTrackerButCannotPresentUI() throws {
        let coordinator = AutomaticRouteCoordinator()
        let scope = AnyHashable("hidden-current")
        coordinator.activate(scope: scope)
        let handoff = try XCTUnwrap(coordinator.beginUserHandoff(scope: scope))
        let tracker = URL(string: "https://tracker.example/click")!
        var sent: [URL] = []
        var outcomes: [AttributionRouteOutcome] = []
        let execution = AttributionRouteExecution(
            isActive: { false },
            allowsDetachedDeterministicAttribution: true,
            onOutcome: { outcomes.append($0) }
        )

        XCTAssertTrue(routeCommittedUserHandoff(
            coordinator: coordinator,
            handoff: handoff,
            scope: scope,
            execution: execution,
            route: { execution in
                CreativeCTARouter.open(
                    trackingUrl: tracker.absoluteString,
                    destination: .appstore,
                    storeUrl: "https://apps.apple.com/app/id375380948",
                    execution: execution,
                    trackerSender: { sent.append($0) }
                )
            }
        ))

        XCTAssertEqual(sent, [tracker])
        XCTAssertEqual(outcomes.first?.failureClass, "inactive_presentation")
    }

    @MainActor
    func testInactiveCommittedWebViewRouteFiresDeterministicTrackerWithoutPresenting() {
        let tracker = URL(string: "https://tracker.example/click")!
        var sent: [URL] = []
        var outcomes: [AttributionRouteOutcome] = []
        let execution = makeCreativeAttributionRouteExecution(
            id: UUID(),
            source: .primaryCTA,
            isActive: { false },
            onUIHandoffReleased: {},
            onTerminalOutcome: { outcomes.append($0) },
            onFinished: { _ in }
        )

        CreativeCTARouter.routeCreativeTap(
            url: tracker,
            destination: .appstore,
            storeOpen: .skstoreproduct,
            storeUrl: "https://apps.apple.com/app/id375380948",
            execution: execution,
            trackerSender: { sent.append($0) }
        )

        XCTAssertEqual(sent, [tracker])
        XCTAssertEqual(outcomes.first?.failureClass, "inactive_presentation")
    }

    @MainActor
    func testInactiveCommittedStorePromptRouteFiresTrackerExactlyOnce() {
        let tracker = URL(string: "https://tracker.example/click")!
        var sent: [URL] = []
        var outcomes: [AttributionRouteOutcome] = []
        let execution = AttributionRouteExecution(
            isActive: { false },
            allowsDetachedDeterministicAttribution: true,
            onOutcome: { outcomes.append($0) }
        )

        for _ in 0..<2 {
            CreativeCTARouter.open(
                trackingUrl: tracker.absoluteString,
                destination: .appstore,
                storeUrl: "https://apps.apple.com/app/id375380948",
                execution: execution,
                trackerSender: { sent.append($0) }
            )
        }

        XCTAssertEqual(sent, [tracker])
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.failureClass, "inactive_presentation")
    }

    @MainActor
    func testInactiveAutomaticAndCancelledUserRoutesDoNotFireInjectedTracker() {
        let tracker = URL(string: "https://tracker.example/click")!
        var sent: [URL] = []
        let automatic = AttributionRouteExecution(isActive: { false }, onOutcome: { _ in })
        CreativeCTARouter.open(
            trackingUrl: tracker.absoluteString,
            destination: .appstore,
            storeUrl: "https://apps.apple.com/app/id375380948",
            execution: automatic,
            trackerSender: { sent.append($0) }
        )

        let cancelled = AttributionRouteExecution(
            isActive: { true },
            allowsDetachedDeterministicAttribution: true,
            onOutcome: { _ in }
        )
        cancelled.cancel()
        CreativeCTARouter.open(
            trackingUrl: tracker.absoluteString,
            destination: .appstore,
            storeUrl: "https://apps.apple.com/app/id375380948",
            execution: cancelled,
            trackerSender: { sent.append($0) }
        )

        XCTAssertTrue(sent.isEmpty)
    }

    @MainActor
    func testDefaultAutomaticDirectStoreRoutePresentsStoreProductController() async {
        CreativeCTARouter.resetExternalPresentationStateForTesting()
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        window.makeKeyAndVisible()
        CreativeCTARouter.setPresentationRootForTesting { root }
        CreativeCTARouter.setStoreProductControllerProviderForTesting {
            SKStoreProductViewController()
        }
        var presentedController: UIViewController?
        CreativeCTARouter.setViewControllerPresenterForTesting { controller in
            presentedController = controller
            return true
        }
        UIView.setAnimationsEnabled(false)
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            UIView.setAnimationsEnabled(true)
            CreativeCTARouter.resetExternalPresentationStateForTesting()
        }
        XCTAssertFalse(window.isHidden)
        XCTAssertTrue(root.view.window === window)

        let automaticGuard = AutomaticRouteGuard()
        XCTAssertTrue(automaticGuard.claim())
        var outcomes: [AttributionRouteOutcome] = []
        let execution = AttributionRouteExecution(
            isActive: { true },
            onOutcome: { outcomes.append($0) }
        )
        CreativeCTARouter.open(
            trackingUrl: "itms-apps://apps.apple.com/app/id375380948",
            destination: .appstore,
            execution: execution
        )

        await Task.yield()
        XCTAssertTrue(
            presentedController is SKStoreProductViewController,
            "default StoreOpen must present SKStoreProductViewController on a live foreground window"
        )
        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .directStore,
            success: true,
            failureClass: nil,
            storeDwellRoute: .storeProductSheet
        )])
    }

    @MainActor
    func testOwnedProductDismissIgnoresStaleOwnerAndBalancesCleanupOnce() async {
        CreativeCTARouter.resetExternalPresentationStateForTesting()
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        CreativeCTARouter.setPresentationRootForTesting { root }
        CreativeCTARouter.setStoreProductControllerProviderForTesting {
            SKStoreProductViewController()
        }
        var presentedController: UIViewController?
        CreativeCTARouter.setViewControllerPresenterForTesting { controller in
            presentedController = controller
            return true
        }
        UIView.setAnimationsEnabled(false)
        let owner = StoreProductOwnershipToken()
        let stale = StoreProductOwnershipToken()
        var dismissNotifications = 0
        let dismissed = expectation(description: "owned store product dismissed")
        let observer = NotificationCenter.default.addObserver(
            forName: .simulaAdExternalSheetDidDismiss,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertTrue((notification.object as? StoreProductOwnershipToken) === owner)
            dismissNotifications += 1
            dismissed.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            UIView.setAnimationsEnabled(true)
            CreativeCTARouter.resetExternalPresentationStateForTesting()
        }

        XCTAssertTrue(CreativeCTARouter.presentStoreProduct(
            appID: "375380948",
            ownershipToken: owner
        ))
        CreativeCTARouter.dismissStoreProduct(ownershipToken: stale)
        await Task.yield()
        XCTAssertTrue(presentedController is SKStoreProductViewController)
        XCTAssertEqual(dismissNotifications, 0)

        CreativeCTARouter.dismissStoreProduct(ownershipToken: owner)
        CreativeCTARouter.dismissStoreProduct(ownershipToken: owner)
        XCTAssertFalse(CreativeCTARouter.presentStoreProduct(
            appID: "375380948",
            ownershipToken: stale
        ))
        await fulfillment(of: [dismissed], timeout: 2)
        XCTAssertEqual(dismissNotifications, 1)
    }

    @MainActor
    func testMountBehindForeignSheetDoesNotInheritItsBlockedState() async {
        CreativeCTARouter.resetExternalPresentationStateForTesting()
        CreativeCTARouter.setStoreProductControllerProviderForTesting {
            SKStoreProductViewController()
        }
        CreativeCTARouter.setViewControllerPresenterForTesting { _ in true }
        let sheetOwner = StoreProductOwnershipToken()
        let mountingPresentationOwner = StoreProductOwnershipToken()
        defer { CreativeCTARouter.resetExternalPresentationStateForTesting() }

        XCTAssertTrue(CreativeCTARouter.presentStoreProduct(
            appID: "375380948",
            ownershipToken: sheetOwner
        ))
        XCTAssertTrue(CreativeCTARouter.isExternalPresentationActive(
            ownershipToken: sheetOwner
        ))
        XCTAssertFalse(CreativeCTARouter.isExternalPresentationActive(
            ownershipToken: mountingPresentationOwner
        ))

        CreativeCTARouter.dismissStoreProduct(ownershipToken: sheetOwner)
        await Task.yield()
        XCTAssertFalse(CreativeCTARouter.isExternalPresentationActive(
            ownershipToken: mountingPresentationOwner
        ))
    }

    @MainActor
    func testFallbackAutomaticSheetUsesLifecycleScopeAndReturnsOnOwnedDismissal() async {
        CreativeCTARouter.resetExternalPresentationStateForTesting()
        CreativeCTARouter.setStoreProductControllerProviderForTesting {
            SKStoreProductViewController()
        }
        CreativeCTARouter.setViewControllerPresenterForTesting { _ in true }
        var events: [StoreDwellLifecycleEvent] = []
        var now = 1_000.0
        let tracker = StoreExitTracker(
            adId: "ad",
            adFormat: "interstitial",
            now: { now },
            recorder: { events.append($0) }
        )
        let lifecycle = AttributionRouteLifecycle(storeDwellPresentationID: tracker.presentationID)
        lifecycle.activate()
        defer {
            tracker.onAdClosed()
            lifecycle.deactivate()
            CreativeCTARouter.resetExternalPresentationStateForTesting()
        }
        let execution = AttributionRouteExecution(
            isActive: { lifecycle.isActive },
            onOutcome: { outcome in
                guard let route = outcome.storeDwellRoute else { return }
                tracker.recordStoreOpen(
                    ClickSource.autoRedirect.storeDwellTrigger,
                    route: route
                )
            }
        )

        openFallbackAutomaticRoute(
            trackingUrl: "itms-apps://apps.apple.com/app/id375380948",
            destination: .appstore,
            storeOpen: .skstoreproduct,
            storeUrl: nil,
            attribution: nil,
            lifecycle: lifecycle,
            execution: execution
        )
        XCTAssertEqual(events.map(\.stage), ["store_opened"])
        XCTAssertEqual(events.first?.trigger, "auto_redirect")

        now = 1_500
        CreativeCTARouter.dismissStoreProduct(
            ownershipToken: lifecycle.storeProductOwnership
        )
        await Task.yield()
        XCTAssertEqual(events.map(\.stage), ["store_opened", "store_returned"])
        XCTAssertEqual(events.last?.endEvent, .sheetDismissed)
    }

    @MainActor
    func testCommittedSheetAfterPrimaryTeardownRemainsOwnedUntilFallbackReturn() async {
        CreativeCTARouter.resetExternalPresentationStateForTesting()
        CreativeCTARouter.setStoreProductControllerProviderForTesting { SKStoreProductViewController() }
        CreativeCTARouter.setViewControllerPresenterForTesting { _ in true }
        var now = 1_000.0
        var events: [StoreDwellLifecycleEvent] = []
        let tracker = StoreExitTracker(adId: "ad", adFormat: "interstitial",
            now: { now }, recorder: { events.append($0) })
        let primary = AttributionRouteLifecycle(storeDwellPresentationID: tracker.presentationID)
        let fallback = AttributionRouteLifecycle(storeDwellPresentationID: tracker.presentationID)
        primary.activate()
        let execution = makeCreativeAttributionRouteExecution(
            id: UUID(), source: .primaryCTA, isActive: { primary.isActive },
            canCompleteAfterPresentationTeardown: { true }, onUIHandoffReleased: {},
            onTerminalOutcome: { outcome in
                if let route = outcome.storeDwellRoute { tracker.recordStoreOpen("cta", route: route) }
            }, onFinished: { _ in })
        startAsynchronousAttributionRoute(execution: execution, start: {})
        primary.deactivate()
        fallback.activate()
        defer {
            tracker.onAdClosed()
            CreativeCTARouter.resetExternalPresentationStateForTesting()
        }
        now = 1_100
        execution.complete(storeDwellRoute: .storeProductSheet) {
            CreativeCTARouter.presentStoreProduct(appID: "375380948", ownershipToken: primary.storeProductOwnership)
        }
        XCTAssertEqual(events.map(\.stage), ["store_opened"])
        // Fallback timing must remain blocked even though sheet routing ownership is distinct.
        XCTAssertTrue(CreativeCTARouter.isExternalPresentationActive(ownershipToken: fallback.storeProductOwnership))
        XCTAssertFalse(CreativeCTARouter.isExternalPresentationActive(ownershipToken: StoreProductOwnershipToken()))
        CreativeCTARouter.dismissStoreProduct(ownershipToken: fallback.storeProductOwnership)
        await Task.yield()
        XCTAssertEqual(events.count, 1, "A sibling surface cannot dismiss a sheet it did not open")
        now = 2_100
        CreativeCTARouter.dismissStoreProduct(ownershipToken: primary.storeProductOwnership)
        await Task.yield()
        XCTAssertEqual(events.last?.endEvent, .sheetDismissed)
        XCTAssertEqual(events.last?.durationMs, 1_000)
        XCTAssertFalse(CreativeCTARouter.isExternalPresentationActive(ownershipToken: fallback.storeProductOwnership))

        now = 2_200
        let second = AttributionRouteExecution(isActive: { fallback.isActive }) { outcome in
            if let route = outcome.storeDwellRoute { tracker.recordStoreOpen("fallback_cta", route: route) }
        }
        openFallbackAutomaticRoute(trackingUrl: "itms-apps://apps.apple.com/app/id375380948",
            destination: .appstore, storeOpen: .skstoreproduct, storeUrl: nil, attribution: nil,
            lifecycle: fallback, execution: second)
        CreativeCTARouter.dismissStoreProduct(ownershipToken: fallback.storeProductOwnership)
        await Task.yield()
        XCTAssertEqual(events.map(\.stage), ["store_opened", "store_returned", "store_opened", "store_returned"])
        XCTAssertEqual(events.map(\.opens), [1, 1, 2, 2])
    }

    @MainActor
    func testPresentationObservationSurvivesSurfaceGapsAndIgnoresForeignSheets() {
        let center = NotificationCenter()
        var events: [StoreDwellLifecycleEvent] = []
        var now = 1_000.0
        let tracker = StoreExitTracker(adId: "ad", adFormat: "rewarded", now: { now },
            recorder: { events.append($0) }, notificationCenter: center)
        let owner = StoreProductOwnershipToken(storeDwellPresentationID: tracker.presentationID)
        let foreign = StoreProductOwnershipToken()
        center.post(name: .simulaAdExternalSheetWillPresent, object: owner)
        tracker.recordStoreOpen("cta", route: .storeProductSheet)
        center.post(name: .simulaAdExternalSheetDidDismiss, object: foreign)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        now = 2_000
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(events.count, 1)
        center.post(name: .simulaAdExternalSheetDidDismiss, object: owner)
        XCTAssertEqual(events.last?.durationMs, 1_000)
        tracker.recordStoreOpen("fallback_cta", route: .externalAppStore)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        now = 3_000
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(events.last?.endEvent, .appForeground)
        tracker.onAdClosed()
        center.post(name: .simulaAdExternalSheetWillPresent, object: owner)
        tracker.recordStoreOpen("cta", route: .storeProductSheet)
        center.post(name: .simulaAdExternalSheetDidDismiss, object: owner)
        XCTAssertEqual(events.count, 4)
    }

    @MainActor
    func testBackgroundLifecyclePostingDoesNotWaitForMainThread() async {
        let center = NotificationCenter()
        let posted = expectation(description: "Background poster completes")
        let opened = expectation(description: "Main actor confirms the visit")
        var events: [StoreDwellLifecycleEvent] = []
        let tracker = StoreExitTracker(adId: "ad", adFormat: "interstitial", recorder: {
            events.append($0)
            if $0.stage == "store_opened" { opened.fulfill() }
        }, notificationCenter: center)
        defer { tracker.onAdClosed() }
        tracker.recordStoreOpen("cta", route: .externalAppStore)
        DispatchQueue.global(qos: .utility).async {
            center.post(name: UIApplication.willResignActiveNotification, object: nil)
            posted.fulfill()
        }
        await fulfillment(of: [posted, opened], timeout: 2)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(events.map(\.stage), ["store_opened", "store_returned"])
    }

    @MainActor
    func testLifecycleObserversDoNotRetainTrackerWithoutExplicitClose() {
        let center = NotificationCenter()
        var tracker: StoreExitTracker? = StoreExitTracker(adId: "ad", adFormat: "interstitial", notificationCenter: center)
        weak var weakTracker = tracker
        tracker = nil
        XCTAssertNil(weakTracker)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @MainActor
    func testInteractiveProductDismissRunsOwnedCleanup() async throws {
        CreativeCTARouter.resetExternalPresentationStateForTesting()
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        CreativeCTARouter.setPresentationRootForTesting { root }
        CreativeCTARouter.setStoreProductControllerProviderForTesting {
            SKStoreProductViewController()
        }
        UIView.setAnimationsEnabled(false)
        let dismissed = expectation(description: "interactive store product dismissed")
        let observer = NotificationCenter.default.addObserver(
            forName: .simulaAdExternalSheetDidDismiss,
            object: nil,
            queue: .main
        ) { _ in dismissed.fulfill() }
        defer {
            NotificationCenter.default.removeObserver(observer)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            UIView.setAnimationsEnabled(true)
            CreativeCTARouter.resetExternalPresentationStateForTesting()
        }

        XCTAssertTrue(CreativeCTARouter.presentStoreProduct(
            appID: "375380948",
            ownershipToken: StoreProductOwnershipToken()
        ))
        let storeVC = try XCTUnwrap(root.presentedViewController as? SKStoreProductViewController)
        let presentationController = try XCTUnwrap(storeVC.presentationController)
        let presentationDelegate = try XCTUnwrap(presentationController.delegate)

        storeVC.dismiss(animated: false)
        presentationDelegate.presentationControllerDidDismiss?(presentationController)

        await fulfillment(of: [dismissed], timeout: 2)
    }
}
#endif
