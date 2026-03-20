import SwiftUI
import ImageIO

#if os(iOS)
import UIKit
private typealias PlatformImage = UIImage
private func makePlatformImage(cgImage: CGImage) -> PlatformImage {
    UIImage(cgImage: cgImage)
}
private extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif os(macOS)
import AppKit
private typealias PlatformImage = NSImage
private func makePlatformImage(cgImage: CGImage) -> PlatformImage {
    NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}
private extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif

// MARK: - CoverImageCache

/// In-memory image cache with GIF support using ImageIO (no external dependencies).
/// Downloads and decodes images, caching results for reuse across carousel scrolls.
final class CoverImageCache {
    static let shared = CoverImageCache()

    enum CoverImage {
        case staticImage(Any) // PlatformImage stored as Any to avoid private type leak
        case animatedGIF(frames: [(image: Any, duration: TimeInterval)])
        case failed

        fileprivate var platformImage: PlatformImage? {
            if case .staticImage(let img) = self { return img as? PlatformImage }
            return nil
        }

        fileprivate var gifFrames: [(image: PlatformImage, duration: TimeInterval)]? {
            if case .animatedGIF(let frames) = self {
                return frames.compactMap { f in
                    guard let img = f.image as? PlatformImage else { return nil }
                    return (img, f.duration)
                }
            }
            return nil
        }
    }

    private var cache: [String: CoverImage] = [:]
    private let queue = DispatchQueue(label: "com.simula.coverImageCache")

    private init() {}

    /// Preload multiple URLs in parallel. Completes when all are cached.
    func preload(urls: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                let alreadyCached = queue.sync { cache[url] != nil }
                guard !alreadyCached else { continue }
                group.addTask { [weak self] in
                    _ = await self?.load(url: url)
                }
            }
        }
    }

    /// Load a single URL, returning cached result if available.
    func load(url: String) async -> CoverImage {
        if let cached = queue.sync(execute: { cache[url] }) {
            return cached
        }

        guard let requestUrl = URL(string: url) else {
            let result = CoverImage.failed
            queue.sync { cache[url] = result }
            return result
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: requestUrl)
            let result = decodeImage(data: data)
            queue.sync { cache[url] = result }
            return result
        } catch {
            let result = CoverImage.failed
            queue.sync { cache[url] = result }
            return result
        }
    }

    func clearCache() {
        queue.sync { cache.removeAll() }
    }

    // MARK: - Decoding

    private func decodeImage(data: Data) -> CoverImage {
        // Check GIF magic bytes: GIF87a or GIF89a
        let isGIF = data.count >= 6 && data.prefix(3) == Data([0x47, 0x49, 0x46])
        if isGIF {
            return decodeGIF(data: data)
        }
        // Static image
        #if os(iOS)
        if let img = UIImage(data: data) { return .staticImage(img as Any) }
        #elseif os(macOS)
        if let img = NSImage(data: data) { return .staticImage(img as Any) }
        #endif
        return .failed
    }

    private func decodeGIF(data: Data) -> CoverImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .failed }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return .failed }

        if count == 1 {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .failed }
            return .staticImage(makePlatformImage(cgImage: cgImage) as Any)
        }

        var frames: [(Any, TimeInterval)] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let duration = gifFrameDuration(source: source, index: i)
            frames.append((makePlatformImage(cgImage: cgImage) as Any, duration))
        }
        return frames.isEmpty ? .failed : .animatedGIF(frames: frames)
    }

    private func gifFrameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let gifProps = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
            return 0.1
        }
        if let delay = gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, delay > 0.001 {
            return delay
        }
        if let delay = gifProps[kCGImagePropertyGIFDelayTime as String] as? Double, delay > 0.001 {
            return delay
        }
        return 0.1
    }
}

// MARK: - AnimatedGIFView

/// Cycles through decoded GIF frames using a Timer.
private struct AnimatedGIFView: View {
    let frames: [(image: PlatformImage, duration: TimeInterval)]

    @State private var currentFrame = 0
    @State private var timer: Timer?

    var body: some View {
        Image(platformImage: frames[currentFrame].image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .onAppear { startTimer() }
            .onDisappear { stopTimer() }
    }

    private func startTimer() {
        guard frames.count > 1 else { return }
        scheduleNext()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNext() {
        let duration = frames[currentFrame].duration
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            DispatchQueue.main.async {
                currentFrame = (currentFrame + 1) % frames.count
                scheduleNext()
            }
        }
    }
}

// MARK: - CachedCoverImage

/// Replaces AsyncImage in GameCard with GIF-capable cached loading.
/// Fallback chain: gifCover -> iconUrl -> emoji (matching Kotlin).
struct CachedCoverImage: View {
    let gifCover: String?
    let iconUrl: String
    let fallbackEmoji: String

    @State private var coverImage: CoverImageCache.CoverImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let coverImage = coverImage {
                if let img = coverImage.platformImage {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.04)
                } else if let frames = coverImage.gifFrames, !frames.isEmpty {
                    AnimatedGIFView(frames: frames)
                        .scaleEffect(1.04)
                } else {
                    emojiFallback
                }
            } else if loaded {
                emojiFallback
            } else {
                Color.clear
            }
        }
        .task { await loadImage() }
    }

    private var emojiFallback: some View {
        ZStack {
            Color.white.opacity(0.04)
            Text(fallbackEmoji)
                .font(.system(size: 48))
        }
    }

    private func loadImage() async {
        // Try gifCover first
        if let gif = gifCover, !gif.isEmpty {
            let result = await CoverImageCache.shared.load(url: gif)
            if case .failed = result {
                // Fall through to iconUrl
            } else {
                coverImage = result
                loaded = true
                return
            }
        }
        // Try iconUrl
        if !iconUrl.isEmpty {
            let result = await CoverImageCache.shared.load(url: iconUrl)
            coverImage = result
            loaded = true
            return
        }
        // Emoji fallback
        coverImage = .failed
        loaded = true
    }
}
