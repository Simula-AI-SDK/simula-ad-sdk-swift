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
        XCTAssertEqual(
            validateSKANIdentifier(
                version: "3.0", campaignIdentifier: nil, sourceIdentifier: nil
            ),
            .rejected(.missingCampaignID)
        )
        XCTAssertEqual(
            validateSKANIdentifier(
                version: "4.0", campaignIdentifier: nil, sourceIdentifier: 10_000
            ),
            .rejected(.invalidSourceID)
        )
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
        XCTAssertNil(completion.nextKey)
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

    func testLookupReportsReadyLoadingAndMissReasons() throws {
        var slot = StoreProductPrewarmSlot<String, String>()
        if case .miss(let reason) = slot.lookup(key: "a") {
            XCTAssertEqual(reason, .empty)
        } else {
            XCTFail("expected empty miss")
        }

        let loading = try XCTUnwrap(slot.reserve(key: "a", makeProduct: { "loading" }))
        if case .miss(let reason) = slot.lookup(key: "b") {
            XCTAssertEqual(reason, .keyMismatch)
        } else {
            XCTFail("expected key mismatch")
        }
        if case .hit(let product, let ready) = slot.lookup(key: "a") {
            XCTAssertEqual(product, "loading")
            XCTAssertFalse(ready)
        } else {
            XCTFail("expected loading hit")
        }
        if case .miss(let reason) = slot.lookup(key: "a") {
            XCTAssertEqual(reason, .alreadyConsumed)
        } else {
            XCTFail("expected consumed miss")
        }
        _ = slot.complete(token: loading.token, loaded: true)

        let readyReservation = try XCTUnwrap(slot.reserve(key: "a", makeProduct: { "ready" }))
        XCTAssertTrue(slot.complete(token: readyReservation.token, loaded: true).retainedReadyProduct)
        if case .hit(let product, let ready) = slot.lookup(key: "a") {
            XCTAssertEqual(product, "ready")
            XCTAssertTrue(ready)
        } else {
            XCTFail("expected ready hit")
        }
    }

    func testDisableKeepsLoadingBoundButPreventsConsumption() throws {
        var slot = StoreProductPrewarmSlot<String, String>()
        let first = try XCTUnwrap(slot.reserve(key: "a", makeProduct: { "first" }))

        slot.disable()

        if case .miss(let reason) = slot.lookup(key: "a") {
            XCTAssertEqual(reason, .disabled)
        } else {
            XCTFail("expected disabled miss")
        }
        XCTAssertNil(slot.reserve(key: "b", makeProduct: { "second" }))
        let completion = slot.complete(token: first.token, loaded: true)
        XCTAssertFalse(completion.retainedReadyProduct)
        XCTAssertEqual(completion.nextKey, "b")
    }

    func testDisableDropsReadyProductImmediately() throws {
        var slot = StoreProductPrewarmSlot<String, String>()
        let first = try XCTUnwrap(slot.reserve(key: "a", makeProduct: { "first" }))
        XCTAssertTrue(slot.complete(token: first.token, loaded: true).retainedReadyProduct)

        slot.disable()

        XCTAssertFalse(slot.isOccupied)
        XCTAssertNotNil(slot.reserve(key: "b", makeProduct: { "second" }))
    }

    func testLookupMissCancelsQueuedDuplicateBeforeColdFallback() throws {
        var slot = StoreProductPrewarmSlot<String, String>()
        let first = try XCTUnwrap(slot.reserve(key: "a", makeProduct: { "first" }))
        XCTAssertNil(slot.reserve(key: "b", makeProduct: { "second" }))

        if case .miss(let reason) = slot.lookup(key: "b") {
            XCTAssertEqual(reason, .keyMismatch)
        } else {
            XCTFail("expected key mismatch")
        }

        let completion = slot.complete(token: first.token, loaded: true)
        XCTAssertNil(completion.nextKey, "tap-time cold load must cancel queued duplicate prewarm")
    }

    func testReenableSameKeyQueuesBehindDisabledInflightLoad() throws {
        var slot = StoreProductPrewarmSlot<String, String>()
        let first = try XCTUnwrap(slot.reserve(key: "a", makeProduct: { "first" }))
        slot.disable()

        XCTAssertNil(slot.reserve(key: "a", makeProduct: { "replacement" }))

        let completion = slot.complete(token: first.token, loaded: true)
        XCTAssertEqual(completion.nextKey, "a")
    }

}
