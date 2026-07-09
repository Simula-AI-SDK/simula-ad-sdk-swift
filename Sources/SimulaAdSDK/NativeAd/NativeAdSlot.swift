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
/// with no placeholder, and additionally surfaces via `onError` as a ``NativeAdError`` (including a
/// no-fill, so the publisher can show fallback content).
///
/// Targeting context is not a parameter here: it is read automatically from the `SimulaProvider`
/// this slot is hosted within (PRD). Must be used inside a `SimulaProviderView`.
public struct NativeAdSlot: View {
    // Non-observing provider injection (see EnvironmentValues.simulaProvider). Reading it via
    // @Environment — instead of @EnvironmentObject — means a @Published change on the provider
    // (e.g. sessionId after session create/refresh) does NOT re-render every NativeAdSlot in a feed.
    @Environment(\.simulaProvider) private var providerEnv: SimulaProvider?

    /// The provider for this slot, resolved without observing it. Falls back to the imperative
    /// `SimulaAds.shared`, then nil — a nil provider renders the slot empty rather than crashing the
    /// host (matching the provider-less robustness the Android SDK has).
    @MainActor private var resolvedProvider: SimulaProvider? { providerEnv ?? SimulaAds.shared }
    @Environment(\.colorScheme) private var colorScheme

    private let adUnitId: String?
    private let position: Int
    private let preloadedAdId: String?
    private let previewHTML: String?
    private let dimension: ParsedDimension
    private let theme: String?
    private let onImpression: (NativeAdData) -> Void
    private let onPaid: (AdValue) -> Void
    private let onError: (NativeAdError) -> Void
    private let onClick: () -> Void

    @State private var phase: Phase = .loading
    @State private var heightPt: CGFloat = 0
    @State private var impressionFired = false
    /// Parent width, measured only when `width` is a percentage (see `sizedSlot`).
    @State private var measuredParentWidth: CGFloat = 0
    /// Forwards the slot's live visible fraction into the creative (`window.onVisibility`); bound to
    /// the WKWebView by `WebViewRepresentable` and fed by the viewability modifier as the slot scrolls.
    @State private var visibilityRelay = VisibilityRelay()
    /// Native render time (fill→first-paint): monotonic start captured when a fresh (network/preload)
    /// creative begins loading; the elapsed-to-first-height is recorded once. A cache re-render restores
    /// height from cache without a real paint, so it leaves the start nil and records nothing.
    @State private var renderStartUptime: TimeInterval?
    @State private var renderTimeRecorded = false

    /// Height the slot holds while the creative is measuring, so it never collapses to a sliver
    /// between "filled" and "first height reported" (which would jolt the surrounding feed).
    static let provisionalHeight: CGFloat = 160

    /// Minimum rendered width. A narrower fixed/percentage `width` is raised to this (a sliver-wide
    /// ad card renders unusably).
    static let minWidthPt: CGFloat = 300

