#if os(iOS)
import SwiftUI
import UIKit

/// An inline, contextually-targeted native ad — a sponsored character card rendered inside a
/// publisher's feed (PRD).
///
/// Loads `POST /load/native` on appearance (or renders a `preloadedAdId` from cache with no network
/// call), mounts the creative in a content-sized `WKWebView`, and reports an impression only when
/// ≥50% of the creative is visible for ≥1 continuous second (the OMID-shaped
/// `trackNativeAdViewability` seam). A no-fill or any error collapses the slot to **zero height**
/// with no placeholder; an error additionally surfaces via `onError` (a no-fill does not — PRD).
///
/// Targeting context is not a parameter here: it is read automatically from the `SimulaProvider`
/// this slot is hosted within (PRD). Must be used inside a `SimulaProviderView`.
public struct NativeAdSlot: View {
    @EnvironmentObject private var provider: SimulaProvider

    private let adUnitId: String?
    private let position: Int
    private let preloadedAdId: String?
    private let previewHTML: String?
    private let onImpression: (NativeAdData) -> Void
    private let onError: (SimulaAdError) -> Void

    @State private var phase: Phase = .loading
    @State private var heightPt: CGFloat = 0
    @State private var impressionFired = false

    /// Height the slot holds while the creative is measuring, so it never collapses to a sliver
    /// between "filled" and "first height reported" (which would jolt the surrounding feed).
    static let provisionalHeight: CGFloat = 160

    /// - Parameters:
    ///   - adUnitId: Simula ad unit id (measurement + targeting). Optional.
    ///   - position: Index position of the slot in the feed (sent to the backend).
    ///   - preloadedAdId: An id from `SimulaAds.preloadNativeAd`; renders that cached ad instead of a
    ///     live request. An expired/unknown id falls back to a live call with no error surfaced.
    ///   - onImpression: Fired once when the viewability threshold is met (co-fired with the server
    ///     impression).
    ///   - onError: Fired on a load/render failure (network, bad session). Not fired on a no-fill.
    ///   - previewHTML: Debug/QA only — render this HTML through the full pipeline (WebView + height
    ///     sizing + viewability + AD-badge feedback bridge) with no network call. Mirrors the
    ///     imperative ads' `showPreview`.
    public init(
        adUnitId: String? = nil,
        position: Int = 0,
        preloadedAdId: String? = nil,
        onImpression: @escaping (NativeAdData) -> Void = { _ in },
        onError: @escaping (SimulaAdError) -> Void = { _ in },
        previewHTML: String? = nil
    ) {
        self.adUnitId = adUnitId
        self.position = position
        self.preloadedAdId = preloadedAdId
        self.previewHTML = previewHTML
        self.onImpression = onImpression
        self.onError = onError

        // Seed the initial state from the per-slot cache so a recycled row paints the SAME ad on its
        // first frame (no shimmer flash, no refetch). A preview / preload resolves in `.task`.
        if previewHTML == nil, preloadedAdId == nil, let entry = NativeAdCache.shared.get(adUnitId, position) {
            if let response = entry.response {
                _phase = State(initialValue: .filled(response))
                _heightPt = State(initialValue: entry.heightPt)
                _impressionFired = State(initialValue: entry.impressionFired)
            } else {
                _phase = State(initialValue: .empty)
            }
        }
    }

    public var body: some View {
        Group {
            switch phase {
            case .filled(let response):
                let impressionId = response.impressionId ?? ""
                ZStack {
                    WebViewRepresentable(
                        url: response.iframeURL.flatMap { URL(string: $0) },
                        htmlString: response.iframeURL == nil ? response.renderedHTML : nil,
                        onNavigationFailed: { _ in handleLoadFailure() },
                        onMessageReceived: { handleMessage($0, impressionId: impressionId) },
                        onAdClick: { /* CLICKED — reserved for a future click callback / telemetry hook. */ },
                        externalClickOnly: true,
                        reportsContentHeight: true
                    )
                    // Hold a provisional height while the creative measures (never collapse), then grow.
                    .frame(height: heightPt > 0 ? heightPt : Self.provisionalHeight)
                    .trackNativeAdViewability(enabled: heightPt > 0) {
                        fireImpression(impressionId: impressionId, adFormat: response.adFormat)
                    }

                    // Keep the shimmer over the slot until the creative reports its height. Without
                    // this the slot would collapse between "filled" and "measured" and jolt the feed
                    // below up then back down (it "looks broken").
                    if heightPt <= 0 {
                        NativeAdShimmer()
                    }

                    // Tap-to-open AdChoices over the creative's top-left "AD" badge (Interested /
                    // Not interested / Report / About) — the SDK's standard dialog, once the ad shows.
                    if heightPt > 0 {
                        NativeAdInfoOverlay(adId: impressionId, apiKey: provider.apiKey)
                    }
                }
                .clipped()
            case .loading:
                // While the request is in flight, show a shimmer placeholder.
                NativeAdShimmer()
            case .empty:
                // No-fill / error → hide the card (zero height, no placeholder).
                Color.clear.frame(height: 0)
            }
        }
        .task(id: taskKey) { await load() }
    }

    private var taskKey: String { "\(adUnitId ?? "")|\(position)|\(preloadedAdId ?? "")|\(previewHTML != nil)" }

