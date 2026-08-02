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

    func testHugeFiniteDurationsAreClampedNotTrapped() {
        // Regression: `UInt64(duration * 1_000_000)` traps for finite durations ≳ 1.8e13 ms.
        // Absurd-but-finite host values must clamp to the max, never crash the host app.
        XCTAssertEqual(MiniGameInvitation.sanitizedAutoCloseDuration(.greatestFiniteMagnitude), MiniGameInvitation.maxAutoCloseDuration)
        XCTAssertEqual(MiniGameInvitation.sanitizedAutoCloseDuration(1e15), MiniGameInvitation.maxAutoCloseDuration)
        XCTAssertEqual(MiniGameInvitation.sanitizedAutoCloseDuration(MiniGameInvitation.maxAutoCloseDuration + 1), MiniGameInvitation.maxAutoCloseDuration)
        // Exactly at the cap passes through unchanged.
        XCTAssertEqual(MiniGameInvitation.sanitizedAutoCloseDuration(MiniGameInvitation.maxAutoCloseDuration), MiniGameInvitation.maxAutoCloseDuration)
    }

    func testClampedDurationFitsTheUInt64Conversion() {
        // The invariant runAutoClose relies on: sanitized values never overflow the ms→ns shift.
        let sanitized = MiniGameInvitation.sanitizedAutoCloseDuration(1e300)
        XCTAssertNotNil(sanitized)
        XCTAssertLessThan(sanitized! * 1_000_000, Double(UInt64.max))
    }
}