    /// - Parameters:
    ///   - adUnitId: Simula ad unit id (measurement + targeting). Optional.
    ///   - position: Index position of the slot in the feed (sent to the backend).
    ///   - width: Rendered width of the card. Client-side only — never sent to the backend. Accepts
    ///     flexible input: `nil` / `""` / `"auto"` fill the parent (the default); `"80%"` is 80% of
    ///     the parent; `"320px"` (case-insensitive) / `"300"` / `300` are a fixed point value; a
    ///     fraction `0 < n < 1` (e.g. `0.8`) is a percentage. Anything invalid (negative, zero,
    ///     out-of-range %, bool, array, garbage) falls back to fill. A fixed/percentage width below
    ///     `minWidthPt` (300pt) is raised to it. Mirrors the Android SDK's `width`.
    ///   - theme: Creative color theme — `"dark"`, `"light"`, `"system"`, or `nil`. `"system"` resolves
    ///     to dark/light from the view's `colorScheme`; `nil` is omitted (backend defaults to light).
    ///   - preloadedAdId: An id from `SimulaAds.preloadNativeAd`; renders that cached ad instead of a
    ///     live request. An expired/unknown id falls back to a live call with no error surfaced.
    ///   - onImpression: Fired once when the viewability threshold is met (co-fired with the server
    ///     impression).
    ///   - onPaid: The paid event — the estimated revenue (``AdValue``) for this impression, fired
    ///     together with `onImpression` (co-fired, not decoupled). Native has no "shown" event.
    ///   - onError: Fired with a ``NativeAdError`` on a load/render failure (not-initialized, no
    ///     session, network) and on a no-fill (`.noFill`). A cached outcome replayed on a recycled row
    ///     does not re-fire (one report per served slot).
    ///   - onClick: Fired when the user taps the creative's CTA and it navigates out — a
    ///     gesture-initiated click only (pixels and JS auto-redirects do not fire it). Mirrors the
    ///     interstitial's `interstitialDidClick`; co-fired with the `click` beacon.
    ///   - previewHTML: Debug/QA only — render this HTML through the full pipeline (WebView + height
    ///     sizing + viewability + AD-badge feedback bridge) with no network call. Mirrors the
    ///     imperative ads' `showPreview`.
    public init(
        adUnitId: String? = nil,
        position: Int = 0,
        width: Any? = nil,
        theme: String? = nil,
        preloadedAdId: String? = nil,
        onImpression: @escaping (NativeAdData) -> Void = { _ in },
        onPaid: @escaping (AdValue) -> Void = { _ in },
        onError: @escaping (NativeAdError) -> Void = { _ in },
        onClick: @escaping () -> Void = {},
        previewHTML: String? = nil
    ) {
        self.adUnitId = adUnitId
        self.position = position
        self.dimension = parseDimension(width).clampMinWidth(Self.minWidthPt)
        self.theme = theme
        self.preloadedAdId = preloadedAdId
        self.previewHTML = previewHTML
        self.onImpression = onImpression
        self.onPaid = onPaid
        self.onError = onError
        self.onClick = onClick

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
        sizedSlot
            .task(id: taskKey) { await load() }
            // Collapse a creative that loaded but never reported a height (see watchForMissingHeight).
            .task(id: awaitingHeight) { await watchForMissingHeight() }
    }

    /// The ad content for the current phase, before any width sizing.
    @ViewBuilder
    private var slotContent: some View {
        switch phase {
        case .filled(let response):
            let impressionId = response.impressionId ?? ""
            ZStack {
                WebViewRepresentable(
                    // Prefer the server-rendered html (the inline <iframe srcdoc> creative); fall back to
                    // the iframe url when no html is present.
                    url: response.renderedHTML == nil ? response.iframeURL.flatMap { URL(string: $0) } : nil,
                    htmlString: response.renderedHTML,
                    onNavigationFailed: { _ in handleLoadFailure() },
                    onMessageReceived: { handleMessage($0, impressionId: impressionId, adFormat: response.adFormat) },
                    onAdClick: {
                        // Surface the click to the publisher (parity with the interstitial's
                        // interstitialDidClick; CAI consumes this) BEFORE recording telemetry.
                        onClick()
                        // click lifecycle parity with interstitial/rewarded (was a reserved no-op).
                        Telemetry.shared.recordLifecycle(
                            stage: "click", adFormat: response.adFormat, adUnitId: adUnitId,
                            adId: impressionId.isEmpty ? nil : impressionId, serveId: nil, durationMs: nil, errorCode: nil
                        )
                    },
                    // SKAN/App-Analytics tokens (parity with interstitial/rewarded). When present, an
                    // App Store CTA routes through the in-app store sheet so the tokens ride it; absent
                    // tokens keep today's external open (see `openNativeCTA`).
                    attribution: response.skanAttribution,
                    externalClickOnly: true,
                    // Server-provided click-through routing — a CTA tap opens the tracking link (PRD).
                    ctaTrackingUrl: response.trackingUrl,
                    ctaDestination: response.destinationKind,
                    reportsContentHeight: true,
                    telemetryAdFormat: response.adFormat,
                    visibilityRelay: visibilityRelay
                )
                // Hold a provisional height while the creative measures (never collapse), then grow.
                .frame(height: heightPt > 0 ? heightPt : Self.provisionalHeight)
                // Snap height changes (grow on first paint, collapse on error) — never animate the
                // feed reflow, which reads as a weird "bump".
                .animation(nil, value: heightPt)
                .trackNativeAdViewability(
                    enabled: heightPt > 0,
                    // Forward the live visible fraction to the creative (window.onVisibility) every
                    // frame so a video/animation can react; per-frame, never sent to telemetry.
                    onVisibilityRatio: { visibilityRelay.report($0) }
                ) { stats in
                    fireImpression(impressionId: impressionId, adFormat: response.adFormat, adValue: response.adValue, stats: stats)
                }

                // Keep the shimmer over the slot until the creative reports its height. Without
                // this the slot would collapse between "filled" and "measured" and jolt the feed
                // below up then back down (it "looks broken").
                if heightPt <= 0 {
                    NativeAdShimmer(isDark: NativeAdTheme.resolve(theme, isDark: colorScheme == .dark) != "light")
                }

                // Tap-to-open AdChoices over the creative's top-left "AD" badge (Interested /
                // Not interested / Report / About) — the SDK's standard dialog, once the ad shows.
                if heightPt > 0 {
                    NativeAdInfoOverlay(adId: impressionId, apiKey: resolvedProvider?.apiKey ?? "")
                }
            }
            .clipped()
        case .loading:
            // While the request is in flight, show a shimmer placeholder.
            NativeAdShimmer(isDark: NativeAdTheme.resolve(theme, isDark: colorScheme == .dark) != "light")
        case .empty:
            // No-fill / error → hide the card (zero height, no placeholder).
            Color.clear.frame(height: 0)
        }
    }

