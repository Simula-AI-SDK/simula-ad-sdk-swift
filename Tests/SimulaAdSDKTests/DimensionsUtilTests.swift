import CoreGraphics
import XCTest
@testable import SimulaAdSDK

/// Tests for the dimensions util — `parseDimension` / `ParsedDimension.clampMinWidth`, the
/// client-side `width` parsing behind `NativeAdSlot(width:)`. Mirrors the Kotlin/Android SDK's
/// dimension handling.
final class DimensionsUtilTests: XCTestCase {

    // MARK: - Fill (default / invalid)

    func testNilIsFill() { XCTAssertEqual(parseDimension(nil), .fill) }
    func testEmptyStringIsFill() { XCTAssertEqual(parseDimension(""), .fill) }
    func testAutoIsFill() { XCTAssertEqual(parseDimension("auto"), .fill) }
    func testZeroIsFill() { XCTAssertEqual(parseDimension(0), .fill) }
    func testNegativeNumberIsFill() { XCTAssertEqual(parseDimension(-100), .fill) }
    func testGarbageStringIsFill() { XCTAssertEqual(parseDimension("banana"), .fill) }
    func testBoolIsFill() { XCTAssertEqual(parseDimension(true), .fill) }
    func testArrayIsFill() { XCTAssertEqual(parseDimension([300]), .fill) }
    func testNegativePercentIsFill() { XCTAssertEqual(parseDimension("-50%"), .fill) }
    func testZeroPercentIsFill() { XCTAssertEqual(parseDimension("0%"), .fill) }
    func testOverHundredPercentIsFill() { XCTAssertEqual(parseDimension("150%"), .fill) }

    // MARK: - Percentage (strings)

    func testPercentString() { XCTAssertEqual(parseDimension("80%"), .percentage(0.8)) }
    func testHundredPercentString() { XCTAssertEqual(parseDimension("100%"), .percentage(1.0)) }
    func testPercentStringTrimsWhitespace() { XCTAssertEqual(parseDimension("  50%  "), .percentage(0.5)) }

    // MARK: - Pixels (strings)

    func testNumericString() { XCTAssertEqual(parseDimension("300"), .pixels(300)) }
    func testPxString() { XCTAssertEqual(parseDimension("320px"), .pixels(320)) }
    func testPxStringCaseInsensitive() { XCTAssertEqual(parseDimension("320PX"), .pixels(320)) }
    func testPxStringTrimsWhitespace() { XCTAssertEqual(parseDimension("  400px  "), .pixels(400)) }

    // MARK: - Numbers

    func testFloatFractionIsPercentage() { XCTAssertEqual(parseDimension(Float(0.8)), .percentage(0.8)) }
    func testDoubleFractionIsPercentage() { XCTAssertEqual(parseDimension(Double(0.5)), .percentage(0.5)) }
    func testIntIsPixels() { XCTAssertEqual(parseDimension(300), .pixels(300)) }
    func testFloatGteOneIsPixels() { XCTAssertEqual(parseDimension(Float(320.0)), .pixels(320)) }

    // MARK: - clampMinWidth

    func testClampRaisesPixelsBelowMin() {
        XCTAssertEqual(ParsedDimension.pixels(100).clampMinWidth(300), .pixels(300))
    }
    func testClampLeavesPixelsAboveMin() {
        XCTAssertEqual(ParsedDimension.pixels(500).clampMinWidth(300), .pixels(500))
    }
    func testClampPassesThroughFill() {
        XCTAssertEqual(ParsedDimension.fill.clampMinWidth(300), .fill)
    }
    func testClampPassesThroughPercentage() {
        XCTAssertEqual(ParsedDimension.percentage(0.5).clampMinWidth(300), .percentage(0.5))
    }

    // MARK: - End-to-end (parse + clamp)

    func testEndToEndPxBelowMinClamps() {
        XCTAssertEqual(parseDimension("100px").clampMinWidth(300), .pixels(300))
    }
    func testEndToEndIntBelowMinClamps() {
        XCTAssertEqual(parseDimension(100).clampMinWidth(300), .pixels(300))
    }
    func testEndToEndFractionNotClamped() {
        // Percentages are enforced at layout time, not at parse time.
        XCTAssertEqual(parseDimension(0.1).clampMinWidth(300), .percentage(0.1))
    }
    func testEndToEndPxAboveMinUnchanged() {
        XCTAssertEqual(parseDimension("400px").clampMinWidth(300), .pixels(400))
    }
}
