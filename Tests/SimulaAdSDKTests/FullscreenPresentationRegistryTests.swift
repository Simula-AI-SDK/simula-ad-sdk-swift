import XCTest
@testable import SimulaAdSDK

final class FullscreenPresentationRegistryTests: XCTestCase {
    func testPrewarmRequiresEveryPresentationTokenToBeReleased() {
        var ownership = FullscreenPresentationOwnership<String>()

        XCTAssertTrue(ownership.isPrewarmEligible)
        XCTAssertTrue(ownership.claim("interstitial"))
        XCTAssertTrue(ownership.claim("rewarded"))
        XCTAssertFalse(ownership.isPrewarmEligible)

        XCTAssertTrue(ownership.release("interstitial"))
        XCTAssertFalse(ownership.isPrewarmEligible)

        XCTAssertFalse(ownership.release("interstitial"))
        XCTAssertFalse(ownership.isPrewarmEligible)

        XCTAssertTrue(ownership.release("rewarded"))
        XCTAssertTrue(ownership.isPrewarmEligible)
    }

    func testUnknownOrStaleReleaseCannotClearAnotherPresentation() {
        var ownership = FullscreenPresentationOwnership<Int>()
        ownership.claim(1)
        ownership.claim(2)

        XCTAssertFalse(ownership.release(3))
        XCTAssertFalse(ownership.isPrewarmEligible)
        XCTAssertTrue(ownership.release(1))
        XCTAssertFalse(ownership.release(1))
        XCTAssertFalse(ownership.isPrewarmEligible)
        XCTAssertTrue(ownership.release(2))
        XCTAssertTrue(ownership.isPrewarmEligible)
    }

    func testLeaseWaitsForPrimaryAndPostCloseTeardownInEitherOrder() {
        var primaryFirst = FullscreenPresentationLeaseCompletion()
        XCTAssertFalse(primaryFirst.finishPrimaryTeardown())
        XCTAssertTrue(primaryFirst.finishPostCloseTeardown())
        XCTAssertFalse(primaryFirst.finishPostCloseTeardown())

        var fallbackFirst = FullscreenPresentationLeaseCompletion()
        XCTAssertFalse(fallbackFirst.finishPostCloseTeardown())
        XCTAssertTrue(fallbackFirst.finishPrimaryTeardown())
        XCTAssertFalse(fallbackFirst.finishPrimaryTeardown())
    }
}
