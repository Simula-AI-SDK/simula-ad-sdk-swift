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
    }

    public var body: some View {
        Group {
            switch phase {
            case .filled(let response):
                let impressionId = response.impressionId ?? ""
                WebViewRepresentable(
                    url: response.iframeURL.flatMap { URL(string: $0) },
                    htmlString: response.iframeURL == nil ? response.renderedHTML : nil,
                    onMessageReceived: { handleMessage($0, impressionId: impressionId) },
                    onAdClick: { /* CLICKED — reserved for a future click callback / telemetry hook. */ },
                    externalClickOnly: true,
                    reportsContentHeight: true
                )
                // 1pt until the creative reports its height, then grow to fit. Transparent, no skeleton.
                .frame(height: heightPt > 0 ? heightPt : 1)
                .clipped()
                .trackNativeAdViewability(enabled: heightPt > 0) {
                    fireImpression(impressionId: impressionId, adFormat: response.adFormat)
                }
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
        phase = .loading
        heightPt = 0
        impressionFired = false

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

        do {
            let response: NativeAdResponse
            if let preloadedAdId, let cached = await NativeAdPreloadCache.shared.consume(preloadedAdId) {
                response = cached // render from cache; expired/unknown falls through to a live request
            } else {
                response = try await NativeAdController.load(provider: provider, adUnitId: adUnitId, position: position)
            }
            phase = response.hasCreative ? .filled(response) : .empty // no-fill collapses silently (no onError)
        } catch is CancellationError {
            // Slot recycled / view torn down mid-load — leave state as-is.
        } catch let error as SimulaAdError {
            phase = .empty
            onError(error)
        } catch {
            phase = .empty
            onError(.network(.invalidResponse))
        }
    }

    private func fireImpression(impressionId: String, adFormat: String) {
        guard !impressionFired else { return }
        impressionFired = true
        // Co-fire the callback and the server impression off the one viewability event (PRD).
        onImpression(NativeAdData(impressionId: impressionId, adFormat: adFormat, adUnitId: adUnitId))
        let apiKey = provider.apiKey
        Task { await SimulaAPI().trackImpression(adId: impressionId, apiKey: apiKey) }
    }

    private func handleMessage(_ raw: String, impressionId: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "SIMULA_AD_HEIGHT", "AD_RESIZE":
            if let h = (obj["height"] as? NSNumber)?.doubleValue, h > 0 {
                heightPt = CGFloat(h)
            }
        case "AD_FEEDBACK":
            if let value = obj["value"] as? String { handleFeedback(value, impressionId: impressionId) }
        default:
            break
        }
    }

    /// The AD badge menu's feedback (PRD design reference): interested/not_interested/report POST to
    /// `reportAd`; "about" opens https://simula.ad in the external browser.
    private func handleFeedback(_ value: String, impressionId: String) {
        switch value {
        case "about":
            if let url = URL(string: "https://simula.ad") { UIApplication.shared.open(url) }
        case "interested", "not_interested", "report":
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
            .frame(height: 160)
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
