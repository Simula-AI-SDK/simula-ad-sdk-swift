import SwiftUI
import ImageIO

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
func makePlatformImage(cgImage: CGImage) -> PlatformImage {
    UIImage(cgImage: cgImage)
}
extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
func makePlatformImage(cgImage: CGImage) -> PlatformImage {
    NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}
extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif

// MARK: - CoverImageCache

/// In-memory image cache with GIF support using ImageIO (no external dependencies).
/// Downloads and decodes images, caching results for reuse across carousel scrolls.
///
/// Decoded bitmaps are downsampled to roughly the on-screen card size and stored
/// in an `NSCache` with a cost limit, so a long, high-resolution GIF can't pin
/// hundreds of MB and the cache evicts under memory pressure. (The previous
/// implementation decoded every frame at full resolution into an unbounded
/// dictionary that was never evicted.)
final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()

    enum CoverImage {
        case staticImage(PlatformImage)
        case animatedGIF(frames: [(image: PlatformImage, duration: TimeInterval)])
        case failed
    }

    /// Cover cards are small on screen; cap the long edge so decoded bitmaps stay
    /// modest regardless of the source resolution.
    private static let maxPixelSize: CGFloat = 800
    /// Sample frames of very long GIFs so frame count can't blow up memory/CPU.
    private static let maxFrames = 60
    /// ~96 MB ceiling for all decoded covers combined; NSCache evicts past this.
    private static let totalCostLimit = 96 * 1024 * 1024

    /// Boxes the enum so it can live in NSCache (which requires class values).
    private final class Entry {
        let image: CoverImage
        init(_ image: CoverImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.totalCostLimit = CoverImageCache.totalCostLimit
        return c
    }()

    /// Tracks in-flight downloads so concurrent loads of the same URL (e.g. the
    /// catalog preload and a visible card requesting the same cover) share one
    /// network request + decode instead of duplicating them.
    private final class InFlight {
        // Optional, not an IUO: it's assigned right after the box is created (both under `lock`,
        // before `inFlight[url]` is published), so readers never observe nil — but a safe unwrap
        // means a future refactor can't turn this into a trap.
        var task: Task<CoverImage, Never>?
        var waiters: Int
        init(waiters: Int) { self.waiters = waiters }
    }
    private let lock = NSLock()
    private var inFlight: [String: InFlight] = [:]

    private init() {
        // Drop all decoded covers under system memory pressure. NSCache evicts on
        // its own, but this is a prompt, explicit belt-and-suspenders alongside
        // the cost limit — relevant with multi-frame GIFs held in memory.
        // (Block-based observer because this isn't an NSObject; the cache is a
        // lifelong singleton, so no removeObserver is needed.)
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clearCache()
        }
        #endif
    }

    /// Preload multiple URLs in parallel. Completes when all are cached.
    func preload(urls: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                guard cache.object(forKey: url as NSString) == nil else { continue }
                group.addTask { [weak self] in
                    _ = await self?.load(url: url)
                }
            }
        }
    }

    /// Load a single URL, returning the cached result if available. Concurrent
    /// loads of the same URL are coalesced onto a single shared download.
    func load(url: String) async -> CoverImage {
        if let cached = cache.object(forKey: url as NSString) {
            return cached.image
        }

        let task = registerWaiter(for: url)
        // Each caller can cancel independently; the shared download is only
        // cancelled once its last waiter goes away — this preserves the
        // menu-close cancellation behavior while still de-duplicating requests.
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            self.releaseWaiter(for: url)
        }
    }

    /// Returns the shared download task for `url`, creating it (and registering
    /// this caller as a waiter) if none is already in flight.
    private func registerWaiter(for url: String) -> Task<CoverImage, Never> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = inFlight[url], let task = existing.task {
            existing.waiters += 1
            return task
        }

        let box = InFlight(waiters: 1)
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        let task = Task<CoverImage, Never> { [weak self] in
            await self?.loadAndClear(url: url, box: box) ?? .failed
        }
        box.task = task
        inFlight[url] = box
        return task
    }

    /// Shared-download task body (named method — see the task-shape note in TelemetryManager):
    /// download + decode, then retire the in-flight entry.
    private func loadAndClear(url: String, box: InFlight) async -> CoverImage {
        let result = await performLoad(url: url)
        clearInFlight(url, ifMatches: box)
        return result
    }

    /// Clears the in-flight entry for `url` once its download finishes, but only
    /// if it's still `box` — a cancelled-and-replaced entry may already point at
    /// a newer task. Synchronous so it never holds the lock across a suspension
    /// (and avoids `NSLock`'s `noasync` lock/unlock in the async task body).
    private func clearInFlight(_ url: String, ifMatches box: InFlight) {
        lock.lock()
        if inFlight[url] === box { inFlight[url] = nil }
        lock.unlock()
    }

    /// A waiter went away (cancelled). Cancel the shared download once no
    /// waiters remain.
    private func releaseWaiter(for url: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let box = inFlight[url] else { return }
        box.waiters -= 1
        if box.waiters <= 0 {
            inFlight[url] = nil
            box.task?.cancel()
        }
    }

    /// Performs the actual download + decode for `url` and caches the result.
    private func performLoad(url: String) async -> CoverImage {
        guard let requestUrl = URL(string: url) else {
            store(.failed, cost: 1, for: url)
            return .failed
        }

        do {
            // Carry the SDK's standard headers (UA + device id) on this CDN fetch too.
            var request = URLRequest(url: requestUrl)
            for (key, value) in SimulaUserAgent.standardHeaders() {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            let (result, cost) = decodeImage(data: data)
            store(result, cost: cost, for: url)
            return result
        } catch {
            // If the shared download was cancelled (its last waiter went away,
            // e.g. the menu closed mid-load), don't poison the cache with a
            // failure — leave the URL uncached so it retries when next requested.
            if Task.isCancelled { return .failed }
            store(.failed, cost: 1, for: url)
            return .failed
        }
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    private func store(_ image: CoverImage, cost: Int, for url: String) {
        cache.setObject(Entry(image), forKey: url as NSString, cost: max(cost, 1))
    }

    // MARK: - Decoding

    /// Downsampling options shared by static and GIF frame decodes. Decodes the
    /// bitmap immediately (off the main thread, here) instead of lazily on first
    /// draw, and caps the long edge at `maxPixelSize`.
    private static let thumbnailOptions: CFDictionary = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ] as CFDictionary

    private func downsample(source: CGImageSource, index: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index, CoverImageCache.thumbnailOptions)
    }

    /// Returns the decoded cover plus its approximate byte cost for NSCache.
    private func decodeImage(data: Data) -> (CoverImage, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return (.failed, 1)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return (.failed, 1) }

        // Treat multi-frame GIFs as animated; everything else as a static image.
        let isGIF = data.count >= 6 && data.prefix(3) == Data([0x47, 0x49, 0x46])
        if isGIF && count > 1 {
            return decodeGIF(source: source, count: count)
        }

        guard let cgImage = downsample(source: source, index: 0) else { return (.failed, 1) }
        return (.staticImage(makePlatformImage(cgImage: cgImage)), bytes(cgImage))
    }

    private func decodeGIF(source: CGImageSource, count: Int) -> (CoverImage, Int) {
        // Sample every `step`-th frame so a GIF with hundreds of frames is bounded.
        let step = max(1, Int(ceil(Double(count) / Double(CoverImageCache.maxFrames))))

        var frames: [(PlatformImage, TimeInterval)] = []
        frames.reserveCapacity(min(count, CoverImageCache.maxFrames))
        var cost = 0
        var i = 0
        while i < count {
            if let cgImage = downsample(source: source, index: i) {
                // Fold the durations of any skipped frames into this one so the
                // overall animation length is preserved.
                var duration: TimeInterval = 0
                for j in i..<min(i + step, count) {
                    duration += gifFrameDuration(source: source, index: j)
                }
                frames.append((makePlatformImage(cgImage: cgImage), duration))
                cost += bytes(cgImage)
            }
            i += step
        }
        return frames.isEmpty ? (.failed, 1) : (.animatedGIF(frames: frames), cost)
    }

    private func bytes(_ image: CGImage) -> Int {
        image.bytesPerRow * image.height
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

/// Plays decoded GIF frames off a single `TimelineView(.animation)` clock rather
/// than a per-view `Timer`. The previous Timer approach rescheduled itself and
/// hopped to the main queue every frame, for every visible card simultaneously.
/// TimelineView is driven by the system's display refresh and pauses on its own
/// when the view isn't visible. When `isAnimating` is false the view shows a
/// single static frame and runs no clock at all.
private struct AnimatedGIFView: View {
    let frames: [(image: PlatformImage, duration: TimeInterval)]
    var isAnimating: Bool = true

    /// Cumulative start time of each frame, and the total loop duration.
    private let frameStarts: [TimeInterval]
    private let totalDuration: TimeInterval

    init(frames: [(image: PlatformImage, duration: TimeInterval)], isAnimating: Bool = true) {
        self.frames = frames
        self.isAnimating = isAnimating
        var starts: [TimeInterval] = []
        starts.reserveCapacity(frames.count)
        var t: TimeInterval = 0
        for frame in frames {
            starts.append(t)
            t += max(frame.duration, 0.02)
        }
        self.frameStarts = starts
        self.totalDuration = max(t, 0.02)
    }

    var body: some View {
        if isAnimating && frames.count > 1 {
            TimelineView(.animation) { context in
                image(for: frameIndex(at: context.date.timeIntervalSinceReferenceDate))
            }
        } else {
            image(for: 0)
        }
    }

    /// The frame whose interval contains the current loop phase.
    private func frameIndex(at time: TimeInterval) -> Int {
        let phase = time.truncatingRemainder(dividingBy: totalDuration)
        var index = 0
        for (i, start) in frameStarts.enumerated() {
            if phase >= start { index = i } else { break }
        }
        return index
    }

    @ViewBuilder
    private func image(for index: Int) -> some View {
        if frames.indices.contains(index) {
            Image(platformImage: frames[index].image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Color.clear
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
    /// When false, an animated cover renders a single static frame (used to keep
    /// only the centered carousel card animating).
    var isAnimating: Bool = true

    @State private var coverImage: CoverImageCache.CoverImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let coverImage = coverImage {
                switch coverImage {
                case .staticImage(let img):
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(1.04)
                        .clipped()
                case .animatedGIF(let frames):
                    AnimatedGIFView(frames: frames, isAnimating: isAnimating)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(1.04)
                        .clipped()
                case .failed:
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

    /// `@MainActor` so the `@State` writes after each `await` resume on the main
    /// thread (the cache resumes on a background executor otherwise).
    @MainActor
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