    @MainActor
    private func load() async {
        // Preview/QA: render the supplied HTML with no network (mirrors imperative showPreview).
        if let previewHTML {
            phase = .filled(NativeAdResponse(
                impressionId: nil,
                adInserted: true,
                adFormat: "character_ad",
                adResponse: NativeAdCreative(renderedHtml: previewHTML)
            ))
            return
        }

        // 1. Honor a fresh preload first (a new id the publisher just preloaded).
        if let preloadedAdId, let preloaded = await NativeAdPreloadCache.shared.consume(preloadedAdId) {
            apply(preloaded)
            return
        }

        // 2. Per-slot cache hit → render without a network call (no duplicate serve / impression).
        if let entry = NativeAdCache.shared.get(adUnitId, position) {
            if let response = entry.response {
                heightPt = entry.heightPt
                impressionFired = entry.impressionFired
                phase = .filled(response)
            } else {
                phase = .empty
            }
            return
        }

        // 3. Live request.
        phase = .loading
        do {
            apply(try await NativeAdController.load(provider: provider, adUnitId: adUnitId, position: position))
        } catch is CancellationError {
            // Slot recycled / view torn down mid-load — leave state as-is.
        } catch let error as SimulaAdError {
            phase = .empty // error → hide; not cached so it can retry next time
            onError(error)
        } catch {
            phase = .empty
            onError(.network(.invalidResponse))
        }
    }

    /// Caches the outcome so the next remount of this slot reuses it (no duplicate serve).
    @MainActor
    private func apply(_ response: NativeAdResponse) {
        if response.hasCreative {
            NativeAdCache.shared.putFill(adUnitId, position, response)
            heightPt = 0
            impressionFired = false
            phase = .filled(response)
        } else {
            // No-fill collapses silently (no onError). PRD.
            NativeAdCache.shared.putNoFill(adUnitId, position)
            phase = .empty
        }
    }

    private func fireImpression(impressionId: String, adFormat: String) {
        guard !impressionFired else { return }
        impressionFired = true
        // Remember it on the cache entry so a remount of the same serve never re-fires.
        NativeAdCache.shared.get(adUnitId, position)?.impressionFired = true
        // Co-fire the callback and the server impression off the one viewability event (PRD).
        onImpression(NativeAdData(impressionId: impressionId, adFormat: adFormat, adUnitId: adUnitId))
        let apiKey = provider.apiKey
        Task { await SimulaAPI().trackImpression(adId: impressionId, apiKey: apiKey) }
    }

    /// The creative's web view failed to load (e.g. no connectivity when this row scrolled into
    /// view — including a recycled row whose height was restored from cache, so we must NOT gate on
    /// height here). Collapse the slot instead of leaving a blank/failed creative on screen; surface
    /// as a load error. The fill stays cached (not invalidated), so a remount retries once
    /// connectivity returns.
    @MainActor
    private func handleLoadFailure() {
        guard case .filled = phase else { return }
        heightPt = 0
        phase = .empty
        onError(.network(.invalidResponse))
    }

    private func handleMessage(_ raw: String, impressionId: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "SIMULA_AD_HEIGHT", "AD_RESIZE":
            if let h = (obj["height"] as? NSNumber)?.doubleValue, h > 0 {
                let newHeight = CGFloat(h)
                // Threshold sub-point churn so a measuring creative can't thrash the feed below.
                if abs(newHeight - heightPt) >= 1 {
                    heightPt = newHeight
                    // Persist so a recycled row sizes correctly on its first frame.
                    NativeAdCache.shared.get(adUnitId, position)?.heightPt = newHeight
                }
            }
        case "AD_FEEDBACK":
            if let value = obj["value"] as? String { handleFeedback(value, impressionId: impressionId) }
        default:
            break
        }
    }

    /// The AD badge menu's feedback (PRD design reference): interested/not_interested record an
    /// interest signal (+1 / -1); "report" posts to `reportAd`; "about" opens https://simula.ad in
    /// the external browser.
    private func handleFeedback(_ value: String, impressionId: String) {
        switch value {
        case "about":
            if let url = URL(string: "https://www.simula.ad/privacy-policy") { UIApplication.shared.open(url) }
        case "interested":
            let apiKey = provider.apiKey
            Task { await SimulaAPI().recordInterest(adId: impressionId, interest: 1, apiKey: apiKey) }
        case "not_interested":
            let apiKey = provider.apiKey
            Task { await SimulaAPI().recordInterest(adId: impressionId, interest: -1, apiKey: apiKey) }
        case "report":
            let apiKey = provider.apiKey
            Task { await SimulaAPI().reportAd(adId: impressionId, flag: value, apiKey: apiKey) }
        default:
            break
        }
    }

    private enum Phase {
        case loading
        case empty
        case filled(NativeAdResponse)
    }
}

/// Animated shimmer shown while a native ad request is in flight. Replaced by the creative on a
/// fill, or collapsed to nothing on a no-fill / error.
private struct NativeAdShimmer: View {
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(red: 0.14, green: 0.14, blue: 0.17))
            .frame(height: NativeAdSlot.provisionalHeight)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width)
                    .offset(x: animate ? geo.size.width : -geo.size.width)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}
#endif
