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
        for bad in [-1.0, -0.01, Double.nan, Double.infinity, -Double.infinity] {
            let v = AdValue.fromBidCpm(bad)
            XCTAssertEqual(v.valueMicros, 0, "bid=\(bad) should clamp to 0 micros")
            XCTAssertEqual(v.expectedRevenue, 0, accuracy: eps)
        }
    }

    func testOutOfRangeBidsClampToZeroInsteadOfTrapping() {
        // Regression: `Int64(Double)` traps when the scaled value exceeds Int64.max — a backend
        // units bug (e.g. bid_amt: 1e16) must degrade to $0, not crash the host at the paid event.
        for absurd in [1e16, 9.3e15, 1e100, 1e308] {
            let v = AdValue.fromBidCpm(absurd)
            XCTAssertEqual(v.valueMicros, 0, "bid=\(absurd) should clamp to 0 micros, not trap")
        }
        // Largest in-range values still convert (just under the trap boundary).
        XCTAssertGreaterThan(AdValue.fromBidCpm(9.0e15).valueMicros, 0)
    }

    func testRespectsNonDefaultCurrency() {
        XCTAssertEqual(AdValue.fromBidCpm(3.0, currencyCode: "EUR").currencyCode, "EUR")
    }
}
