import XCTest
@testable import SimulaAdSDK

final class WebViewRenderRecoveryTests: XCTestCase {
    func testBackoffIsOneTwoFourSeconds() {
        XCTAssertEqual(renderRecoveryBackoff(attempt: 1), 1)
        XCTAssertEqual(renderRecoveryBackoff(attempt: 2), 2)
        XCTAssertEqual(renderRecoveryBackoff(attempt: 3), 4)
    }

    func testBackoffClampsOutOfRangeAttempts() {
        XCTAssertEqual(renderRecoveryBackoff(attempt: 0), 1)   // floors to attempt 1
        XCTAssertEqual(renderRecoveryBackoff(attempt: -5), 1)
        XCTAssertEqual(renderRecoveryBackoff(attempt: 99), 4)  // caps at the max attempt
    }

    func testRecoveryCapIsThree() {
        // Guards the constant: cumulative, never reset — 3 strikes and the creative collapses
        // (parity with the load-failure path) instead of looping WebContent process churn.
        XCTAssertEqual(maxRenderRecoveries, 3)
    }

    func testNoReloadableContentDoesNotConsumeRecoveryBudget() {
        XCTAssertNil(nextRenderRecoveryAttempt(currentCount: 0, hasReloadableContent: false))
        XCTAssertNil(nextRenderRecoveryAttempt(currentCount: 2, hasReloadableContent: false))
    }

    func testReloadableContentAdvancesUntilCap() {
        XCTAssertEqual(nextRenderRecoveryAttempt(currentCount: 0, hasReloadableContent: true), 1)
        XCTAssertEqual(nextRenderRecoveryAttempt(currentCount: 2, hasReloadableContent: true), 3)
        XCTAssertNil(nextRenderRecoveryAttempt(currentCount: 3, hasReloadableContent: true))
    }
}
