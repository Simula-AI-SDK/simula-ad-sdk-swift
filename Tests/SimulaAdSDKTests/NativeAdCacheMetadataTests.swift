#if os(iOS)
import XCTest
@testable import SimulaAdSDK

final class NativeAdCacheMetadataTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NativeAdCache.shared.invalidateAll()
    }

    override func tearDown() {
        NativeAdCache.shared.invalidateAll()
        super.tearDown()
    }

    func testNormalFillHasNoPendingSeenMetadata() throws {
        let response = NativeAdResponse(
            impressionId: "imp-1",
            adInserted: true,
            adFormat: "character_ad",
            renderedHtml: "<div>ad</div>"
        )

        NativeAdCache.shared.putFill("unit", 2, response, metadata: nil)
        let cached = try XCTUnwrap(NativeAdCache.shared.get("unit", 2))

        XCTAssertNil(cached.metadata)
    }

    func testPreloadedFillRetainsMountMetadataForSeen() throws {
        let mountMetadata = ["screen": "search"]
        let response = NativeAdResponse(
            impressionId: "preload-imp",
            adInserted: true,
            adFormat: "character_ad",
            renderedHtml: "<div>ad</div>"
        )

        NativeAdCache.shared.putFill("unit", 3, response, metadata: mountMetadata)
        let cached = try XCTUnwrap(NativeAdCache.shared.get("unit", 3))

        XCTAssertEqual(cached.metadata, mountMetadata)
    }

    func testCacheSeedRestoresFillOnFirstRender() throws {
        let response = NativeAdResponse(
            impressionId: "recycled-fill",
            adInserted: true,
            adFormat: "character_ad",
            renderedHtml: "<div>cached</div>"
        )
        let entry = NativeAdCache.shared.putFill("unit", 4, response, metadata: ["feed": "home"])
        entry.heightPt = 212
        entry.impressionFired = true

        let seed = nativeAdSlotCacheSeed(
            hasPreview: false,
            hasPreloadedAd: false,
            cachedEntry: NativeAdCache.shared.get("unit", 4)
        )

        guard case .filled(let seededResponse) = seed.phase else {
            return XCTFail("cached fill must be present synchronously")
        }
        XCTAssertEqual(seededResponse.impressionId, "recycled-fill")
        XCTAssertEqual(seed.heightPt, 212)
        XCTAssertTrue(seed.impressionFired)
        XCTAssertEqual(seed.metadata, ["feed": "home"])
    }

    func testCacheSeedRestoresNoFillAtZeroHeight() {
        NativeAdCache.shared.putNoFill("unit", 5)

        let seed = nativeAdSlotCacheSeed(
            hasPreview: false,
            hasPreloadedAd: false,
            cachedEntry: NativeAdCache.shared.get("unit", 5)
        )

        guard case .empty = seed.phase else { return XCTFail("cached no-fill must start empty") }
        XCTAssertEqual(seed.heightPt, 0)
        XCTAssertFalse(seed.impressionFired)
    }

    func testCacheSeedIsHarmlessWhenProviderCompatibilityBlocksRendering() {
        let response = NativeAdResponse(
            impressionId: "incompatible-fill",
            adInserted: true,
            adFormat: "character_ad",
            renderedHtml: "<div>cached</div>"
        )
        NativeAdCache.shared.putFill("unit", 6, response, metadata: nil).heightPt = 180
        let seed = nativeAdSlotCacheSeed(
            hasPreview: false,
            hasPreloadedAd: false,
            cachedEntry: NativeAdCache.shared.get("unit", 6)
        )
        let compatible = nativeAdSlotStartupPlan(
            providerCompatible: true,
            hasPreview: false,
            hasPreloadedAd: false
        )
        let incompatible = nativeAdSlotStartupPlan(
            providerCompatible: false,
            hasPreview: false,
            hasPreloadedAd: false
        )

        guard case .filled = seed.phase else { return XCTFail("snapshot should preserve the cached fill") }
        XCTAssertTrue(compatible.rendersContent)
        XCTAssertTrue(compatible.restoresRetainedCreative)
        XCTAssertFalse(incompatible.rendersContent)
        XCTAssertFalse(incompatible.readsCache)
        XCTAssertFalse(incompatible.restoresRetainedCreative)
        XCTAssertFalse(incompatible.loadsNetwork)
    }
}
#endif
