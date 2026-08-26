#if os(iOS)
import StoreKit
import UIKit
import XCTest
@testable import SimulaAdSDK

final class StoreProductPresentationTests: XCTestCase {
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
}
#endif
