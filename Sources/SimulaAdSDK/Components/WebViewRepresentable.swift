struct WebNavigationTracker<Token: Hashable> {
    private(set) var active: Token?
    private(set) var requested: Token?
    private var rejected: [Token] = []

    mutating func resetForRebind() {
        reject(active)
        reject(requested)
        active = nil
        requested = nil
    }

    mutating func trackRequested(_ token: Token?) {
        if active != token { reject(active) }
        if requested != token { reject(requested) }
        if let token { rejected.removeAll { $0 == token } }
        active = token
        requested = token
    }

    mutating func didStart(_ token: Token?) -> Bool {
        guard let token, !rejected.contains(token) else { return false }
        if let requested, requested != token { return false }
        requested = nil
        active = token
        return true
    }

    func isActive(_ token: Token?) -> Bool {
        guard let token else { return false }
        return active == token && !rejected.contains(token)
    }

    mutating func didFinish(_ token: Token?) -> Bool {
        guard isActive(token) else { return false }
        active = nil
        requested = nil
        return true
    }

    mutating func didFail(_ token: Token?) -> Bool {
        guard let token, !rejected.contains(token), token == active || token == requested else {
            return false
        }
        if active == token { active = nil }
        if requested == token { requested = nil }
        return true
    }

    private mutating func reject(_ token: Token?) {
        guard let token, !rejected.contains(token) else { return }
        rejected.append(token)
        if rejected.count > 8 { rejected.removeFirst() }
    }
}

#if os(iOS)
import SwiftUI
import WebKit
import StoreKit
import SafariServices

internal func identicalNonNilObjects<T: AnyObject>(_ lhs: T?, _ rhs: T?) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs === rhs
}

internal func stopBeforeRecycling(stop: () -> Void, recycle: () -> Void) {
    stop()
    recycle()
}

// MARK: - WebViewRepresentable

/// A UIViewRepresentable wrapper around WKWebView for loading game iframes and ad content.
/// Translates the React `<iframe>` elements used in GameIframe.tsx and MiniGameMenu.tsx.
///
/// Supports:
/// - Loading a URL (for game iframes and ad iframes)
/// - Loading raw HTML string (for native ad content)
/// - Navigation delegate callbacks (load finished, load failed)
/// - JavaScript message handler for postMessage communication from game iframes
struct WebViewRepresentable: UIViewRepresentable {
    /// The URL to load. Mutually exclusive with `htmlString`.
    let url: URL?

    /// Raw HTML content to load. Mutually exclusive with `url`.
    let htmlString: String?

    /// Base URL for `htmlString` loads — sets the page origin so the creative's own same-origin
    /// requests (e.g. the end screen's click beacon) behave as if served from that origin. `nil` for
    /// the interstitial / native html (no in-creative same-origin calls).
    var baseURL: URL?

    /// Called when the current main document commits, before subresources finish loading.
    var onNavigationCommitted: (() -> Void)?

    /// Called when the web view finishes loading content.
    var onNavigationFinished: (() -> Void)?

    /// Called when the web view fails to load content
    var onNavigationFailed: ((Error) -> Void)?

    /// Called when the web view receives a postMessage from JavaScript
    var onMessageReceived: ((String) -> Void)?

    /// Called when a user-initiated link inside the content is intercepted for
    /// routing (App Store / cross-domain click-through). Lets the imperative HTML
    /// creative emit CLICKED. `nil` for the declarative game iframe (no behavior change).
    var onAdClick: ((ClickInteraction) -> Void)?
    /// Reports the short persistence/start handoff so fullscreen controls cannot dismantle this
    /// WebView before a claimed click is durable and any asynchronous route safely starts.
    var onClickHandoffPendingChanged: ((Bool) -> Void)?
    var onAttributionRouteOutcome: ((AttributionRouteOutcome) -> Void)?
    var attributionRouteLifecycle: AttributionRouteLifecycle?
    var clickSource: ClickSource
    /// Non-nil only when the SDK owns this surface's backend click beacon. Native-ad HTML leaves
    /// this nil; capability-negotiated fullscreen/fallback surfaces supply their impression id.
    var clickBeaconImpressionId: String?

    /// The WebView ↔ SDK bridge (PRD §3). When set, `window.postMessage` envelopes from the
    /// creative are routed to it (and `GET_*` replies are posted back via the web view). `nil`
    /// for the game iframe / previews, which keep the plain `onMessageReceived` path.
    var bridge: CreativeBridge?

    /// Ad-network attribution tokens carried into the in-app store sheet for click-through / auto-redirect
    /// CTAs (so the SKAN install postback credits the campaign). Set for the imperative HTML creative;
    /// `nil` for the game iframe / previews (no attribution to apply).
    var attribution: AdAttribution?

    /// Native-ad mode: admits approved custom-scheme destinations in addition to HTTP(S)/App Store
    /// URLs. The actual store surface is selected independently by `ctaStoreOpen`.
    var externalClickOnly: Bool

    /// The server's MMP click-tracking URL a CTA tap should open, preferred over the URL embedded in
    /// rendered HTML. A `nil`, blank, or malformed tracker falls back to the in-creative URL.
    var ctaTrackingUrl: String?
    var ctaDestination: AdDestination
    var ctaStoreOpen: StoreOpen

    /// The serve's raw App Store link (`ios_store_url`), when known. Drives the deterministic CTA
    /// route for in-creative click-throughs: the in-app store sheet opens from this link's app id
    /// while the tapped tracker URL fires in the background (`CreativeCTARouter.routeCreativeTap`).
    /// `nil` (older payloads / previews / the declarative menu) keeps today's redirect-chain
    /// resolution unchanged.
    var ctaStoreUrl: String?

    /// Native-ad mode: after load, inject a script that reports the creative's content height over
    /// the JS bridge (`{type:"SIMULA_AD_HEIGHT", height}`) so the slot can size its container.
    var reportsContentHeight: Bool

    /// Native-ad mode: the serve's impression id, keying this creative's rendered `WKWebView` in
    /// `NativeAdWebViewStore` so a recycled feed row reattaches the same, already-rendered view
    /// (no reload — no blank-then-pop flash). `nil` (previews / non-native surfaces) keeps the
    /// ephemeral `WebViewPool` path.
    var retainedImpressionId: String?

    /// Optional ad-format tag for WebView telemetry (page-load timing, render crash, JS errors).
    /// `nil` → untagged.
    var telemetryAdFormat: String?

    /// Native-ad mode: forwards the slot's live visible fraction into this creative via
    /// `window.onVisibility(ratio)` as it scrolls. Bound to this instance's WKWebView on acquire and
    /// unbound on teardown. `nil` for the game iframe / interstitial creative (no per-frame visibility).
    var visibilityRelay: VisibilityRelay?

