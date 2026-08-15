import SwiftUI
import ImageIO
#if os(iOS)
import UIKit
#endif

enum BundledImageAsset: String, CaseIterable, Hashable, Sendable {
    case gameIcon = "game_icon"
    case gamesUnavailable = "games_unavailable"
    case minigameInterstitialBackground = "minigame_interstitial_background"
}

enum BundledImageCacheLookup {
    case miss
    case image(CGImage)
    case failed
}

/// Three-entry, single-flight cache for SDK-bundled images. Asset-specific downsampling bounds the
/// decoded total below 8 MB; memory pressure clears it. Bundle lookup, file I/O, and ImageIO work
/// all run on a serial utility queue; the lock-backed peek only reads already-decoded process memory.
final class BundledImageCache: @unchecked Sendable {
    static let shared = BundledImageCache()

    typealias Reader = (BundledImageAsset) -> Data?
    typealias Decoder = (Data, BundledImageAsset) -> CGImage?

    private enum Entry {
        case image(CGImage)
        case failed

        var image: CGImage? {
            if case .image(let image) = self { return image }
            return nil
        }
    }

    private let queue: DispatchQueue
    private let reader: Reader
    private let decoder: Decoder
    private let lock = NSLock()
    private var cache: [BundledImageAsset: Entry] = [:]
    private var generation: UInt64 = 0

    init(
        queueLabel: String = "ad.simula.images.bundled",
        reader: @escaping Reader = BundledImageCache.readBundledAsset,
        decoder: @escaping Decoder = BundledImageCache.decodeImmediately
    ) {
        queue = DispatchQueue(label: queueLabel, qos: .utility)
        self.reader = reader
        self.decoder = decoder
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clear()
        }
        #endif
    }

    func peek(_ asset: BundledImageAsset) -> BundledImageCacheLookup {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = cache[asset] else { return .miss }
        switch cached {
        case .image(let image): return .image(image)
        case .failed: return .failed
        }
    }

    func load(_ asset: BundledImageAsset) async -> CGImage? {
        lock.lock()
        let initial = cache[asset]
        lock.unlock()
        if let initial { return initial.image }

        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            queue.async { [self] in
                lock.lock()
                if let cached = cache[asset] {
                    lock.unlock()
                    continuation.resume(returning: cached.image)
                    return
                }
                // Capture after this serial load actually starts. A request queued before a clear but
                // started afterward is fresh work and may populate the new generation; a clear during
                // decode still invalidates the result below.
                let requestGeneration = generation
                lock.unlock()

                guard let data = reader(asset), let image = decoder(data, asset) else {
                    lock.lock()
                    if generation == requestGeneration { cache[asset] = .failed }
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                lock.lock()
                if generation == requestGeneration { cache[asset] = .image(image) }
                lock.unlock()
                continuation.resume(returning: image)
            }
        }
    }

    func clear() {
        lock.lock()
        generation &+= 1
        cache.removeAll()
        lock.unlock()
    }

    private static func readBundledAsset(_ asset: BundledImageAsset) -> Data? {
        guard let url = Bundle.module.url(forResource: asset.rawValue, withExtension: "png") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func decodeImmediately(_ data: Data, asset: BundledImageAsset) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let maxPixelSize: Int
        switch asset {
        case .gameIcon: maxPixelSize = 256
        case .gamesUnavailable: maxPixelSize = 512
        case .minigameInterstitialBackground: maxPixelSize = 1536
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

enum BundledImagePhase {
    case empty
    case success(Image)
    case failure
}

/// Async bundled-image surface mirroring `AsyncImage` phases without any main-thread disk/decode.
struct BundledImage<Content: View>: View {
    let asset: BundledImageAsset
    @ViewBuilder let content: (BundledImagePhase) -> Content

    @State private var phase: BundledImagePhase

    init(
        asset: BundledImageAsset,
        @ViewBuilder content: @escaping (BundledImagePhase) -> Content
    ) {
        self.asset = asset
        self.content = content
        switch BundledImageCache.shared.peek(asset) {
        case .miss:
            _phase = State(initialValue: .empty)
        case .image(let image):
            _phase = State(initialValue: .success(Image(platformImage: makePlatformImage(cgImage: image))))
        case .failed:
            _phase = State(initialValue: .failure)
        }
    }

    var body: some View {
        content(phase)
            .task(id: asset) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        switch BundledImageCache.shared.peek(asset) {
        case .image(let image):
            phase = .success(Image(platformImage: makePlatformImage(cgImage: image)))
            return
        case .failed:
            phase = .failure
            return
        case .miss:
            phase = .empty
        }
        let image = await BundledImageCache.shared.load(asset)
        guard !Task.isCancelled else { return }
        if let image {
            phase = .success(Image(platformImage: makePlatformImage(cgImage: image)))
        } else {
            phase = .failure
        }
    }
}
