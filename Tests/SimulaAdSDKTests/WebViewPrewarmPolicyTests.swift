import XCTest
@testable import SimulaAdSDK

final class WebViewPrewarmPolicyTests: XCTestCase {
    func testDeviceAtTheMemoryFloorSkipsStartupPrewarm() {
        XCTAssertTrue(WebViewPrewarmPolicy.shouldSkipStartupPrewarm(
            physicalMemoryBytes: WebViewPrewarmPolicy.startupMemoryFloorBytes
        ))
    }

    func testDeviceBelowTheMemoryFloorSkipsStartupPrewarm() {
        XCTAssertTrue(WebViewPrewarmPolicy.shouldSkipStartupPrewarm(physicalMemoryBytes: 1_073_741_824)) // 1 GiB
    }

    func testDeviceAboveTheMemoryFloorPrewarms() {
        XCTAssertFalse(WebViewPrewarmPolicy.shouldSkipStartupPrewarm(
            physicalMemoryBytes: WebViewPrewarmPolicy.startupMemoryFloorBytes + 1
        ))
        XCTAssertFalse(WebViewPrewarmPolicy.shouldSkipStartupPrewarm(physicalMemoryBytes: 6_442_450_944)) // ~6 GiB
    }

    func testMemoryFloorIsTwoGiB() {
        // Guards the constant against accidental drift: 2 GiB = oldest iOS 15 device class.
        XCTAssertEqual(WebViewPrewarmPolicy.startupMemoryFloorBytes, 2_147_483_648)
    }
}
