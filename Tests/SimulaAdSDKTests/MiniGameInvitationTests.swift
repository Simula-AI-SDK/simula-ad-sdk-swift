import XCTest
@testable import SimulaAdSDK

/// Regression: a host passing `.infinity` (or NaN/absurd values) as `autoCloseDuration` must
/// get "no auto-close", not a trapped `UInt64(duration * 1_000_000)` conversion.
final class MiniGameInvitationTests: XCTestCase {
    func testInfinityAndNaNSanitizeToNoAutoClose() {
        XCTAssertNil(MiniGameInvitation.sanitizedAutoCloseDuration(.infinity))
        XCTAssertNil(MiniGameInvitation.sanitizedAutoCloseDuration(-.infinity))
        XCTAssertNil(MiniGameInvitation.sanitizedAutoCloseDuration(.nan))
    }

    func testNilZeroAndNegativeSanitizeToNoAutoClose() {
        XCTAssertNil(MiniGameInvitation.sanitizedAutoCloseDuration(nil))
        XCTAssertNil(MiniGameInvitation.sanitizedAutoCloseDuration(0))
        XCTAssertNil(MiniGameInvitation.sanitizedAutoCloseDuration(-5))
    }

    func testFinitePositiveDurationsPassThrough() {
        XCTAssertEqual(MiniGameInvitation.sanitizedAutoCloseDuration(1_500), 1_500)
        XCTAssertEqual(MiniGameInvitation.sanitizedAutoCloseDuration(0.5), 0.5)
    }
}