    init(
        url: URL? = nil,
        htmlString: String? = nil,
        baseURL: URL? = nil,
        onNavigationCommitted: (() -> Void)? = nil,
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: ((Error) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil,
        onAdClick: ((ClickInteraction) -> Void)? = nil,
        onClickHandoffPendingChanged: ((Bool) -> Void)? = nil,
        onAttributionRouteOutcome: ((AttributionRouteOutcome) -> Void)? = nil,
        attributionRouteLifecycle: AttributionRouteLifecycle? = nil,
        clickSource: ClickSource = .primaryCTA,
        clickBeaconImpressionId: String? = nil,
        bridge: CreativeBridge? = nil,
        attribution: AdAttribution? = nil,
        externalClickOnly: Bool = false,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil,
        reportsContentHeight: Bool = false,
        retainedImpressionId: String? = nil,
        telemetryAdFormat: String? = nil,
        visibilityRelay: VisibilityRelay? = nil
    ) {
        self.url = url
        self.htmlString = htmlString
        self.baseURL = baseURL
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onMessageReceived = onMessageReceived
        self.onAdClick = onAdClick
        self.onClickHandoffPendingChanged = onClickHandoffPendingChanged
        self.onAttributionRouteOutcome = onAttributionRouteOutcome
        self.attributionRouteLifecycle = attributionRouteLifecycle
        self.clickSource = clickSource
        self.clickBeaconImpressionId = clickBeaconImpressionId
        self.bridge = bridge
        self.attribution = attribution
        self.externalClickOnly = externalClickOnly
        self.ctaTrackingUrl = ctaTrackingUrl
        self.ctaDestination = ctaDestination
        self.ctaStoreOpen = ctaStoreOpen
        self.ctaStoreUrl = ctaStoreUrl
        self.reportsContentHeight = reportsContentHeight
        self.retainedImpressionId = retainedImpressionId
        self.telemetryAdFormat = telemetryAdFormat
        self.visibilityRelay = visibilityRelay
    }

    init(
        url: URL? = nil,
        htmlString: String? = nil,
        baseURL: URL? = nil,
        onNavigationCommitted: (() -> Void)? = nil,
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: ((Error) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil,
        onAdClick: (() -> Void)?,
        onClickHandoffPendingChanged: ((Bool) -> Void)? = nil,
        onAttributionRouteOutcome: ((AttributionRouteOutcome) -> Void)? = nil,
        bridge: CreativeBridge? = nil,
        attribution: AdAttribution? = nil,
        externalClickOnly: Bool = false,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil,
        reportsContentHeight: Bool = false,
        retainedImpressionId: String? = nil,
        telemetryAdFormat: String? = nil,
        visibilityRelay: VisibilityRelay? = nil
    ) {
        self.init(
            url: url,
            htmlString: htmlString,
            baseURL: baseURL,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMessageReceived: onMessageReceived,
            onAdClick: onAdClick.map { callback in { _ in callback() } },
            onClickHandoffPendingChanged: onClickHandoffPendingChanged,
            onAttributionRouteOutcome: onAttributionRouteOutcome,
            bridge: bridge,
            attribution: attribution,
            externalClickOnly: externalClickOnly,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreOpen: ctaStoreOpen,
            ctaStoreUrl: ctaStoreUrl,
            reportsContentHeight: reportsContentHeight,
            retainedImpressionId: retainedImpressionId,
            telemetryAdFormat: telemetryAdFormat,
            visibilityRelay: visibilityRelay
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        // Pull a prewarmed web view from the pool when one is available so the
        // expensive allocation / process spin-up was already paid off the
        // critical path. The pool wires the shared process pool and the
        // postMessage-forwarding script; we only attach this instance's
        // coordinator (navigation/UI delegate) and message callback here.
        //
        // Match the iframe sandbox attributes from React:
        // sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-forms"
        // WKWebView handles these by default; scripts and forms are always allowed.
        let coordinator = context.coordinator
        let onMessage: (WebViewForwardedMessage) -> Void = { [weak coordinator] message in
            coordinator?.handleMessage(message)
        }
        let webView: WKWebView
        if let impressionId = retainedImpressionId, !impressionId.isEmpty {
            // Native-ad retained path: reattach this serve's already-rendered view when the store
            // has one (no reload — eliminates the blank-then-pop flash on a recycled feed row), or
            // adopt a fresh pool view into the store so the NEXT remount reattaches it.
            let attach = NativeAdWebViewStore.shared.attach(
                impressionId: impressionId,
                creativeKey: storeCreativeKey,
                delegate: coordinator,
                onMessage: onMessage
            )
            webView = attach.webView
            if attach.alreadyLoaded {
                // Pre-mark the coordinator with the current content so `updateUIView` sees no
                // change and does NOT reload the creative into the retained view. The injected
                // height script keeps running in-page; the slot's height was restored from
                // NativeAdCache, so no re-report is needed either.
                coordinator.currentHTML = htmlString
                coordinator.currentURL = url
                coordinator.currentBaseURL = baseURL
                coordinator.realLoadStarted = true
                // Re-assert overflow:hidden on reattach — the full height script is not re-run
                // on this path, and older retained sessions may predate the lock CSS.
                webView.evaluateJavaScript(Coordinator.overflowLockScript, completionHandler: nil)
            }
        } else {
            webView = WebViewPool.shared.acquire(
                delegate: coordinator,
                onMessage: onMessage,
                surface: telemetryAdFormat
            )
        }
        // The coordinator needs the web view to post `GET_*` replies back into the page.
        coordinator.webView = webView
        // Point the visibility relay at this acquired view so scroll-driven `window.onVisibility`
        // pushes reach it; held on the coordinator so dismantle can unbind. No-op when unset.
        coordinator.visibilityRelay = visibilityRelay
        visibilityRelay?.bind(webView)
        configureScrollBehavior(webView, coordinator: coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onNavigationCommitted = onNavigationCommitted
        coordinator.onNavigationFinished = onNavigationFinished
        coordinator.onNavigationFailed = onNavigationFailed
        coordinator.onMessageReceived = onMessageReceived
        coordinator.onAdClick = onAdClick
        coordinator.onClickHandoffPendingChanged = onClickHandoffPendingChanged
        coordinator.onAttributionRouteOutcome = onAttributionRouteOutcome
        coordinator.attributionRouteLifecycle = attributionRouteLifecycle
        coordinator.clickSource = clickSource
        coordinator.clickBeaconImpressionId = clickBeaconImpressionId
        if coordinator.bridge !== bridge {
            coordinator.bridge?.stop()
            coordinator.bridge = bridge
        }
        coordinator.attribution = attribution
        coordinator.externalClickOnly = externalClickOnly
        coordinator.ctaTrackingUrl = ctaTrackingUrl
        coordinator.ctaDestination = ctaDestination
        coordinator.ctaStoreOpen = ctaStoreOpen
        coordinator.ctaStoreUrl = ctaStoreUrl
        coordinator.reportsContentHeight = reportsContentHeight
        coordinator.telemetryAdFormat = telemetryAdFormat
        if coordinator.visibilityRelay !== visibilityRelay {
            coordinator.visibilityRelay?.bind(nil)
            coordinator.visibilityRelay = visibilityRelay
            visibilityRelay?.bind(webView)
        }

        // Re-apply every update: pool reuse + content-size churn can re-enable bounce even when
        // `isScrollEnabled` stays false (visible as a tiny rubber-band while the feed scrolls).
        configureScrollBehavior(webView, coordinator: coordinator)

        // The slot can be recycled to a DIFFERENT serve in place (host list recycling updates
        // props without remaking this representable). The coordinator's id — set once in
        // makeCoordinator — must follow, or dismantle detaches under the wrong key; and the store
        // session retained under the old id must be re-keyed before the new creative loads into
        // its view, or a revisit of the old serve would reattach the wrong DOM.
        if coordinator.retainedImpressionId != retainedImpressionId {
            if let oldId = coordinator.retainedImpressionId, !oldId.isEmpty {
                NativeAdWebViewStore.shared.rebind(
                    webView,
                    from: oldId,
                    to: retainedImpressionId,
                    creativeKey: storeCreativeKey
                )
            }
            coordinator.retainedImpressionId = retainedImpressionId
            coordinator.prepareForRetainedServeRebind()
            // A DIFFERENT serve must always issue a fresh navigation, even when its markup is
            // byte-identical to the previous serve's (templated creatives): the old page is live
            // DOM with the old serve's state (timers, macros, viewed animations) while clicks and
            // beacons already carry the new id. Clearing the load-tracking state makes the block
            // below re-issue the load; its didFinish then marks the rebound store session
            // loadCompleted, so the new serve is retained (not destroyed) on scroll-out.
            coordinator.currentHTML = nil
            coordinator.currentURL = nil
            coordinator.currentBaseURL = nil
        }

        // Only load if URL/HTML changed
        let currentURL = coordinator.currentURL
        let currentHTML = coordinator.currentHTML

        if let html = htmlString, html != currentHTML || baseURL != coordinator.currentBaseURL {
            coordinator.currentHTML = html
            coordinator.currentURL = nil
            coordinator.currentBaseURL = baseURL
            coordinator.realLoadStarted = true
            coordinator.trackRequestedNavigation(webView.loadHTMLString(html, baseURL: baseURL))
        } else if let url = url, url != currentURL {
            coordinator.currentURL = url
            coordinator.currentHTML = nil
            coordinator.currentBaseURL = nil
            coordinator.realLoadStarted = true
            let request = URLRequest(url: url)
            coordinator.trackRequestedNavigation(webView.load(request))
        }
    }

    /// Native ads size to content and must never scroll (PRD) — even a 1pt rubber-band steals the
    /// host feed's gesture. Games keep the default scrollable WKWebView.
    private func configureScrollBehavior(_ webView: WKWebView, coordinator: Coordinator) {
        let scrollable = !reportsContentHeight
        let scrollView = webView.scrollView
        scrollView.isScrollEnabled = scrollable
        scrollView.bounces = scrollable
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInsetAdjustmentBehavior = .never
        if !scrollable {
            scrollView.showsVerticalScrollIndicator = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.contentInset = .zero
            scrollView.scrollIndicatorInsets = .zero
            scrollView.panGestureRecognizer.isEnabled = false
            // WebKit still nudges contentOffset when contentSize is a hair taller than bounds
            // (looks like a tiny scroll at the bottom of the card). Pin it continuously via KVO —
            // do not assign scrollView.delegate (WKWebView owns that).
            coordinator.lockContentOffset(scrollView)
            if scrollView.contentOffset != .zero {
                scrollView.setContentOffset(.zero, animated: false)
            }
        } else {
            scrollView.panGestureRecognizer.isEnabled = true
            coordinator.unlockContentOffset()
        }
    }

    /// Return the web view to the pool when SwiftUI tears this representable down,
    /// so the (expensive) WKWebView + its Web Content process is recycled for the
    /// next acquire instead of being deallocated. A retained native-ad view is
    /// instead kept — rendered DOM intact — by `NativeAdWebViewStore` for the next
    /// remount of the same serve.
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.unlockContentOffset()
        coordinator.detachPendingClickState()
        stopBeforeRecycling(stop: { coordinator.bridge?.stop() }) {
            coordinator.bridge = nil
            coordinator.webView = nil
            // Stop forwarding visibility into a view that's about to be recycled/retained.
            coordinator.visibilityRelay?.bind(nil)
            if let impressionId = coordinator.retainedImpressionId,
               NativeAdWebViewStore.shared.detach(uiView, impressionId: impressionId) {
                return // retained (or destroyed if render-dead) — never pool-released
            }
            WebViewPool.shared.release(uiView)
        }
    }

    /// The creative-identity key for `NativeAdWebViewStore`: the iframe URL when loading by URL,
    /// else the HTML content hash (stable within a process — the cached response is reused across
    /// remounts, so the same serve always produces the same key).
    private var storeCreativeKey: String {
        if let url { return url.absoluteString }
        return "html:\(htmlString?.hashValue ?? 0)"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMessageReceived: onMessageReceived,
            onAdClick: onAdClick,
            onClickHandoffPendingChanged: onClickHandoffPendingChanged,
            onAttributionRouteOutcome: onAttributionRouteOutcome,
            attributionRouteLifecycle: attributionRouteLifecycle,
            clickSource: clickSource,
            clickBeaconImpressionId: clickBeaconImpressionId,
            bridge: bridge,
            attribution: attribution,
            externalClickOnly: externalClickOnly,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreOpen: ctaStoreOpen,
            ctaStoreUrl: ctaStoreUrl,
            reportsContentHeight: reportsContentHeight,
            retainedImpressionId: retainedImpressionId,
            telemetryAdFormat: telemetryAdFormat
        )
    }

    // MARK: - Coordinator

    @preconcurrency
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onNavigationCommitted: (() -> Void)?
        var onNavigationFinished: (() -> Void)?
        var onNavigationFailed: ((Error) -> Void)?
        var onMessageReceived: ((String) -> Void)?
        var onAdClick: ((ClickInteraction) -> Void)?
        var onClickHandoffPendingChanged: ((Bool) -> Void)?
        var onAttributionRouteOutcome: ((AttributionRouteOutcome) -> Void)?
        var attributionRouteLifecycle: AttributionRouteLifecycle?
        var clickSource: ClickSource
        var clickBeaconImpressionId: String?
        /// The WebView ↔ SDK bridge (PRD §3); `nil` for non-ad web views.
        var bridge: CreativeBridge?
        /// Attribution tokens applied to the in-app store sheet this coordinator routes CTAs to.
        var attribution: AdAttribution?
        /// The web view this coordinator drives — used to post `GET_*` replies back into the page.
        weak var webView: WKWebView?
        /// Native-ad mode: route user clicks to the external browser; report content height.
        var externalClickOnly: Bool
        /// Native-ad mode: server CTA routing — the MMP tracker URL to open (preferred over the
        /// in-creative URL) and where it routes. See `WebViewRepresentable.ctaTrackingUrl`.
        var ctaTrackingUrl: String?
        var ctaDestination: AdDestination
        var ctaStoreOpen: StoreOpen
        /// The serve's raw App Store link — drives the deterministic in-creative CTA route.
        /// See `WebViewRepresentable.ctaStoreUrl`.
        var ctaStoreUrl: String?
        var reportsContentHeight: Bool
        /// Native-ad retained-store key; drives the dismantle retain-vs-pool-release decision and
        /// the render-death bookkeeping. See `WebViewRepresentable.retainedImpressionId`.
        var retainedImpressionId: String?
        /// Ad-format tag for WebView telemetry; nil → untagged.
        var telemetryAdFormat: String?
        /// Native-ad visibility relay (set on acquire); used to unbind on dismantle. See `VisibilityRelay`.
        var visibilityRelay: VisibilityRelay?
        /// Monotonic page-load start (set on provisional navigation start) for `webview_page_load`.
        private var pageStartUptime: TimeInterval?
        /// Main-document navigation state. Object identifiers avoid retaining WebKit's navigation
        /// objects while rejecting late callbacks from pooled or rebound documents.
        private var navigationTracker = WebNavigationTracker<ObjectIdentifier>()

        func trackRequestedNavigation(_ navigation: WKNavigation?) {
            navigationTracker.trackRequested(navigation.map(ObjectIdentifier.init))
        }

        /// A retained view is about to load a different serve into the same WKWebView. Clear every
        /// old-document verdict before issuing the new load and disarm bridge audio immediately;
        /// stale callbacks remain explicitly rejected by the navigation tracker.
        func prepareForRetainedServeRebind() {
            detachPendingClickState()
            automaticPopupGuard.reset()
            if attributionRouteLifecycle == nil {
                ownedAutomaticRouteScope = AnyHashable(UUID())
                ownedAutomaticRoutes.reset(scope: ownedAutomaticRouteScope)
            }
            navigationTracker.resetForRebind()
            pageStartUptime = nil
            mainFrameHTTPFailed = false
            renderRecoveryAttempted = false
            realLoadStarted = false
            bridge?.stop()
        }

        /// Tracks the currently loaded URL to avoid redundant loads
        var currentURL: URL?
        /// Tracks the currently loaded HTML to avoid redundant loads
        var currentHTML: String?
        /// True once `updateUIView` has issued the real content load. The pool prewarms each view with
        /// an `about:blank` load; its (late) navigation callbacks must be ignored. Gating on this flag
        /// — rather than `webView.url == "about:blank"` — is correct even for a native creative loaded
        /// via `loadHTMLString(_:baseURL:)` with a `nil` baseURL, which itself makes `webView.url`
        /// report `about:blank`. The old URL check matched that real load too and suppressed the
        /// height-reporting script, so the native slot never sized and collapsed (rendered blank).
        var realLoadStarted = false
        /// Base URL of the current HTML load, remembered so the exact creative can be re-issued if the
        /// web-content process is terminated (`reload()` can't restore a `loadHTMLString` load — its URL
        /// is the baseURL, not the content).
        var currentBaseURL: URL?
        /// One-shot guard for the reload-after-termination recovery, so a creative that reliably crashes
        /// the renderer can't spin in a reload loop. Reset on each successful load (`didFinish`).
        var renderRecoveryAttempted = false
        /// True when the current main-frame load answered 4xx/5xx. WKWebView renders the error body
        /// as a *successful* navigation, so without this flag the ensuing `didFinish` would mark the
        /// retained session healthy (`noteLoadSucceeded`) right after the HTTP error marked it
        /// unusable — letting a recycled row reattach the error page with no reload. Reset when a
        /// new load starts.
        private var mainFrameHTTPFailed = false

        /// One atomic claim guards both publisher notification and destination routing when WebKit
        /// reports one target=_blank gesture through both delegate methods.
        private var clickClaim = CreativeClickClaim()
        let automaticPopupGuard = AutomaticRouteGuard()
        private let ownedAutomaticRoutes = AutomaticRouteCoordinator()
        private var ownedAutomaticRouteScope = AnyHashable(UUID())
        private var pendingAutomaticUserHandoff: AutomaticRouteUserHandoff?
        private var clickHandoffPending = false
        private var pendingAttributionRoute: AttributionRouteExecution?

        /// Pins `contentOffset` at zero for native ads. WKWebView owns `scrollView.delegate`, so we
        /// use KVO instead of becoming the scroll delegate.
        private var contentOffsetObservation: NSKeyValueObservation?

        /// Claims a genuine activation, records it, then waits behind telemetry persistence before
        /// handing off to StoreKit/Safari. Returning false means this delegate path must not route.
        private func routeClaimedClick(
            userActivated: Bool,
            route: @escaping @MainActor (AttributionRouteExecution) -> Void
        ) -> Bool {
            let now = ProcessInfo.processInfo.systemUptime
            guard let interaction = clickClaim.claim(
                userActivated: userActivated,
                source: clickSource,
                now: now
            ) else { return false }
            let lifecycle = attributionRouteLifecycle
            let automaticRoutes = lifecycle?.automaticRoutes ?? ownedAutomaticRoutes
            let automaticRouteScope = lifecycle?.automaticRouteScope ?? ownedAutomaticRouteScope
            guard let automaticUserHandoff = automaticRoutes.beginUserHandoff(
                scope: automaticRouteScope
            ) else { return false }
            let source = clickSource
            let routeID = UUID()
            let terminalOutcome = onAttributionRouteOutcome
            let execution = makeCreativeAttributionRouteExecution(
                id: routeID,
                source: source,
                originatingScene: webView?.window?.windowScene,
                isActive: { [weak self] in
                    let presentationActive = lifecycle?.isActive ?? (self?.webView != nil)
                    return presentationActive && UIApplication.shared.applicationState == .active
                },
                onUIHandoffReleased: { [weak self] in
                    guard self?.pendingAttributionRoute?.id == routeID else { return }
                    self?.setClickHandoffPending(false)
                },
                onTerminalOutcome: terminalOutcome,
                onFinished: { [weak self] finishedID in
                    if self?.pendingAttributionRoute?.id == finishedID {
                        self?.pendingAttributionRoute = nil
                    }
                }
            )
            pendingAutomaticUserHandoff = automaticUserHandoff
            pendingAttributionRoute = execution
            setClickHandoffPending(true)
            onAdClick?(interaction)
            ClickHandoffPersistence.wait(
                interaction: interaction,
                beaconImpressionId: clickBeaconImpressionId
            ) {
                DispatchQueue.main.async { [weak self] in
                    guard self?.pendingAttributionRoute === execution || lifecycle != nil else {
                        automaticRoutes.cancelUserHandoff(
                            automaticUserHandoff,
                            scope: automaticRouteScope
                        )
                        execution.cancel()
                        return
                    }
                    guard automaticRoutes.commitUserHandoff(
                        automaticUserHandoff,
                        scope: automaticRouteScope
                    ) else {
                        execution.cancel()
                        return
                    }
                    if self?.pendingAutomaticUserHandoff == automaticUserHandoff {
                        self?.pendingAutomaticUserHandoff = nil
                    }
                    route(execution)
                }
            }
            return true
        }

        private func routeAutomaticNavigation(_ url: URL) {
            let lifecycle = attributionRouteLifecycle
            let automaticRoutes = lifecycle?.automaticRoutes ?? ownedAutomaticRoutes
            let automaticRouteScope = lifecycle?.automaticRouteScope ?? ownedAutomaticRouteScope
            let route = externalClickOnly
                ? nativeCTARoute(fallback: url)
                : creativeCTARoute(
                    fallback: url,
                    fallbackStoreURL: validatedDirectAppStoreURL(url.absoluteString)
                )
            automaticRoutes.requestAutomaticRoute(scope: automaticRouteScope) { [weak self] in
                let execution = AttributionRouteExecution(
                    originatingScene: self?.webView?.window?.windowScene,
                    isActive: { [weak self] in
                        let presentationActive = lifecycle?.isActive ?? (self?.webView != nil)
                        return presentationActive && UIApplication.shared.applicationState == .active
                    },
                    onOutcome: { outcome in
                        recordAttributionRoute(outcome: outcome, source: .autoRedirect)
                    }
                )
                route(execution)
            }
        }

        private func popupAdmission(
            for url: URL,
            isPopup: Bool,
            userActivated: Bool
        ) -> CreativePopupRouteAdmission {
            let scheme = url.scheme?.lowercased() ?? ""
            let currentHost = (currentURL ?? currentBaseURL)?.host?.lowercased() ?? ""
            let targetHost = url.host?.lowercased() ?? ""
            let sameOriginHTTP = (scheme == "http" || scheme == "https")
                && !targetHost.isEmpty
                && currentHost == targetHost
            return creativeAutomaticRouteAdmission(
                isPopup: isPopup,
                userActivated: userActivated,
                sameOriginHTTP: sameOriginHTTP,
                isDirectStoreNavigation: validatedDirectAppStoreURL(url.absoluteString) != nil,
                automaticGuard: automaticPopupGuard
            )
        }

        func detachPendingClickState() {
            // Fullscreen/fallback containers own a presentation lifecycle and keep accepted routes
            // alive across WebView replacement. Lifecycle-less native-ad rows cancel on rebind.
            if attributionRouteLifecycle == nil {
                if let pendingAutomaticUserHandoff {
                    ownedAutomaticRoutes.cancelUserHandoff(
                        pendingAutomaticUserHandoff,
                        scope: ownedAutomaticRouteScope
                    )
                    self.pendingAutomaticUserHandoff = nil
                }
                pendingAttributionRoute?.cancel()
                pendingAttributionRoute = nil
            }
            setClickHandoffPending(false)
        }

        private func setClickHandoffPending(_ pending: Bool) {
            guard clickHandoffPending != pending else { return }
            clickHandoffPending = pending
            onClickHandoffPendingChanged?(pending)
        }

        /// Continuously cancel any WebKit-driven offset nudge (sub-pt content overflow).
        func lockContentOffset(_ scrollView: UIScrollView) {
            guard reportsContentHeight else {
                unlockContentOffset()
                return
            }
            if contentOffsetObservation == nil {
                contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { scrollView, _ in
                    if scrollView.contentOffset != .zero {
                        scrollView.setContentOffset(.zero, animated: false)
                    }
                }
            }
        }

        func unlockContentOffset() {
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
        }

        /// Retained native-ad path: the view no longer shows a valid creative (render process died,
        /// or the main-frame load failed — e.g. offline when the row scrolled in). Flag the store
        /// session so the next attach rebuilds the creative instead of reattaching a blank view —
        /// which would also suppress the retry a remount of the still-cached fill is expected to do.
        /// No-op for ephemeral (non-retained) views.
        private func noteRetainedUnusable(_ webView: WKWebView?) {
            guard retainedImpressionId != nil, let webView else { return }
            // Synchronous on the main thread (WebKit delivers these callbacks there) so a
            // detach/attach in the same runloop turn can't act before the flag lands.
            NativeAdWebViewStore.markUnusable(viewID: ObjectIdentifier(webView))
        }

        /// Schemes that should be handled within the webview
        private let internalSchemes: Set<String> = ["about", "data", "blob"]

        /// App Store id extraction lives in the shared `CreativeCTARouter` so the
        /// game-iframe CTA and the native creative CTA resolve ids identically.
        /// `CreativeCTARouter.appStoreID` is `nonisolated` (pure regex), so this is
        /// a plain direct call — no `MainActor.assumeIsolated` trap on the hot path.
        nonisolated private func appStoreID(from url: URL) -> String? {
            CreativeCTARouter.appStoreID(from: url)
        }

        init(
            onNavigationCommitted: (() -> Void)? = nil,
            onNavigationFinished: (() -> Void)?,
            onNavigationFailed: ((Error) -> Void)?,
            onMessageReceived: ((String) -> Void)?,
            onAdClick: ((ClickInteraction) -> Void)? = nil,
            onClickHandoffPendingChanged: ((Bool) -> Void)? = nil,
            onAttributionRouteOutcome: ((AttributionRouteOutcome) -> Void)? = nil,
            attributionRouteLifecycle: AttributionRouteLifecycle? = nil,
            clickSource: ClickSource = .primaryCTA,
            clickBeaconImpressionId: String? = nil,
            bridge: CreativeBridge? = nil,
            attribution: AdAttribution? = nil,
            externalClickOnly: Bool = false,
            ctaTrackingUrl: String? = nil,
            ctaDestination: AdDestination = .appstore,
            ctaStoreOpen: StoreOpen = .skstoreproduct,
            ctaStoreUrl: String? = nil,
            reportsContentHeight: Bool = false,
            retainedImpressionId: String? = nil,
            telemetryAdFormat: String? = nil
        ) {
            self.onNavigationCommitted = onNavigationCommitted
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMessageReceived = onMessageReceived
            self.onAdClick = onAdClick
            self.onClickHandoffPendingChanged = onClickHandoffPendingChanged
            self.onAttributionRouteOutcome = onAttributionRouteOutcome
            self.attributionRouteLifecycle = attributionRouteLifecycle
            self.clickSource = clickSource
            self.clickBeaconImpressionId = clickBeaconImpressionId
            self.bridge = bridge
            self.attribution = attribution
            self.externalClickOnly = externalClickOnly
            self.ctaTrackingUrl = ctaTrackingUrl
            self.ctaDestination = ctaDestination
            self.ctaStoreOpen = ctaStoreOpen
            self.ctaStoreUrl = ctaStoreUrl
            self.reportsContentHeight = reportsContentHeight
            self.retainedImpressionId = retainedImpressionId
            self.telemetryAdFormat = telemetryAdFormat
            ownedAutomaticRoutes.activate(scope: ownedAutomaticRouteScope)
        }

        /// Routes a `window.postMessage` envelope from the creative: to the bridge (PRD §3)
        /// when one is attached — which posts `GET_*` replies back via this web view — else to
        /// the legacy `onMessageReceived` callback (game iframe).
        func handleMessage(_ message: WebViewForwardedMessage) {
            switch message {
            case .userActivatedCTA(let url):
                guard CreativeCTAOpenMessage.isAllowed(
                    url,
                    destination: ctaDestination,
                    externalClickOnly: externalClickOnly
                ) else { return }
                let route = externalClickOnly
                    ? nativeCTARoute(fallback: url)
                    : creativeCTARoute(
                        fallback: url,
                        fallbackStoreURL: validatedDirectAppStoreURL(url.absoluteString)
                    )
                _ = routeClaimedClick(userActivated: true, route: route)
                return
            case .page(let body):
                handlePageMessage(body)
            }
        }

        private func handlePageMessage(_ body: String) {
            // Intercept creative JS errors (window.onerror → simulaSDK) before normal routing, so they
            // are captured for ALL modes (bridge + native). Recorded as deduped, redacted telemetry.
            if body.contains("SIMULA_JS_ERROR"),
               let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["type"] as? String) == "SIMULA_JS_ERROR" {
                Telemetry.shared.recordError(
                    signature: "creative:js_error",
                    errorCode: telemetryAdFormat,
                    message: obj["message"] as? String,
                    breadcrumb: "line=\(obj["line"] ?? 0)"
                )
                return
            }
            if let bridge {
                bridge.handle(body) { [weak self] js in
                    self?.webView?.evaluateJavaScript(js, completionHandler: nil)
                }
            } else {
                onMessageReceived?(body)
            }
        }

        /// Native-ad CTA routing (`externalClickOnly`). The selected `StoreOpen` controls whether an
        /// App Store destination uses StoreKit (default) or leaves the app (`external`), falling back
        /// to the validated creative URL when the serve carried no tracker.
        ///
        /// The serve's raw store link (`ctaStoreUrl`) makes both branches deterministic, exactly like
        /// the interstitial/rewarded WebViews: the store surface opens from its app id while the
        /// tracker fires in the background, instead of depending on the tracker's redirect chain.
        ///
        /// SKAN parity with interstitial/rewarded: when the serve carries usable `skan_attribution`
        /// tokens AND the CTA is an App Store destination, the click instead routes through the **in-app**
        /// `SKStoreProductViewController`, so the tokens ride the StoreKit-rendered sheet and the SKAN
        /// install postback credits the campaign (StoreKit tokens can't ride an external open).
        private func nativeCTARoute(fallback: URL) -> @MainActor (AttributionRouteExecution) -> Void {
            let destination = ctaDestination
            let selectedURL = preferredCreativeClickURL(
                trackingUrl: ctaTrackingUrl,
                fallback: fallback,
                destination: destination,
                externalClickOnly: true
            )
            let fallbackStoreURL = validatedDirectAppStoreURL(fallback.absoluteString)
            let storeOpen = ctaStoreOpen
            let storeUrl = ctaStoreUrl
            let attribution = self.attribution
            return { execution in
                Self.routeNativeCTA(
                    selectedURL: selectedURL,
                    destination: destination,
                    storeOpen: storeOpen,
                    storeUrl: storeUrl,
                    fallbackStoreURL: fallbackStoreURL,
                    attribution: attribution,
                    execution: execution
                )
            }
        }

        /// Imperative interstitial/rewarded/fallback CTA routing. The HTML navigation proves a user
        /// interaction; the separately decoded tracker remains the attribution source of truth.
        private func creativeCTARoute(
            fallback: URL,
            fallbackStoreURL: URL?
        ) -> @MainActor (AttributionRouteExecution) -> Void {
            let destination = ctaDestination
            let target = preferredCreativeClickURL(
                trackingUrl: ctaTrackingUrl,
                fallback: fallback,
                destination: destination,
                externalClickOnly: false
            )
            let storeOpen = ctaStoreOpen
            let storeUrl = ctaStoreUrl
            let attribution = self.attribution
            return { execution in
                guard let target else {
                    guard execution.begin(path: .mmpRedirect) else { return }
                    execution.fail("invalid_url")
                    return
                }
                CreativeCTARouter.routeCreativeTap(
                    url: target,
                    destination: destination,
                    storeOpen: storeOpen,
                    storeUrl: storeUrl,
                    fallbackStoreURL: fallbackStoreURL,
                    attribution: attribution,
                    execution: execution
                )
            }
        }

        /// Task body for the native-CTA routing (named method — see the task-shape note in
        /// TelemetryManager).
        @MainActor
        private static func routeNativeCTA(
            selectedURL: URL?,
            destination: AdDestination,
            storeOpen: StoreOpen,
            storeUrl: String?,
            fallbackStoreURL: URL?,
            attribution: AdAttribution?,
            execution: AttributionRouteExecution
        ) {
            guard let selectedURL else {
                guard execution.begin(path: .mmpRedirect) else { return }
                execution.fail("invalid_url")
                return
            }
            CreativeCTARouter.routeCreativeTap(
                url: selectedURL,
                destination: destination,
                storeOpen: storeOpen,
                storeUrl: storeUrl,
                fallbackStoreURL: fallbackStoreURL,
                externalClickOnly: true,
                attribution: attribution,
                execution: execution
            )
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // Start the page-load timer for the real content load (ignore the prewarm about:blank).
            // Gate on realLoadStarted, not the URL: a native creative loaded with a nil baseURL also
            // reports webView.url == about:blank, and must NOT be skipped.
            guard realLoadStarted else { return }
            guard navigationTracker.didStart(navigation.map(ObjectIdentifier.init)) else { return }
            automaticPopupGuard.reset()
            mainFrameHTTPFailed = false // fresh load — the previous HTTP verdict no longer applies
            pageStartUptime = ProcessInfo.processInfo.systemUptime
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard realLoadStarted,
                  navigationTracker.isActive(navigation.map(ObjectIdentifier.init)),
                  !mainFrameHTTPFailed else { return }
            bridge?.pageDidCommit()
            onNavigationCommitted?()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Ignore the pool's prewarm load — only the real content load counts. See realLoadStarted:
            // gating on the URL would also drop the native (nil-baseURL → about:blank) creative's load
            // and never inject the height-reporting script, collapsing the slot.
            guard realLoadStarted else { return }
            // A pooled view may still deliver its reset-to-about:blank completion after the real
            // navigation starts. Only the latest tracked main document may run success lifecycle.
            guard navigationTracker.didFinish(navigation.map(ObjectIdentifier.init)) else { return }
            // Main-frame 4xx/5xx: this didFinish is WebKit rendering the ERROR page, not the
            // creative — the slot already collapsed via onNavigationFailed (decidePolicyFor). Run
            // NONE of the success path: don't mark the store session healthy (it was just flagged
            // unusable), don't fire onNavigationFinished, and don't inject the height script — the
            // error page would post SIMULA_AD_HEIGHT, resizing the collapsed slot and poisoning the
            // cached height the retry restores. (Only the native path can set this flag.)
            if mainFrameHTTPFailed {
                pageStartUptime = nil
                return
            }
            // A clean load means the (possibly just-reloaded) creative is healthy — restore the
            // one-shot render-recovery budget for any future web-content-process termination.
            renderRecoveryAttempted = false
            // Retained native-ad view: clear the store's render-dead flag too, so a recovered view
            // is retained (not destroyed) on the next detach. Synchronous on main so a same-runloop
            // detach/attach sees the updated state.
            if retainedImpressionId != nil {
                NativeAdWebViewStore.markLoadSucceeded(viewID: ObjectIdentifier(webView))
            }
            // webview_page_load timing (best-effort; Tier 3 diagnostics).
            if let start = pageStartUptime {
                pageStartUptime = nil
                Telemetry.shared.recordLifecycle(
                    stage: "webview_page_load", adFormat: telemetryAdFormat, adUnitId: nil, adId: nil,
                    serveId: nil, durationMs: Int((ProcessInfo.processInfo.systemUptime - start) * 1000), errorCode: nil
                )
            }
            bridge?.pageDidFinishLoading { [weak self, weak webView] js in
                guard let self, let webView, self.webView === webView else { return }
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            onNavigationFinished?()
            // Native ad: start reporting content height so the slot can size its container.
            if reportsContentHeight {
                webView.evaluateJavaScript(Coordinator.heightReportingScript, completionHandler: nil)
            }
            // Replay the current visibility ratio now that window.onVisibility exists — pushes
            // issued while the page was loading were dropped by the guard but still advanced the
            // relay's dedup baseline, leaving an off-screen creative deaf to the bridge (its
            // no-bridge fallback then animates before the slot scrolls into view).
            visibilityRelay?.flush()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The creative's web-content process crashed/was jettisoned (commonly an OS reclaim while
            // backgrounded). Record it; the SDK survives (WKWebView is sandboxed, so the host app is
            // never taken down with it).
            Telemetry.shared.recordError(
                signature: "webview:render_gone",
                errorCode: "render_terminated",
                breadcrumb: telemetryAdFormat
            )
            bridge?.stop()
            // A renderer death is a real pressure signal: drain idle views and suppress retention /
            // explicit minigame prewarm for the cooldown. Ordinary backgrounding does not do this.
            WebViewPool.shared.handleRendererDeath()
            NativeAdWebViewStore.shared.handleRendererDeath()
            // Retained native-ad view: flag the store session so a dead view is never reattached.
            // The in-place recovery below may still succeed — didFinish clears the flag then.
            noteRetainedUnusable(webView)
            // Recover in place: a WKWebView is reusable after a termination, so re-issue the SAME
            // creative so the slot comes back instead of collapsing. reload() can't restore a
            // loadHTMLString load (its URL is the baseURL, not the content), so re-load the stored
            // content. One-shot per successful load (reset in didFinish) so a creative that reliably
            // crashes the renderer can't spin a reload loop.
            if !renderRecoveryAttempted {
                if let html = currentHTML {
                    renderRecoveryAttempted = true
                    trackRequestedNavigation(webView.loadHTMLString(html, baseURL: currentBaseURL))
                    return
                }
                if let url = currentURL {
                    renderRecoveryAttempted = true
                    trackRequestedNavigation(webView.load(URLRequest(url: url)))
                    return
                }
            }
            // Already retried (or nothing to reload): surface terminal failure to any consumer. The
            // retained native slot collapses through this callback; fullscreen surfaces keep their
            // native black failure shield and stop showing a loading spinner.
            onNavigationFailed?(NSError(domain: "SimulaWebView", code: NSURLErrorCannotDecodeContentData))
        }

        // An HTTP error status on the creative's main-frame load (e.g. the iframe URL 404s/500s) still
        // reports as a successful navigation on WKWebView — it renders the error body and never hits
        // didFail. Mirror Android's onReceivedHttpError: treat every main-frame 4xx/5xx as a load
        // failure. Native slots collapse; fullscreen consumers keep their native black shield and
        // stop loading. The response remains allowed, but didFinish is suppressed below so WebKit's
        // error document can never be marked ready.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(.allow)
            guard navigationResponse.isForMainFrame,
                  let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 else {
                return
            }
            mainFrameHTTPFailed = true // the coming didFinish is the error page — see the flag's doc
            noteRetainedUnusable(webView)
            onNavigationFailed?(NSError(domain: "SimulaWebView", code: http.statusCode))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard navigationTracker.didFail(navigation.map(ObjectIdentifier.init)) else { return }
            if isCancelled(error) { return }
            bridge?.stop()
            noteRetainedUnusable(webView)
            onNavigationFailed?(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigationTracker.didFail(navigation.map(ObjectIdentifier.init)) else { return }
            // A cancelled provisional load happens when the real URL supersedes
            // the prewarm's about:blank load; it isn't a genuine failure.
            if isCancelled(error) { return }
            bridge?.stop()
            noteRetainedUnusable(webView)
            onNavigationFailed?(error)
        }

        private func isCancelled(_ error: Error) -> Bool {
            (error as NSError).code == NSURLErrorCancelled
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let isPopup = navigationAction.targetFrame == nil
            let userActivated = navigationAction.navigationType == .linkActivated
            let scheme = url.scheme?.lowercased() ?? ""

            // Allow internal schemes (about:blank, about:srcdoc, data:, blob:)
            if internalSchemes.contains(scheme) {
                decisionHandler(.allow)
                return
            }

            // Block javascript: URLs for security
            if scheme == "javascript" {
                decisionHandler(.cancel)
                return
            }

            let isDirectStoreNavigation = validatedDirectAppStoreURL(url.absoluteString) != nil
            if (isPopup || (!userActivated && isDirectStoreNavigation)), CreativeCTAOpenMessage.isAllowed(
                url,
                destination: ctaDestination,
                externalClickOnly: externalClickOnly
            ) {
                switch popupAdmission(for: url, isPopup: isPopup, userActivated: userActivated) {
                case .automatic:
                    routeAutomaticNavigation(url)
                    decisionHandler(.cancel)
                    return
                case .ignored where !userActivated:
                    decisionHandler(.cancel)
                    return
                case .billable, .ignored:
                    break
                }
            }

            // Native ad: route only user-activated exits here. Non-popup `.other` subresource and
            // server-redirect navigations still pass through so they can never become clicks.
            if externalClickOnly {
                if userActivated, CreativeCTAOpenMessage.isAllowed(
                    url,
                    destination: ctaDestination,
                    externalClickOnly: true
                ) {
                    // Prefer the server tracking URL (attribution-preserving); fall back to the tapped URL.
                    _ = routeClaimedClick(
                        userActivated: true,
                        route: nativeCTARoute(fallback: url)
                    )
                    decisionHandler(.cancel)
                    return
                }
                // Anything else (the initial load, same-origin, subresources) loads in place.
                decisionHandler(.allow)
                return
            }

            // Intercept App Store URLs → show in-app store sheet. The router's
            // presentation entry points are `@MainActor`; WebKit delivers this
            // delegate callback on the main thread, so hop there explicitly (no
            // `assumeIsolated`, which would trap if ever called off-main).
            if let appID = appStoreID(from: url) {
                // Fire CLICKED only for a user-activated link — consistent with the
                // cross-domain branch below and Android's `hasGesture()` guard — so a
                // programmatic redirect to the store can't fake a click. Routing is
                // unconditional (the game iframe's post-game auto-redirect still opens).
                if userActivated {
                    _ = routeClaimedClick(
                        userActivated: true,
                        route: creativeCTARoute(fallback: url, fallbackStoreURL: url)
                    )
                    decisionHandler(.cancel)
                    return
                }
                if isPopup {
                    decisionHandler(.cancel)
                    return
                }
                let attribution = self.attribution
                let originatingScene = webView.window?.windowScene
                Task { @MainActor in CreativeCTARouter.presentStoreProduct(appID: appID, attribution: attribution, originatingScene: originatingScene) }
                decisionHandler(.cancel)
                return
            }

            // Intercept itms-apps:// and itms:// schemes (direct App Store links)
            if scheme == "itms-apps" || scheme == "itms" {
                guard appStoreID(from: url) != nil else {
                    decisionHandler(.cancel)
                    return
                }
                if userActivated {
                    _ = routeClaimedClick(
                        userActivated: true,
                        route: creativeCTARoute(
                            fallback: url,
                            fallbackStoreURL: validatedDirectAppStoreURL(url.absoluteString)
                        )
                    )
                    decisionHandler(.cancel)
                    return
                }
                if isPopup {
                    decisionHandler(.cancel)
                    return
                }
                if let appID = appStoreID(from: url) {
                    let attribution = self.attribution
                    let originatingScene = webView.window?.windowScene
                    Task { @MainActor in CreativeCTARouter.presentStoreProduct(appID: appID, attribution: attribution, originatingScene: originatingScene) }
                } else {
                    // Couldn't extract app ID — let the system handle it
                    Task { @MainActor in UIApplication.shared.open(url) }
                }
                decisionHandler(.cancel)
                return
            }

            if userActivated,
               scheme != "http", scheme != "https",
               CreativeCTAOpenMessage.isAllowed(
                   url,
                   destination: ctaDestination,
                   externalClickOnly: false
               ) {
                _ = routeClaimedClick(
                    userActivated: true,
                    route: creativeCTARoute(
                        fallback: url,
                        fallbackStoreURL: validatedDirectAppStoreURL(url.absoluteString)
                    )
                )
                decisionHandler(.cancel)
                return
            }

            // User-initiated cross-domain clicks → deterministic store route when the serve
            // supplied its raw store link (in-app sheet + background tracker fire), else resolve
            // the redirect chain, then SKStoreProductViewController (App Store) or
            // SFSafariViewController (other).
            if userActivated,
               scheme == "http" || scheme == "https" {
                let currentHost = (currentURL ?? currentBaseURL)?.host?.lowercased() ?? ""
                let targetHost = url.host?.lowercased() ?? ""
                if !targetHost.isEmpty && currentHost != targetHost {
                    _ = routeClaimedClick(
                        userActivated: true,
                        route: creativeCTARoute(
                            fallback: url,
                            fallbackStoreURL: validatedDirectAppStoreURL(url.absoluteString)
                        )
                    )
                    decisionHandler(.cancel)
                    return
                }
            }

            // Same-origin navigations and server redirects → stay in webview
            decisionHandler(.allow)
        }

        // MARK: - WKUIDelegate

        /// Handles target="_blank" and window.open()
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                let userActivated = navigationAction.navigationType == .linkActivated
                guard CreativeCTAOpenMessage.isAllowed(
                    url,
                    destination: ctaDestination,
                    externalClickOnly: externalClickOnly
                ) else { return nil }
                switch popupAdmission(for: url, isPopup: true, userActivated: userActivated) {
                case .automatic:
                    routeAutomaticNavigation(url)
                    return nil
                case .ignored:
                    return nil
                case .billable:
                    break
                }
                // Native ad: target="_blank" / window.open follows the serve's store-open policy.
                if externalClickOnly {
                    // Prefer the server tracking URL (attribution-preserving); fall back to this URL.
                    _ = routeClaimedClick(
                        userActivated: userActivated,
                        route: nativeCTARoute(fallback: url)
                    )
                    return nil
                }
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "http" || scheme == "https" {
                    let currentHost = (currentURL ?? currentBaseURL)?.host?.lowercased() ?? ""
                    let targetHost = url.host?.lowercased() ?? ""
                    if !targetHost.isEmpty && currentHost != targetHost {
                        // Cross-domain → deterministic store route when the serve supplied its raw
                        // store link, else resolve redirects then route. Router entry point is
                        // `@MainActor`; this delegate runs on main, so hop explicitly rather than
                        // asserting isolation. WebKit can also invoke this for programmatic
                        // `window.open`; the document-start bridge suppresses genuine gesture
                        // popups first, while this fallback admits only explicit link activation.
                        _ = routeClaimedClick(
                            userActivated: userActivated,
                            route: creativeCTARoute(
                                fallback: url,
                                fallbackStoreURL: validatedDirectAppStoreURL(url.absoluteString)
                            )
                        )
                    } else if userActivated {
                        // Explicit same-origin target=_blank links stay in this web view. A
                        // programmatic `.other` popup is suppressed without navigating or routing.
                        webView.load(URLRequest(url: url))
                    }
                } else {
                    _ = routeClaimedClick(
                        userActivated: userActivated,
                        route: creativeCTARoute(
                            fallback: url,
                            fallbackStoreURL: validatedDirectAppStoreURL(url.absoluteString)
                        )
                    )
                }
            }
            return nil
        }

