#if os(iOS)
import XCTest
@testable import SimulaAdSDK

@MainActor
final class NativeAdPreloadCacheTests: XCTestCase {
    func testPreloadSnapshotsMetadataForLoadAndConsumption() async throws {
        var loadedMetadata: [String: String]?
        let cache = NativeAdPreloadCache { _, _, _, _, metadata in
            loadedMetadata = metadata
            return NativeAdResponse(
                impressionId: "preloaded-impression",
                adInserted: true,
                adFormat: "character_ad",
                renderedHtml: "<div>ad</div>"
            )
        }
        let provider = SimulaProvider(apiKey: "test-api-key")
        var source = ["screen": "search"]

        let id = cache.preload(
            provider: provider,
            adUnitId: "feed",
            position: 1,
            theme: nil,
            metadata: source
        )
        source["screen"] = "mutated"
        guard let id else {
            return XCTFail("Expected preload id")
        }
        let consumed = await cache.consume(id)

        XCTAssertEqual(loadedMetadata, ["screen": "search"])
        XCTAssertEqual(consumed?.metadata, ["screen": "search"])
    }

    func testPreloadWithoutMetadataRetainsNilSnapshot() async {
        let cache = NativeAdPreloadCache { _, _, _, _, _ in
            NativeAdResponse(
                impressionId: "preloaded-impression",
                adInserted: true,
                adFormat: "character_ad",
                renderedHtml: "<div>ad</div>"
            )
        }
        let provider = SimulaProvider(apiKey: "test-api-key")
        let id = cache.preload(provider: provider, adUnitId: "feed", position: 2, theme: nil, metadata: nil)
        guard let id else {
            return XCTFail("Expected preload id")
        }
        let consumed = await cache.consume(id)

        XCTAssertNil(consumed?.metadata)
    }

    func testCancelledConsumerLeavesPreloadAvailableForRemount() async throws {
        let releaseLoad = AsyncStream<Void>.makeStream()
        let cache = NativeAdPreloadCache { _, _, _, _, _ in
            for await _ in releaseLoad.stream { break }
            return NativeAdResponse(
                impressionId: "preloaded-impression",
                adInserted: true,
                adFormat: "character_ad",
                renderedHtml: "<div>ad</div>"
            )
        }
        let provider = SimulaProvider(apiKey: "test-api-key")
        let id = try XCTUnwrap(cache.preload(
            provider: provider,
            adUnitId: "feed",
            position: 3,
            theme: nil,
            metadata: ["screen": "search"]
        ))
        let firstConsumer = Task { @MainActor in await cache.consume(id) }

        firstConsumer.cancel()
        releaseLoad.continuation.yield()
        releaseLoad.continuation.finish()
        _ = await firstConsumer.value
        let remounted = await cache.consume(id)

        XCTAssertEqual(remounted?.metadata, ["screen": "search"])
    }
}
#endif
