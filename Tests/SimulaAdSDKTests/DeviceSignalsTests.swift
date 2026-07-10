import XCTest
@testable import SimulaAdSDK

/// Verifies the pure signal mappers and header assembly for `SimulaDeviceSignals`. The device reads
/// themselves need a live iOS runtime, so only the pure logic is unit-tested here.
final class DeviceSignalsTests: XCTestCase {

    // MARK: - volumePercent

    func testVolumePercentMapsToHundredScale() {
        XCTAssertEqual(SimulaDeviceSignals.volumePercent(0), 0)
        XCTAssertEqual(SimulaDeviceSignals.volumePercent(1), 100)
        XCTAssertEqual(SimulaDeviceSignals.volumePercent(0.5), 50)
    }

    func testVolumePercentIsNilWhenUnreadable() {
        XCTAssertNil(SimulaDeviceSignals.volumePercent(nil))
        XCTAssertNil(SimulaDeviceSignals.volumePercent(-1))
        XCTAssertNil(SimulaDeviceSignals.volumePercent(.nan))
    }

    // MARK: - batteryPercent

    func testBatteryPercentMapsValidRangeAndRejectsUnknown() {
        XCTAssertEqual(SimulaDeviceSignals.batteryPercent(0), 0)
        XCTAssertEqual(SimulaDeviceSignals.batteryPercent(0.87), 87)
        XCTAssertEqual(SimulaDeviceSignals.batteryPercent(1), 100)
        XCTAssertNil(SimulaDeviceSignals.batteryPercent(-1)) // UIDevice unknown
        XCTAssertNil(SimulaDeviceSignals.batteryPercent(nil))
    }

    // MARK: - batteryStateLabel

    func testBatteryStateMapsToStableLabels() {
        XCTAssertEqual(SimulaDeviceSignals.batteryStateLabel(0), "unknown")
        XCTAssertEqual(SimulaDeviceSignals.batteryStateLabel(1), "unplugged")
        XCTAssertEqual(SimulaDeviceSignals.batteryStateLabel(2), "charging")
        XCTAssertEqual(SimulaDeviceSignals.batteryStateLabel(3), "full")
        XCTAssertNil(SimulaDeviceSignals.batteryStateLabel(nil))
        XCTAssertNil(SimulaDeviceSignals.batteryStateLabel(99))
    }

    // MARK: - buildHeaders

    func testBuildHeadersEmitsEveryAvailableSignal() {
        let headers = SimulaDeviceSignals.buildHeaders(
            timezone: "America/Sao_Paulo",
            memoryFreeBytes: 654_321,
            batteryLevel: 0.87,
            batteryStateRaw: 2,
            outputVolume: 0.5
        )
        XCTAssertEqual(headers["X-Timezone"], "America/Sao_Paulo")
        XCTAssertEqual(headers["X-Memory-Free"], "654321")
        XCTAssertEqual(headers["X-Battery-Level"], "87")
        XCTAssertEqual(headers["X-Battery-State"], "charging")
        XCTAssertEqual(headers["X-Volume"], "50")
        // iOS has no public silent-switch API, so no ringer-mode header is emitted.
        XCTAssertNil(headers["X-Ringer-Mode"])
        // Free-disk-space is a required-reason API with no off-device-sending reason, so iOS never
        // emits X-Storage-Free (Android only).
        XCTAssertNil(headers["X-Storage-Free"])
    }

    func testBuildHeadersOmitsUnavailableSignals() {
        let headers = SimulaDeviceSignals.buildHeaders(
            timezone: "",
            memoryFreeBytes: nil,
            batteryLevel: -1,
            batteryStateRaw: nil,
            outputVolume: nil
        )
        XCTAssertTrue(headers.isEmpty)
    }
}