        /// Injected (via `evaluateJavaScript`) after a native-ad creative loads: posts the content
        /// height to native (over the pool's `simulaSDK` channel) on load + whenever it changes, so
        /// the slot resizes to fit. A `<meta viewport width=device-width,initial-scale=1>` creative
        /// maps 1 CSS px → 1 point, so the reported value is used directly as the SwiftUI height.
        /// Injected on native-ad load (and on retained-view reattach) so nothing in the creative can
        /// scroll. `scrollView.isScrollEnabled = false` only disables the WebView's MAIN scrolling
        /// node — WebKit gives inner scrollable regions (the `<iframe srcdoc>` the creative renders
        /// in, overflow divs) their own composited scrolling nodes that keep handling touches. The
        /// visible symptom: the card content nudges a few px at the start of a feed scroll. Styling
        /// the iframe *element* is not enough; the lock must land on `html,body` INSIDE each iframe
        /// document (same-origin — srcdoc inherits the parent origin — so `contentDocument` works).
        /// Re-applied on iframe `load` (a reload wipes injected styles) and via a MutationObserver
        /// for iframes attached after this script runs. Idempotent per document.
        static let overflowLockScript = """
        (function () {
          function lockDoc(doc) {
            try {
              if (!doc || doc.__simulaNoScroll) return;
              doc.__simulaNoScroll = true;
              var s = doc.createElement('style');
              s.textContent = 'html,body{overflow:hidden!important;overscroll-behavior:none!important;}';
              (doc.head || doc.documentElement).appendChild(s);
            } catch (e) {}
          }
          function lockFrame(frame) {
            try {
              frame.setAttribute('scrolling', 'no');
              frame.style.overflow = 'hidden';
            } catch (e) {}
            lockDoc(frame.contentDocument);
            if (!frame.__simulaNoScrollHook) {
              frame.__simulaNoScrollHook = true;
              try { frame.addEventListener('load', function () { lockDoc(frame.contentDocument); }); } catch (e) {}
            }
          }
          function lockAll() {
            try { document.querySelectorAll('iframe').forEach(lockFrame); } catch (e) {}
          }
          lockDoc(document);
          lockAll();
          try {
            // Hook the observer on documentElement, not body: at document-start injection (Android)
            // body is still null and no iframes exist yet, so a body-gated observer would never be
            // installed and nothing would re-run the lock for the srcdoc iframe parsed later.
            // documentElement exists from the first script tick; subtree:true covers body + iframes.
            var root = document.documentElement;
            if (window.MutationObserver && root && !root.__simulaNoScrollMO) {
              root.__simulaNoScrollMO = true;
              new MutationObserver(lockAll).observe(root, { childList: true, subtree: true });
            }
          } catch (e) {}
          // Belt-and-braces: sweep once more when parsing completes.
          try { document.addEventListener('DOMContentLoaded', lockAll); } catch (e) {}
        })();
        """

