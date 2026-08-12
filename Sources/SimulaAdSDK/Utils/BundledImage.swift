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

/// Three-entry, single-flight cache for SDK-bundled images. Asset-specific downsampling bounds the
/// decoded total below 8 MB; memory pressure clears it. Bundle lookup, file I/O, and ImageIO work
/// all run on a serial utility queue; SwiftUI only wraps the ready `CGImage`.
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
    private var cache: [BundledImageAsset: Entry] = [:]

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

    func load(_ asset: BundledImageAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let cached = cache[asset] {
                    continuation.resume(returning: cached.image)
                    return
                }
                guard let data = reader(asset), let image = decoder(data, asset) else {
                    cache[asset] = .failed
                    continuation.resume(returning: nil)
                    return
                }
                cache[asset] = .image(image)
                continuation.resume(returning: image)
            }
        }
    }

    func clear() {
        queue.async { [self] in cache.removeAll() }
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

    @State private var phase: BundledImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: asset) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        phase = .empty
        let image = await BundledImageCache.shared.load(asset)
        guard !Task.isCancelled else { return }
        if let image {
            phase = .success(Image(platformImage: makePlatformImage(cgImage: image)))
        } else {
            phase = .failure
        }
    }
}