    /// Applies the parsed `width` to `slotContent`.
    ///
    /// `.fill` is a true no-op — the slot renders exactly as it did before `width` existed (critical:
    /// any always-on wrapper here breaks the `WKWebView` rows inside a `LazyVStack`). `.pixels` pins a
    /// fixed width; a `LazyVStack`/`VStack` centers the narrower card automatically. `.percentage`
    /// measures the parent width once and pins a clamped fraction of it.
    @ViewBuilder
    private var sizedSlot: some View {
        switch dimension {
        case .fill:
            slotContent
        case .pixels(let pt):
            slotContent.frame(width: pt)
        case .percentage(let fraction):
            slotContent
                .frame(width: percentageWidth(fraction))
                .frame(maxWidth: .infinity, alignment: .center)
                // Measure the parent: the maxWidth:.infinity frame fills it, so its background
                // reports the parent's width (not the constrained card's) — no shrink loop.
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { measuredParentWidth = geo.size.width }
                            .onChange(of: geo.size.width) { newValue in measuredParentWidth = newValue }
                    }
                )
        }
    }

    /// `nil` until the parent is measured (slot fills until then), then `parentWidth * fraction`
    /// clamped to the minimum — the clamp lives here, at layout time, since SwiftUI's `.frame(minWidth:)`
    /// can't override a fixed `.frame(width:)`.
    private func percentageWidth(_ fraction: Float) -> CGFloat? {
        guard measuredParentWidth > 0 else { return nil }
        return max(measuredParentWidth * CGFloat(fraction), Self.minWidthPt)
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
                renderedHtml: previewHTML
            ))
            return
        }

        // 1. Honor a fresh preload first (a new id the publisher just preloaded).
        if let preloadedAdId, let preloaded = await NativeAdPreloadCache.shared.consume(preloadedAdId) {
            apply(preloaded, source: "preload")
            return
        }

        // 2. Per-slot cache hit → render without a network call (no duplicate serve / impression).
        if let entry = NativeAdCache.shared.get(adUnitId, position) {
            if let response = entry.response {
                heightPt = entry.heightPt
                impressionFired = entry.impressionFired
                phase = .filled(response)
                reportLoadSuccess(response, source: "cache")
            } else {
                phase = .empty
            }
            return
        }

        // 3. Live request.
        phase = .loading
        guard let provider = resolvedProvider else {
            // No SimulaProvider in the environment and no imperative SimulaAds.initialize() — render
            // empty instead of crashing the host (mirrors Android's provider-less fallback).
            phase = .empty
            return
        }
        let loadStartNanos = DispatchTime.now().uptimeNanoseconds
        do {
            let response = try await NativeAdController.load(
                provider: provider,
                adUnitId: adUnitId,
                position: position,
                theme: NativeAdTheme.resolve(theme, isDark: colorScheme == .dark)
            )
            let ms = Int((DispatchTime.now().uptimeNanoseconds &- loadStartNanos) / 1_000_000)
            apply(response, source: "network", durationMs: ms)
        } catch is CancellationError {
            // Slot recycled / view torn down mid-load — leave state as-is.
        } catch let error as SimulaAdError {
            phase = .empty // error → hide; not cached so it can retry next time
            reportError(NativeAdError(error))
        } catch {
            phase = .empty
            reportError(.network)
        }
    }

    /// Caches the outcome so the next remount of this slot reuses it (no duplicate serve).
    @MainActor
    private func apply(_ response: NativeAdResponse, source: String, durationMs: Int? = nil) {
        if response.hasCreative {
            NativeAdCache.shared.putFill(adUnitId, position, response)
            heightPt = 0
            impressionFired = false
            // Start the native fill→first-paint render timer for a genuine load (network/preload); a
            // cache re-render leaves it nil so it doesn't record a render time.
            if source != "cache" {
                renderStartUptime = ProcessInfo.processInfo.systemUptime
                renderTimeRecorded = false
            }
            phase = .filled(response)
            reportLoadSuccess(response, source: source, durationMs: durationMs)
        } else {
            // No-fill: collapse the slot AND surface noFill so the publisher can react (fallback).
            NativeAdCache.shared.putNoFill(adUnitId, position)
            phase = .empty
            reportError(.noFill)
        }
    }

    /// Surface a native failure to the publisher and record it for telemetry (errorCode parity with the
    /// imperative ads). Reused by the load, no-fill, and creative-render-failure paths.
    @MainActor
    private func reportError(_ error: NativeAdError) {
        Telemetry.shared.recordError(signature: "native:load", errorCode: error.telemetryCode, breadcrumb: "NativeAdSlot")
        // load_fail lifecycle parity with interstitial/rewarded (native previously emitted error only).
        Telemetry.shared.recordLifecycle(
            stage: "load_fail", adFormat: "character_ad", adUnitId: adUnitId, adId: nil,
            serveId: nil, durationMs: nil, errorCode: error.telemetryCode
        )
        onError(error)
    }

    /// load_success lifecycle parity, tagged with where the fill came from (preload | cache | network).
    @MainActor
    private func reportLoadSuccess(_ response: NativeAdResponse, source: String, durationMs: Int? = nil) {
        Telemetry.shared.recordLifecycle(
            stage: "load_success", adFormat: response.adFormat, adUnitId: adUnitId,
            adId: (response.impressionId?.isEmpty == false) ? response.impressionId : nil,
            serveId: nil, durationMs: durationMs, errorCode: nil, cacheSource: source
        )
    }

    private func fireImpression(impressionId: String, adFormat: String, adValue: AdValue, stats: ViewabilityStats) {
        guard !impressionFired else { return }
        impressionFired = true
        // Remember it on the cache entry so a remount of the same serve never re-fires.
        NativeAdCache.shared.get(adUnitId, position)?.impressionFired = true
        // Dedup by impression id too, so the same served ad fires at most one impression process-wide
        // (e.g. shown in two slots, or re-composed). The callback + server beacon co-fire together; a
        // preview (empty id) always fires the callback but never a beacon.
        guard impressionId.isEmpty || NativeAdCache.shared.markImpressionFired(impressionId) else { return }
        // displayed lifecycle parity — fires once per served impression (same dedup gate).
        Telemetry.shared.recordLifecycle(
            stage: "displayed", adFormat: adFormat, adUnitId: adUnitId,
            adId: impressionId.isEmpty ? nil : impressionId, serveId: nil, durationMs: nil, errorCode: nil
        )
        // Viewability exposure aggregate — once per impression. The per-frame ratio is far too
        // high-volume for the batch pipeline, so this records the MRC-shaped summary instead:
        // time-to-viewable + peak/avg/total exposure. Breadcrumb format matches the Kotlin SDK.
        Telemetry.shared.recordLifecycle(
            stage: "viewability", adFormat: adFormat, adUnitId: adUnitId,
            adId: impressionId.isEmpty ? nil : impressionId, serveId: nil,
            durationMs: stats.timeToViewableMs, errorCode: nil,
            breadcrumb: String(format: "peak=%.2f;avg=%.2f;visible_ms=%d", stats.peakExposure, stats.avgExposure, stats.totalVisibleMs)
        )
        onImpression(NativeAdData(impressionId: impressionId, adFormat: adFormat, adUnitId: adUnitId))
        // PAID — co-fired with the impression (PRD "co-fire, do not decouple"). The estimate is already
        // on-device from load; no network round-trip.
        onPaid(adValue)
        // Durable impression beacon (was a fire-and-forget trackImpression).
        AdBeaconManager.shared.enqueue(impressionId: impressionId, action: "seen", adFormat: adFormat, adUnitId: adUnitId)
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
        reportError(.network)
    }

    /// True while a filled creative has not yet reported a usable height — i.e. it is still holding
    /// the provisional block. Drives the missing-height watchdog and flips false the moment a real
    /// height arrives (`handleMessage`), the slot collapses, or it disappears.
    private var awaitingHeight: Bool {
        if case .filled = phase { return heightPt <= 0 }
        return false
    }

    /// A creative can finish loading (no navigation failure, no HTTP error) yet never post a usable
    /// `SIMULA_AD_HEIGHT` — a broken/empty creative. Without this it would hold the 160 pt provisional
    /// block forever (reserved empty space — the "bump"). Give a genuine load a generous window to
    /// paint; if it still hasn't, collapse the slot to zero height. SwiftUI cancels this automatically
    /// when `awaitingHeight` flips false (height arrived, or the slot left the screen), so it only ever
    /// fires for a creative that truly never measured.
    @MainActor
    private func watchForMissingHeight() async {
        guard awaitingHeight else { return }
        // Explicit do/catch (not `try?`): the sleep only throws on cancellation (height
        // arrived / slot left), and `try?`-wrapped awaits in task closures are one of the
        // shapes miscompiled by Swift 6.1–6.3 (see the task-shape note in TelemetryManager).
        do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
        guard !Task.isCancelled, awaitingHeight else { return }
        handleLoadFailure()
    }

    private func handleMessage(_ raw: String, impressionId: String, adFormat: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            // Malformed / non-object message from the creative bridge — dropped, but counted so a
            // broken or hostile creative is visible rather than silent (aggregated by signature).
            Telemetry.shared.recordError(signature: "native:bridge_parse_failed", breadcrumb: "NativeAdSlot.handleMessage")
            return
        }
        switch type {
        case "SIMULA_AD_HEIGHT", "AD_RESIZE":
            if let h = (obj["height"] as? NSNumber)?.doubleValue, h > 0 {
                let newHeight = CGFloat(h)
                // Native render time (the fill→first-paint blind spot): from load-begin to the
                // creative's first real height report (it has laid out and is on screen). Records once
                // per genuine load; a cache re-render left renderStartUptime nil.
                if !renderTimeRecorded, let start = renderStartUptime {
                    renderTimeRecorded = true
                    Telemetry.shared.recordLifecycle(
                        stage: "native_render", adFormat: adFormat, adUnitId: adUnitId,
                        adId: impressionId.isEmpty ? nil : impressionId, serveId: nil,
                        durationMs: Int((ProcessInfo.processInfo.systemUptime - start) * 1000), errorCode: nil
                    )
                }
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
            let apiKey = resolvedProvider?.apiKey ?? ""
            Task { await SimulaAPI.shared.recordInterest(adId: impressionId, interest: 1, apiKey: apiKey) }
        case "not_interested":
            let apiKey = resolvedProvider?.apiKey ?? ""
            Task { await SimulaAPI.shared.recordInterest(adId: impressionId, interest: -1, apiKey: apiKey) }
        case "report":
            let apiKey = resolvedProvider?.apiKey ?? ""
            Task { await SimulaAPI.shared.reportAd(adId: impressionId, flag: value, apiKey: apiKey) }
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
///
/// `isDark` matches the shimmer to the creative that's about to render. Defaults to dark; the skeleton
/// is light only for an explicitly light (or system-light) creative, so an unspecified theme shows a
/// dark block rather than a light one that then flips.
private struct NativeAdShimmer: View {
    var isDark: Bool = true
    @State private var animate = false

    private var base: Color {
        isDark ? Color(red: 0.14, green: 0.14, blue: 0.17) : Color(red: 0.89, green: 0.89, blue: 0.91)
    }

    /// White sweep band — needs more opacity to read against the light base.
    private var highlight: Color {
        isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.55)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(base)
            .frame(height: NativeAdSlot.provisionalHeight)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, highlight, .clear],
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