        static let heightReportingScript = """
        \(overflowLockScript)
        (function () {
          var lastH = 0, timer = null;
          function measure() {
            var b = document.body;
            if (!b) { var de = document.documentElement; return de ? de.scrollHeight : 0; }
            // The bottom of the lowest in-flow child = the creative's content height, independent of
            // the height the SDK gave the WebView. A full-height creative (html,body{height:100%} or
            // an inner 100%/100vh element) otherwise reports back the size we set, which feeds back
            // and grows the slot on every resize — the height:auto trick only neutralized html/body,
            // so inner full-height elements still looped. The card's content is top-packed in a flex
            // column, so the lowest child's bottom is the true height and never tracks our resize.
            // Mirrors the Android SDK's BRIDGE_SCRIPT measurement (cross-platform height parity).
            var max = 0, kids = b.children;
            for (var i = 0; i < kids.length; i++) {
              var bottom = kids[i].getBoundingClientRect().bottom;
              if (bottom > max) max = bottom;
            }
            max += (window.scrollY || window.pageYOffset || 0);
            var raw = Math.ceil(max) || b.scrollHeight;
            // Viewport-echo guard: a 100%/100vh child (or a child-less full-height body, where the
            // scrollHeight fallback kicks in) doesn't measure content — it reflects whatever height
            // the SDK just gave the WebView. Adding the +1 cushion to that echo would ratchet the
            // slot +1pt per resize forever (measure -> +1 -> resize -> measure...). Report the echo
            // verbatim instead: identical to lastH, so the loop terminates.
            var vh = window.innerHeight || 0;
            if (vh > 0 && Math.abs(raw - vh) <= 2) return vh;
            // +1pt cushion so sub-pixel layout can't leave contentSize > bounds (tiny bottom scroll).
            return raw + 1;
          }
          function send() {
            try {
              var h = measure();
              if (h > 0 && Math.abs(h - lastH) >= 1 &&
                  window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.simulaSDK) {
                lastH = h;
                window.webkit.messageHandlers.simulaSDK.postMessage(JSON.stringify({ type: 'SIMULA_AD_HEIGHT', height: h }));
              }
            } catch (e) {}
          }
          // Debounced so a creative that animates / settles its layout posts a stable height instead
          // of streaming intermediate values that would thrash the host feed's layout.
          function post() { if (timer) clearTimeout(timer); timer = setTimeout(send, 80); }
          send();
          window.addEventListener('resize', post);
          try {
            if (window.ResizeObserver) {
              var ro = new ResizeObserver(function () { post(); });
              if (document.documentElement) ro.observe(document.documentElement);
              if (document.body) ro.observe(document.body);
            }
          } catch (e) {}
        })();
        """
    }
}

