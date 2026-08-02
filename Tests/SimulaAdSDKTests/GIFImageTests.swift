import XCTest
@testable import SimulaAdSDK

/// iOS-5: the preload fan-out is chunked (bounded concurrency) — the helper is pure.
final class GIFImageTests: XCTestCase {
    func testChunksSplitIntoBoundedGroups() {
        let urls = (1...7).map { "u\($0)" }
        XCTAssertEqual(
            CoverImageCache.chunks(urls, size: 3),
            [["u1", "u2", "u3"], ["u4", "u5", "u6"], ["u7"]]
        )
    }

    func testChunksEdgeCases() {
        XCTAssertEqual(CoverImageCache.chunks([], size: 3), [])
        XCTAssertEqual(CoverImageCache.chunks(["a"], size: 3), [["a"]])
        XCTAssertEqual(CoverImageCache.chunks(["a", "b"], size: 1), [["a"], ["b"]])
        // A non-positive size must not loop forever — falls back to one group.
        XCTAssertEqual(CoverImageCache.chunks(["a", "b"], size: 0), [["a", "b"]])
    }

    func testOnly2xxCoverResponsesAreAccepted() {
        XCTAssertFalse(isSuccessfulCoverHTTPStatus(199))
        XCTAssertTrue(isSuccessfulCoverHTTPStatus(200))
        XCTAssertTrue(isSuccessfulCoverHTTPStatus(204))
        XCTAssertTrue(isSuccessfulCoverHTTPStatus(299))
        XCTAssertFalse(isSuccessfulCoverHTTPStatus(300))
        XCTAssertFalse(isSuccessfulCoverHTTPStatus(404))
        XCTAssertFalse(isSuccessfulCoverHTTPStatus(503))
    }
}
