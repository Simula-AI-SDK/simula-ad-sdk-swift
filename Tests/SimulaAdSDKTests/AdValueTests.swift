import XCTest
@testable import SimulaAdSDK

/// Tests for the AdMob-shaped `AdValue` derivation from the backend `bid_amt` (CPM). The three
/// figures must always agree (all derived from one `valueMicros`), and a missing/garbage bid must
/// degrade to a $0 estimate rather than trapping — surfacing the paid event can't crash the host.
/// Mirrors the Kotlin/Android SDK's `AdValueTest`.
final class AdValueTests: XCTestCase {

    private let eps = 1e-9

    func testDerivesAdMobBlockFromWholeDollarCPM() {
        // PRD worked example: $5.00 CPM → valueMicros 5000 → $0.005 per impression.
        let v = AdValue.fromBidCpm(5.0)
        XCTAssertEqual(v.valueMicros, 5000)
        XCTAssertEqual(v.currencyCode, "USD")
        XCTAssertEqual(v.precisionType, .estimated)
        XCTAssertEqual(v.expectedCpm, 5.0, accuracy: eps)        // valueMicros / 1_000
        XCTAssertEqual(v.expectedRevenue, 0.005, accuracy: eps)  // valueMicros / 1_000_000
    }

    func testCarriesSubDollarCPMPrecision() {
        let v = AdValue.fromBidCpm(5.5)
        XCTAssertEqual(v.valueMicros, 5500)
        XCTAssertEqual(v.expectedCpm, 5.5, accuracy: eps)
        XCTAssertEqual(v.expectedRevenue, 0.0055, accuracy: eps)
    }

    func testFiguresAreAlwaysConsistent() {
        let v = AdValue.fromBidCpm(12.34)
        XCTAssertEqual(v.expectedCpm, Double(v.valueMicros) / 1_000, accuracy: eps)
        XCTAssertEqual(v.expectedRevenue, Double(v.valueMicros) / 1_000_000, accuracy: eps)
    }

    func testZeroBidYieldsZeroEstimate() {
        let v = AdValue.fromBidCpm(0)
        XCTAssertEqual(v.valueMicros, 0)
        XCTAssertEqual(v.expectedCpm, 0, accuracy: eps)
        XCTAssertEqual(v.expectedRevenue, 0, accuracy: eps)
        XCTAssertEqual(v.precisionType, .estimated)
    }

    func testNegativeAndNonFiniteBidsClampToZero() {
        for bad in [-1.0, -0.01, -Double.greatestFiniteMagnitude, Double.nan, Double.infinity, -Double.infinity] {
            let v = AdValue.fromBidCpm(bad)
            XCTAssertEqual(v.valueMicros, 0, "bid=\(bad) should clamp to 0 micros")
            XCTAssertEqual(v.expectedRevenue, 0, accuracy: eps)
        }
    }

    func testOversizedFiniteBidFallsBackToZero() {
        let v = AdValue.fromBidCpm(.greatestFiniteMagnitude)
        XCTAssertEqual(v.valueMicros, 0)
        XCTAssertEqual(v.expectedCpm, 0, accuracy: eps)
        XCTAssertEqual(v.expectedRevenue, 0, accuracy: eps)
    }

    func testNormalFractionalBidPreservesRounding() {
        XCTAssertEqual(AdValue.fromBidCpm(1.2345).valueMicros, 1_235)
    }

    func testRespectsNonDefaultCurrency() {
        XCTAssertEqual(AdValue.fromBidCpm(3.0, currencyCode: "EUR").currencyCode, "EUR")
    }
}