// MARK: - VisibilityRelay

/// Throttling channel that forwards a native slot's live visible fraction (0..1) to the creative's
/// `window.onVisibility`. Created per served slot by `NativeAdSlot`, bound to that slot's `WKWebView`
/// by `WebViewRepresentable` while mounted, and fed by `NativeAdViewabilityModifier` as the slot
/// scrolls. Rounds to ~1% and drops sub-1% changes so a high-frequency scroll can't flood the JS
/// bridge; guards on `window.onVisibility` existence so it's a no-op until the creative defines it.
/// All access is on the main thread (the SwiftUI viewability callbacks + representable lifecycle).
final class VisibilityRelay {
    private weak var webView: WKWebView?
    /// Last ratio actually pushed over the JS bridge (dedup baseline). -1 = nothing pushed yet.
    private var lastSent: CGFloat = -1
    /// Latest ratio the viewability modifier reported, whether or not the push reached the page.
    /// -1 = no geometry sample yet.
    private var latest: CGFloat = -1

    /// Point the relay at the live `WKWebView` (or `nil` to detach on teardown).
    func bind(_ webView: WKWebView?) {
        self.webView = webView
        lastSent = -1
    }

    /// Forward a 0..1 ratio to the creative, de-duped against the last forwarded value (~1%
    /// granularity). Guarded so it's a no-op until `window.onVisibility` is defined.
    func report(_ ratio: CGFloat) {
        let r = min(1, max(0, ratio))
        latest = r
        if lastSent >= 0, abs(r - lastSent) < 0.01 { return }
        push(r)
    }

