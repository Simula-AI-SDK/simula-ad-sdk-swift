#if os(iOS)
import XCTest
@testable import SimulaAdSDK

@MainActor
final class NativeAdPreloadCacheTests: XCTestCase {
    func testPreloadInvokesMetadataFreeLoaderAndReturnsItsResponse() async throws {
        var loadCount = 0
        let cache = NativeAdPreloadCache { _, _, _, _ in
            loadCount += 1
            return NativeAdResponse(
                impressionId: "preloaded-impression",
                adInserted: true,
                adFormat: "character_ad",
                renderedHtml: "<div>ad</div>"
            )
        }

        let id = cache.preloadForTests(
            adUnitId: "feed",
            position: 1,
            theme: nil
        )
        guard let id else {
            return XCTFail("Expected preload id")
        }
        let consumed = await cache.consume(id)

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(consumed?.impressionId, "preloaded-impression")
    }

    func testCancelledConsumerLeavesPreloadAvailableForRemount() async throws {
        let releaseLoad = AsyncStream<Void>.makeStream()
        let cache = NativeAdPreloadCache { _, _, _, _ in
            for await _ in releaseLoad.stream { break }
            return NativeAdResponse(
                impressionId: "preloaded-impression",
                adInserted: true,
                adFormat: "character_ad",
                renderedHtml: "<div>ad</div>"
            )
        }
        let id = try XCTUnwrap(cache.preloadForTests(
            adUnitId: "feed",
            position: 3,
            theme: nil
        ))
        let firstConsumer = Task { @MainActor in await cache.consume(id) }

        firstConsumer.cancel()
        releaseLoad.continuation.yield()
        releaseLoad.continuation.finish()
        _ = await firstConsumer.value
        let remounted = await cache.consume(id)

        XCTAssertEqual(remounted?.impressionId, "preloaded-impression")
    }

    func testCancelledPreloadResolutionCannotFallThroughAsUnavailable() async {
        let consumeStarted = expectation(description: "consume started")
        let releaseConsume = AsyncStream<Void>.makeStream()
        let resolution = Task { @MainActor in
            await resolveNativeAdPreload("preloaded-id") { _ in
                consumeStarted.fulfill()
                for await _ in releaseConsume.stream { break }
                return nil
            }
        }
        await fulfillment(of: [consumeStarted], timeout: TestWait.timeout)

        resolution.cancel()
        releaseConsume.continuation.yield()
        releaseConsume.continuation.finish()

        guard case .cancelled = await resolution.value else {
            return XCTFail("Cancelled preload resolution must stop the slot load")
        }
    }

    func testFailedUnconsumedPreloadsReleaseCapacity() async throws {
        enum LoadError: Error { case failed }
        var loadCount = 0
        let cache = NativeAdPreloadCache { _, _, _, _ in
            loadCount += 1
            throw LoadError.failed
        }

        for position in 0..<5 {
            XCTAssertNotNil(cache.preloadForTests(adUnitId: "feed", position: position, theme: nil))
        }
        await waitUntil { loadCount == 5 }

        XCTAssertNotNil(cache.preloadForTests(adUnitId: "feed", position: 6, theme: nil))
    }

    func testMismatchedProviderNativeLoadFailsBeforeSessionOrNetwork() async {
        let ownership = ProcessApiKeyOwnership()
        _ = SimulaProvider(testApiKey: "winning-key", apiKeyOwnership: ownership)
        let mismatched = SimulaProvider(testApiKey: "losing-key", apiKeyOwnership: ownership)

        do {
            _ = try await NativeAdController.load(
                provider: mismatched,
                adUnitId: "feed",
                position: 0
            )
            XCTFail("mismatched provider must not load an ad")
        } catch let error as SimulaAdError {
            guard case .noSession = error else {
                return XCTFail("unexpected SimulaAdError: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
#endif
