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
}
#endif