    /// Re-deliver the latest ratio unconditionally, bypassing the dedup. Called when the creative
    /// finishes loading: any `report` issued while the page was still loading was silently dropped
    /// by the `window.onVisibility&&…` guard (the function didn't exist yet) but still advanced the
    /// dedup baseline, so without this replay a creative that mounts off-screen never hears a
    /// ratio at all — and its no-bridge fallback animates the card before it scrolls into view.
    /// With no geometry sample yet, sends 0 ("bridge is live, not visible") so the creative arms
    /// its visibility gating instead of the fallback timer; the first real sample follows.
    func flush() {
        push(max(latest, 0))
    }

    /// Deterministic foreground wake-up (call on `UIApplication.willEnterForegroundNotification`
    /// while the slot is mounted). The creative (`character_ad.html`) can freeze mid-video/mid-typing
    /// when its WKWebView's content process was suspended while backgrounded, and its own
    /// `visibilitychange`/`pageshow`/`focus` listeners are not guaranteed to fire across that
    /// suspend. `evaluateJavaScript` reaches the page regardless, so this calls the creative's
    /// `onAppForeground` self-heal directly, then re-arms the dedupe and re-pushes the latest known
    /// ratio — the on-screen geometry is typically unchanged from before backgrounding, so without
    /// resetting `lastSent` the creative would never receive another `onVisibility` telling it the
    /// app (and thus playback) is live again.
    func resyncOnForeground() {
        webView?.evaluateJavaScript("window.onAppForeground&&window.onAppForeground()", completionHandler: nil)
        let previous = latest
        lastSent = -1
        if previous >= 0 { report(previous) }
    }

