import SwiftUI

// MARK: - CachedAsyncImage

/// A drop-in replacement for `AsyncImage(url:content:)` that loads through the
/// in-memory `CoverImageCache` (deduped + downsampled), so the same character
/// image isn't re-downloaded every time its component re-appears (every menu
/// open, interstitial, or invitation). The content closure receives the same
/// `AsyncImagePhase` values as `AsyncImage`, so existing call sites switch over
/// unchanged.
///
/// Animated (GIF) sources surface their first frame — matching `AsyncImage`,
/// which doesn't animate — which is the right behavior for static avatars.
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    /// `@MainActor` so the `@State` write after the `await` lands on the main
    /// thread (the cache resumes on a background executor otherwise).
    @MainActor
    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        // Reset while (re)loading so a changed URL doesn't show the stale image,
        // mirroring AsyncImage.
        phase = .empty

        let result = await CoverImageCache.shared.load(url: url.absoluteString)
        switch result {
        case .staticImage(let image):
            phase = .success(Image(platformImage: image))
        case .animatedGIF(let frames):
            if let first = frames.first?.image {
                phase = .success(Image(platformImage: first))
            } else {
                phase = .failure(CachedAsyncImageError.decodeFailed)
            }
        case .failed:
            phase = .failure(CachedAsyncImageError.decodeFailed)
        }
    }
}

private enum CachedAsyncImageError: Error {
    case decodeFailed
}
