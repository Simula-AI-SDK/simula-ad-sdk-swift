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
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
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
            root.presentedViewController is SKStoreProductViewController,
            "default StoreOpen must present SKStoreProductViewController on a live foreground window"
        )
        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .directStore,
            success: true,
            failureClass: nil
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
        let owner = StoreProductOwnershipToken()
        let stale = StoreProductOwnershipToken()
        var dismissNotifications = 0
        let dismissed = expectation(description: "owned store product dismissed")
        let observer = NotificationCenter.default.addObserver(
            forName: .simulaAdExternalSheetDidDismiss,
            object: nil,
            queue: .main
        ) { _ in
            dismissNotifications += 1
            dismissed.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            CreativeCTARouter.resetExternalPresentationStateForTesting()
        }

        XCTAssertTrue(CreativeCTARouter.presentStoreProduct(
            appID: "375380948",
            ownershipToken: owner
        ))
        CreativeCTARouter.dismissStoreProduct(ownershipToken: stale)
        await Task.yield()
        XCTAssertTrue(root.presentedViewController is SKStoreProductViewController)
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
