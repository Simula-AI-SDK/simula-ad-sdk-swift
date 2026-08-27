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
        XCTAssertTrue(slot.isOccupied, "an in-flight consumed controller keeps the allocation bound")

        let completion = slot.complete(token: first.token, loaded: true)
        XCTAssertFalse(completion.retainedReadyProduct)
        XCTAssertEqual(completion.nextKey, "campaign-b")
        XCTAssertFalse(slot.isOccupied)
    }

    func testCompletedProductCanBeReplacedWithoutOverlappingLoads() throws {
        var slot = StoreProductPrewarmSlot<String, String>()
        let first = try XCTUnwrap(slot.reserve(key: "campaign-a", makeProduct: { "first" }))
        let completion = slot.complete(token: first.token, loaded: true)
        XCTAssertTrue(completion.retainedReadyProduct)

        let second = try XCTUnwrap(slot.reserve(key: "campaign-b", makeProduct: { "second" }))
        XCTAssertEqual(second.product, "second")
        XCTAssertNil(slot.consume(key: "campaign-a"))
        XCTAssertEqual(slot.consume(key: "campaign-b"), "second")
    }

    func testFailedLoadAdvancesLatestQueuedCandidate() throws {
        var slot = StoreProductPrewarmSlot<String, String>()
        let first = try XCTUnwrap(slot.reserve(key: "campaign-a", makeProduct: { "first" }))
        XCTAssertNil(slot.reserve(key: "campaign-b", makeProduct: { "second" }))
        XCTAssertNil(slot.reserve(key: "campaign-c", makeProduct: { "third" }))

        let completion = slot.complete(token: first.token, loaded: false)
        XCTAssertFalse(completion.retainedReadyProduct)
        XCTAssertEqual(completion.nextKey, "campaign-c")
        XCTAssertFalse(slot.isOccupied)
    }
}
