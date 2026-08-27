import Foundation
import XCTest
@testable import SimulaAdSDK

final class StoreProductPrewarmerTests: XCTestCase {
    func testCapabilityVersionMatchesStoreKitOSAvailability() {
        XCTAssertEqual(
            DeviceCapabilities.supportedSKANVersion(
                for: OperatingSystemVersion(majorVersion: 13, minorVersion: 7, patchVersion: 0)
            ),
            "0"
        )
        XCTAssertEqual(
            DeviceCapabilities.supportedSKANVersion(
                for: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
            ),
            "2.1"
        )
        XCTAssertEqual(
            DeviceCapabilities.supportedSKANVersion(
                for: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
            ),
            "2.2"
        )
        XCTAssertEqual(
            DeviceCapabilities.supportedSKANVersion(
                for: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
            ),
            "3.0"
        )
        XCTAssertEqual(
            DeviceCapabilities.supportedSKANVersion(
                for: OperatingSystemVersion(majorVersion: 16, minorVersion: 0, patchVersion: 0)
            ),
            "3.0"
        )
        XCTAssertEqual(
            DeviceCapabilities.supportedSKANVersion(
                for: OperatingSystemVersion(majorVersion: 16, minorVersion: 1, patchVersion: 0)
            ),
            "4.0"
        )
    }

    func testIdentifierSelectionUsesPayloadVersion() {
        XCTAssertEqual(
            validatedSKANIdentifier(
                version: "3.0",
                campaignIdentifier: 42,
                sourceIdentifier: 1_234
            ),
            .campaign(42)
        )
        XCTAssertEqual(
            validatedSKANIdentifier(
                version: "4.0",
                campaignIdentifier: 42,
                sourceIdentifier: 1_234
            ),
            .source(1_234)
        )
    }

    func testIdentifierSelectionRejectsIncompleteOrOutOfRangePayloads() {
        XCTAssertNil(validatedSKANIdentifier(
            version: "3.0", campaignIdentifier: nil, sourceIdentifier: 1_234
        ))
        XCTAssertNil(validatedSKANIdentifier(
            version: "4.0", campaignIdentifier: 42, sourceIdentifier: nil
        ))
        XCTAssertNil(validatedSKANIdentifier(
            version: "3.0", campaignIdentifier: 101, sourceIdentifier: nil
        ))
        XCTAssertNil(validatedSKANIdentifier(
            version: "4.0", campaignIdentifier: nil, sourceIdentifier: 10_000
        ))
        XCTAssertNil(validatedSKANIdentifier(
            version: "5.0", campaignIdentifier: nil, sourceIdentifier: 1
        ))
    }

    func testPrewarmSlotIsBoundedAndConsumesOnlyExactMatch() throws {
        var slot = StoreProductPrewarmSlot<String, String>()
        let first = try XCTUnwrap(slot.reserve(key: "campaign-a", makeProduct: { "first" }))

        XCTAssertTrue(slot.isOccupied)
        XCTAssertNil(slot.reserve(key: "campaign-b", makeProduct: { "second" }))
        XCTAssertNil(slot.consume(key: "campaign-b"))
        XCTAssertEqual(slot.consume(key: "campaign-a"), "first")
        XCTAssertFalse(slot.isOccupied)

        let second = try XCTUnwrap(slot.reserve(key: "campaign-b", makeProduct: { "second" }))
        XCTAssertFalse(slot.remove(token: first.token))
        XCTAssertTrue(slot.remove(token: second.token))
        XCTAssertFalse(slot.isOccupied)
    }
}
