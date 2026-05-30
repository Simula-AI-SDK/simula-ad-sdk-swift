import SwiftUI

// MARK: - BundledImageCache

/// Loads images that are bundled as loose resource files (copied via SPM `.copy`)
/// exactly once and caches the decoded result.
///
/// The previous call sites decoded these PNGs synchronously inside SwiftUI `body`
/// (`Bundle.module.url(...)` + `Data(contentsOf:)` + `UIImage(data:)`), which
/// re-ran the disk read and decode on every view recomputation — on the main
/// thread. Resolving through this cache turns that into a one-time cost.
enum BundledImageCache {
    private static let lock = NSLock()
    private static var cache: [String: PlatformImage] = [:]

    /// Returns the decoded bundled image for `name`.`ext`, loading and caching it
    /// on first access. Returns `nil` if the resource is missing or undecodable
    /// (callers fall back to a placeholder).
    static func image(named name: String, withExtension ext: String = "png") -> PlatformImage? {
        let key = "\(name).\(ext)"

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        #if os(iOS)
        let image = UIImage(data: data)
        #elseif os(macOS)
        let image = NSImage(data: data)
        #else
        let image: PlatformImage? = nil
        #endif
        guard let image else { return nil }

        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }
}
