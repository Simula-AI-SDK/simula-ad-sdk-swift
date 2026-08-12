import CoreGraphics
import Foundation
import XCTest
@testable import SimulaAdSDK

final class BundledImageCacheTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        private var _decodes = 0
        private var _readerWasMain = false
        private var _decoderWasMain = false

        var snapshot: (reads: Int, decodes: Int, readerWasMain: Bool, decoderWasMain: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (_reads, _decodes, _readerWasMain, _decoderWasMain)
        }

        func recordRead() {
            lock.lock()
            _reads += 1
            _readerWasMain = _readerWasMain || Thread.isMainThread
            lock.unlock()
        }

        func recordDecode() {
            lock.lock()
            _decodes += 1
            _decoderWasMain = _decoderWasMain || Thread.isMainThread
            lock.unlock()
        }
    }

    @MainActor
    func testColdLoadReadsAndDecodesOffMainThenCaches() async {
        let probe = Probe()
        let cache = BundledImageCache(
            queueLabel: "test.bundled.image.off-main",
            reader: { _ in
                probe.recordRead()
                return Data([1])
            },
            decoder: { _, _ in
                probe.recordDecode()
                return Self.makeTestImage()
            }
        )

        let first = await cache.load(.gameIcon)
        let second = await cache.load(.gameIcon)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)

        let result = probe.snapshot
        XCTAssertEqual(result.reads, 1)
        XCTAssertEqual(result.decodes, 1)
        XCTAssertFalse(result.readerWasMain)
        XCTAssertFalse(result.decoderWasMain)
    }

    func testConcurrentRequestsCoalesceOnSerialCache() async {
        let probe = Probe()
        let cache = BundledImageCache(
            queueLabel: "test.bundled.image.coalesce",
            reader: { _ in
                probe.recordRead()
                return Data([1])
            },
            decoder: { _, _ in
                probe.recordDecode()
                return Self.makeTestImage()
            }
        )

        await withTaskGroup(of: CGImage?.self) { group in
            for _ in 0..<8 {
                group.addTask { await cache.load(.gamesUnavailable) }
            }
            for await image in group {
                XCTAssertNotNil(image)
            }
        }

        XCTAssertEqual(probe.snapshot.reads, 1)
        XCTAssertEqual(probe.snapshot.decodes, 1)
    }

    func testFailureIsNegativelyCached() async {
        let probe = Probe()
        let cache = BundledImageCache(
            queueLabel: "test.bundled.image.failure",
            reader: { _ in
                probe.recordRead()
                return nil
            },
            decoder: { _, _ in
                probe.recordDecode()
                return Self.makeTestImage()
            }
        )

        let first = await cache.load(.minigameInterstitialBackground)
        let second = await cache.load(.minigameInterstitialBackground)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(probe.snapshot.reads, 1)
        XCTAssertEqual(probe.snapshot.decodes, 0)
    }

    func testPackagedAssetsDecodeAtExpectedDimensions() async {
        let expected: [BundledImageAsset: (Int, Int)] = [
            .gameIcon: (256, 256),
            .gamesUnavailable: (512, 512),
            .minigameInterstitialBackground: (1024, 1536),
        ]
        for asset in BundledImageAsset.allCases {
            let image = await BundledImageCache.shared.load(asset)
            XCTAssertEqual(image?.width, expected[asset]?.0, "\(asset) width")
            XCTAssertEqual(image?.height, expected[asset]?.1, "\(asset) height")
        }
    }

    private static func makeTestImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        return context.makeImage()
    }
}
