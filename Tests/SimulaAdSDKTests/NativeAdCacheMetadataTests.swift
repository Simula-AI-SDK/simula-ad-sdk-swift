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

    func testCachedFillRetainsItsLoadTimeMetadataSnapshot() throws {
        let loadMetadata = ["placement": "original"]
        let response = NativeAdResponse(
            impressionId: "imp-1",
            adInserted: true,
            adFormat: "character_ad",
            renderedHtml: "<div>ad</div>"
        )

        NativeAdCache.shared.putFill("unit", 2, response, metadata: loadMetadata)
        let cached = try XCTUnwrap(NativeAdCache.shared.get("unit", 2))

        XCTAssertEqual(cached.metadata, loadMetadata)
        XCTAssertNotEqual(cached.metadata, ["placement": "remount"])
    }

    func testPreloadedFillRetainsPreloadMetadataInsteadOfMountMetadata() throws {
        let preloadMetadata = ["screen": "search"]
        let response = NativeAdResponse(
            impressionId: "preload-imp",
            adInserted: true,
            adFormat: "character_ad",
            renderedHtml: "<div>ad</div>"
        )

        NativeAdCache.shared.putFill("unit", 3, response, metadata: preloadMetadata)
        let cached = try XCTUnwrap(NativeAdCache.shared.get("unit", 3))

        XCTAssertEqual(cached.metadata, preloadMetadata)
        XCTAssertNotEqual(cached.metadata, ["screen": "mount"])
    }
}
#endif
