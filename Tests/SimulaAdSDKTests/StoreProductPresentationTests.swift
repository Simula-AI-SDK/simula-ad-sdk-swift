#if os(iOS)
import StoreKit
import UIKit
import XCTest
@testable import SimulaAdSDK

final class StoreProductPresentationTests: XCTestCase {
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