    private func push(_ r: CGFloat) {
        lastSent = r
        let s = String(format: "%.2f", r)
        webView?.evaluateJavaScript("window.onVisibility&&window.onVisibility(\(s))", completionHandler: nil)
    }
}

#elseif os(macOS)
import SwiftUI
import WebKit

// MARK: - WebViewRepresentable (macOS)

struct WebViewRepresentable: NSViewRepresentable {
    let url: URL?
    let htmlString: String?
    var baseURL: URL?
    var onNavigationCommitted: (() -> Void)?
    var onNavigationFinished: (() -> Void)?
    var onNavigationFailed: ((Error) -> Void)?
    var onMessageReceived: ((String) -> Void)?
    /// Accepted for signature parity with the iOS variant (the imperative HTML
    /// creative is iOS-only, so these are unused on macOS).
    var onAdClick: ((ClickInteraction) -> Void)?
    var onClickHandoffPendingChanged: ((Bool) -> Void)?
    var onAttributionRouteOutcome: ((AttributionRouteOutcome) -> Void)?
    var attributionRouteLifecycle: AttributionRouteLifecycle?
    var clickSource: ClickSource
    var clickBeaconImpressionId: String?
    var attribution: AdAttribution?
    var ctaTrackingUrl: String?
    var ctaDestination: AdDestination
    var ctaStoreOpen: StoreOpen
    var ctaStoreUrl: String?

    init(
        url: URL? = nil,
        htmlString: String? = nil,
        baseURL: URL? = nil,
        onNavigationCommitted: (() -> Void)? = nil,
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: ((Error) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil,
        onAdClick: ((ClickInteraction) -> Void)? = nil,
        onClickHandoffPendingChanged: ((Bool) -> Void)? = nil,
        onAttributionRouteOutcome: ((AttributionRouteOutcome) -> Void)? = nil,
        attributionRouteLifecycle: AttributionRouteLifecycle? = nil,
        clickSource: ClickSource = .primaryCTA,
        clickBeaconImpressionId: String? = nil,
        attribution: AdAttribution? = nil,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil
    ) {
        self.url = url
        self.htmlString = htmlString
        self.baseURL = baseURL
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onMessageReceived = onMessageReceived
        self.onAdClick = onAdClick
        self.onClickHandoffPendingChanged = onClickHandoffPendingChanged
        self.onAttributionRouteOutcome = onAttributionRouteOutcome
        self.attributionRouteLifecycle = attributionRouteLifecycle
        self.clickSource = clickSource
        self.clickBeaconImpressionId = clickBeaconImpressionId
        self.attribution = attribution
        self.ctaTrackingUrl = ctaTrackingUrl
        self.ctaDestination = ctaDestination
        self.ctaStoreOpen = ctaStoreOpen
        self.ctaStoreUrl = ctaStoreUrl
    }

    init(
        url: URL? = nil,
        htmlString: String? = nil,
        baseURL: URL? = nil,
        onNavigationCommitted: (() -> Void)? = nil,
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: ((Error) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil,
        onAdClick: (() -> Void)?,
        onClickHandoffPendingChanged: ((Bool) -> Void)? = nil,
        onAttributionRouteOutcome: ((AttributionRouteOutcome) -> Void)? = nil,
        attributionRouteLifecycle: AttributionRouteLifecycle? = nil,
        attribution: AdAttribution? = nil,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil
    ) {
        self.init(
            url: url,
            htmlString: htmlString,
            baseURL: baseURL,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMessageReceived: onMessageReceived,
            onAdClick: onAdClick.map { callback in { _ in callback() } },
            onClickHandoffPendingChanged: onClickHandoffPendingChanged,
            onAttributionRouteOutcome: onAttributionRouteOutcome,
            attributionRouteLifecycle: attributionRouteLifecycle,
            attribution: attribution,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreOpen: ctaStoreOpen,
            ctaStoreUrl: ctaStoreUrl
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "simulaSDK")

        let postMessageScript = WKUserScript(
            source: """
            window.addEventListener('message', function(event) {
                if (event.data && event.data.__simulaSdkResponse) { return; }
                if (event.data && typeof event.data === 'string') {
                    window.webkit.messageHandlers.simulaSDK.postMessage(event.data);
                } else if (event.data && typeof event.data === 'object') {
                    window.webkit.messageHandlers.simulaSDK.postMessage(JSON.stringify(event.data));
                }
            });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(postMessageScript)
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let currentURL = context.coordinator.currentURL
        let currentHTML = context.coordinator.currentHTML

        if let url = url, url != currentURL {
            context.coordinator.currentURL = url
            context.coordinator.currentHTML = nil
            webView.load(URLRequest(url: url))
        } else if let html = htmlString, html != currentHTML {
            context.coordinator.currentHTML = html
            context.coordinator.currentURL = nil
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMessageReceived: onMessageReceived
        )
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var onNavigationCommitted: (() -> Void)?
        var onNavigationFinished: (() -> Void)?
        var onNavigationFailed: ((Error) -> Void)?
        var onMessageReceived: ((String) -> Void)?
        var currentURL: URL?
        var currentHTML: String?
        private var mainFrameHTTPFailed = false

        private let internalSchemes: Set<String> = ["about", "data", "blob"]

        init(
            onNavigationCommitted: (() -> Void)?,
            onNavigationFinished: (() -> Void)?,
            onNavigationFailed: ((Error) -> Void)?,
            onMessageReceived: ((String) -> Void)?
        ) {
            self.onNavigationCommitted = onNavigationCommitted
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMessageReceived = onMessageReceived
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            mainFrameHTTPFailed = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !mainFrameHTTPFailed else { return }
            onNavigationFinished?()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard !mainFrameHTTPFailed else { return }
            onNavigationCommitted?()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(.allow)
            guard navigationResponse.isForMainFrame,
                  let http = navigationResponse.response as? HTTPURLResponse,
                  http.statusCode >= 400 else { return }
            mainFrameHTTPFailed = true
            onNavigationFailed?(NSError(domain: "SimulaWebView", code: http.statusCode))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onNavigationFailed?(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onNavigationFailed?(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""

            if internalSchemes.contains(scheme) {
                decisionHandler(.allow)
                return
            }

            if scheme == "javascript" {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame.map(\.isMainFrame) != true {
                if scheme == "http" || scheme == "https" {
                    if url == currentURL {
                        decisionHandler(.allow)
                        return
                    }
                    if navigationAction.navigationType == .other || navigationAction.navigationType == .formSubmitted {
                        NSWorkspace.shared.open(url)
                        decisionHandler(.cancel)
                        return
                    }
                }
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "http" || scheme == "https" {
                    NSWorkspace.shared.open(url)
                }
            }
            return nil
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if let body = message.body as? String {
                onMessageReceived?(body)
            }
        }
    }
}
#endif
