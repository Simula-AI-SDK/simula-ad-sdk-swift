#if os(iOS)
import SwiftUI
import WebKit
import StoreKit
import SafariServices

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

    /// Called when the web view finishes loading content
    var onNavigationFinished: (() -> Void)?

    /// Called when the web view fails to load content
    var onNavigationFailed: ((Error) -> Void)?

    /// Called when the web view receives a postMessage from JavaScript
    var onMessageReceived: ((String) -> Void)?

    /// Called when a user-initiated link inside the content is intercepted for
    /// routing (App Store / cross-domain click-through). Lets the imperative HTML
    /// creative emit CLICKED. `nil` for the declarative game iframe (no behavior change).
    var onAdClick: (() -> Void)?

    /// The WebView ↔ SDK bridge (PRD §3). When set, `window.postMessage` envelopes from the
    /// creative are routed to it (and `GET_*` replies are posted back via the web view). `nil`
    /// for the game iframe / previews, which keep the plain `onMessageReceived` path.
    var bridge: CreativeBridge?

    /// Ad-network attribution tokens carried into the in-app store sheet for click-through / auto-redirect
    /// CTAs (so the SKAN install postback credits the campaign). Set for the imperative HTML creative;
    /// `nil` for the game iframe / previews (no attribution to apply).
    var attribution: AdAttribution?

    /// Native-ad mode: open any user-activated navigation that leaves the page in the **external**
    /// system browser (Safari/Chrome) instead of the in-app store / SFSafari sheet (PRD). `false`
    /// for the interstitial HTML creative / game iframe — their behavior is unchanged.
    var externalClickOnly: Bool

    /// Native-ad mode: the server's MMP click-tracking URL a CTA tap should open (preferred over the
    /// URL the creative itself navigates to, so the click is attributed exactly like the imperative
    /// ads), and where it routes (`.appstore` resolves the redirect chain to the App Store; `.web`
    /// opens the link directly). A `nil`/empty tracker falls back to the in-creative URL. Ignored
    /// unless `externalClickOnly` is set.
    var ctaTrackingUrl: String?
    var ctaDestination: AdDestination

    /// Native-ad mode: after load, inject a script that reports the creative's content height over
    /// the JS bridge (`{type:"SIMULA_AD_HEIGHT", height}`) so the slot can size its container.
    var reportsContentHeight: Bool

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
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: ((Error) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil,
        onAdClick: (() -> Void)? = nil,
        bridge: CreativeBridge? = nil,
        attribution: AdAttribution? = nil,
        externalClickOnly: Bool = false,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        reportsContentHeight: Bool = false,
        telemetryAdFormat: String? = nil,
        visibilityRelay: VisibilityRelay? = nil
    ) {
        self.url = url
        self.htmlString = htmlString
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onMessageReceived = onMessageReceived
        self.onAdClick = onAdClick
        self.bridge = bridge
        self.attribution = attribution
        self.externalClickOnly = externalClickOnly
        self.ctaTrackingUrl = ctaTrackingUrl
        self.ctaDestination = ctaDestination
        self.reportsContentHeight = reportsContentHeight
        self.telemetryAdFormat = telemetryAdFormat
        self.visibilityRelay = visibilityRelay
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
        let webView = WebViewPool.shared.acquire(
            delegate: coordinator,
            onMessage: { [weak coordinator] body in coordinator?.handleMessage(body) }
        )
        // The coordinator needs the web view to post `GET_*` replies back into the page.
        coordinator.webView = webView
        // Point the visibility relay at this acquired view so scroll-driven `window.onVisibility`
        // pushes reach it; held on the coordinator so dismantle can unbind. No-op when unset.
        coordinator.visibilityRelay = visibilityRelay
        visibilityRelay?.bind(webView)
        // A native ad sizes to content and is not scrollable (PRD); disabling the inner scroll keeps
        // it from intercepting the host feed's scroll. Set per-acquire since the pool reuses views.
        webView.scrollView.isScrollEnabled = !reportsContentHeight
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only load if URL/HTML changed
        let currentURL = context.coordinator.currentURL
        let currentHTML = context.coordinator.currentHTML

        if let url = url, url != currentURL {
            context.coordinator.currentURL = url
            context.coordinator.currentHTML = nil
            let request = URLRequest(url: url)
            webView.load(request)
        } else if let html = htmlString, html != currentHTML {
            context.coordinator.currentHTML = html
            context.coordinator.currentURL = nil
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Return the web view to the pool when SwiftUI tears this representable down,
    /// so the (expensive) WKWebView + its Web Content process is recycled for the
    /// next acquire instead of being deallocated.
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // Stop forwarding visibility into a view that's about to be recycled by the pool.
        coordinator.visibilityRelay?.bind(nil)
        WebViewPool.shared.release(uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMessageReceived: onMessageReceived,
            onAdClick: onAdClick,
            bridge: bridge,
            attribution: attribution,
            externalClickOnly: externalClickOnly,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            reportsContentHeight: reportsContentHeight,
            telemetryAdFormat: telemetryAdFormat
        )
    }

    // MARK: - Coordinator

    @preconcurrency
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var onNavigationFinished: (() -> Void)?
        var onNavigationFailed: ((Error) -> Void)?
        var onMessageReceived: ((String) -> Void)?
        var onAdClick: (() -> Void)?
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
        var reportsContentHeight: Bool
        /// Ad-format tag for WebView telemetry; nil → untagged.
        var telemetryAdFormat: String?
        /// Native-ad visibility relay (set on acquire); used to unbind on dismantle. See `VisibilityRelay`.
        var visibilityRelay: VisibilityRelay?
        /// Monotonic page-load start (set on provisional navigation start) for `webview_page_load`.
        private var pageStartUptime: TimeInterval?

        /// Tracks the currently loaded URL to avoid redundant loads
        var currentURL: URL?
        /// Tracks the currently loaded HTML to avoid redundant loads
        var currentHTML: String?

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
            onNavigationFinished: (() -> Void)?,
            onNavigationFailed: ((Error) -> Void)?,
            onMessageReceived: ((String) -> Void)?,
            onAdClick: (() -> Void)? = nil,
            bridge: CreativeBridge? = nil,
            attribution: AdAttribution? = nil,
            externalClickOnly: Bool = false,
            ctaTrackingUrl: String? = nil,
            ctaDestination: AdDestination = .appstore,
            reportsContentHeight: Bool = false,
            telemetryAdFormat: String? = nil
        ) {
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMessageReceived = onMessageReceived
            self.onAdClick = onAdClick
            self.bridge = bridge
            self.attribution = attribution
            self.externalClickOnly = externalClickOnly
            self.ctaTrackingUrl = ctaTrackingUrl
            self.ctaDestination = ctaDestination
            self.reportsContentHeight = reportsContentHeight
            self.telemetryAdFormat = telemetryAdFormat
        }

        /// Routes a `window.postMessage` envelope from the creative: to the bridge (PRD §3)
        /// when one is attached — which posts `GET_*` replies back via this web view — else to
        /// the legacy `onMessageReceived` callback (game iframe).
        func handleMessage(_ body: String) {
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

        /// Native-ad CTA routing (`externalClickOnly`). Default: opens the server's MMP tracking URL
        /// **externally** — `.appstore` resolves the click-attribution redirect chain to the App Store,
        /// `.web` opens the link directly — falling back to `fallback` (the URL the creative itself
        /// navigated to) when the serve carried no tracker.
        ///
        /// SKAN parity with interstitial/rewarded: when the serve carries usable `skan_attribution`
        /// tokens AND the CTA is an App Store destination, the click instead routes through the **in-app**
        /// `SKStoreProductViewController`, so the tokens ride the StoreKit-rendered sheet and the SKAN
        /// install postback credits the campaign (StoreKit tokens can't ride an external open). Absent /
        /// token-less attribution, or a `.web` destination, keeps today's external behavior unchanged.
        private func openNativeCTA(fallback: URL) {
            let tracking = ctaTrackingUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trackingURL = (tracking?.isEmpty == false) ? URL(string: tracking!) : nil
            let destination = ctaDestination
            let attribution = self.attribution
            Task { @MainActor in
                if destination == .appstore, attribution?.hasUsableTokens == true {
                    // In-app store sheet carrying the SKAN/App-Analytics tokens (parity with the
                    // imperative formats). Prefers the tracker (router resolves it to the store), else
                    // the in-creative URL.
                    CreativeCTARouter.open(
                        trackingUrl: (trackingURL ?? fallback).absoluteString,
                        destination: destination,
                        storeOpen: .skstoreproduct,
                        attribution: attribution
                    )
                } else if let trackingURL {
                    CreativeCTARouter.openExternally(initialURL: trackingURL, destination: destination)
                } else {
                    UIApplication.shared.open(fallback)
                }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // Start the page-load timer for the real content load (ignore the prewarm about:blank).
            if webView.url?.absoluteString == "about:blank" { return }
            pageStartUptime = ProcessInfo.processInfo.systemUptime
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Ignore the pool's prewarm load — only the real content load counts.
            if webView.url?.absoluteString == "about:blank" { return }
            // webview_page_load timing (best-effort; Tier 3 diagnostics).
            if let start = pageStartUptime {
                pageStartUptime = nil
                Telemetry.shared.recordLifecycle(
                    stage: "webview_page_load", adFormat: telemetryAdFormat, adUnitId: nil, adId: nil,
                    serveId: nil, durationMs: Int((ProcessInfo.processInfo.systemUptime - start) * 1000), errorCode: nil
                )
            }
            onNavigationFinished?()
            // Native ad: start reporting content height so the slot can size its container.
            if reportsContentHeight {
                webView.evaluateJavaScript(Coordinator.heightReportingScript, completionHandler: nil)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The creative's web-content process crashed/was jettisoned. Record it; the SDK survives
            // (WKWebView is sandboxed, so the host app is never taken down with it).
            Telemetry.shared.recordError(
                signature: "webview:render_gone",
                errorCode: "render_terminated",
                breadcrumb: telemetryAdFormat
            )
            // Native ad: a terminated render leaves nothing to show, so collapse the slot to zero
            // height (parity with a load failure) instead of holding the provisional block. Gated to
            // the native, content-sized path — the full-screen creatives don't size to content.
            if reportsContentHeight {
                onNavigationFailed?(NSError(domain: "SimulaWebView", code: NSURLErrorCannotDecodeContentData))
            }
        }

        // An HTTP error status on the creative's main-frame load (e.g. the iframe URL 404s/500s) still
        // reports as a successful navigation on WKWebView — it renders the error body and never hits
        // didFail. Mirror Android's onReceivedHttpError: for the native path, treat a main-frame
        // 4xx/5xx as a load failure so the slot collapses instead of holding a blank reserved block.
        // Allow the response (the slot tears the WebView down on collapse); gated to the native path
        // so full-screen creatives are unaffected.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(.allow)
            guard reportsContentHeight, navigationResponse.isForMainFrame,
                  let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 else {
                return
            }
            onNavigationFailed?(NSError(domain: "SimulaWebView", code: http.statusCode))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if isCancelled(error) { return }
            onNavigationFailed?(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // A cancelled provisional load happens when the real URL supersedes
            // the prewarm's about:blank load; it isn't a genuine failure.
            if isCancelled(error) { return }
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

            // Native ad: a user-activated navigation that leaves the page opens in the EXTERNAL
            // system browser (PRD) — never the in-app store/SFSafari sheet. Subresource and
            // server-redirect navigations (.other) pass through so the creative loads normally.
            if externalClickOnly {
                if navigationAction.navigationType == .linkActivated,
                   scheme == "http" || scheme == "https" || scheme == "itms-apps" || scheme == "itms" {
                    onAdClick?()
                    // Prefer the server tracking URL (attribution-preserving); fall back to the tapped URL.
                    openNativeCTA(fallback: url)
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
                if navigationAction.navigationType == .linkActivated { onAdClick?() }
                let attribution = self.attribution
                Task { @MainActor in CreativeCTARouter.presentStoreProduct(appID: appID, attribution: attribution) }
                decisionHandler(.cancel)
                return
            }

            // Intercept itms-apps:// and itms:// schemes (direct App Store links)
            if scheme == "itms-apps" || scheme == "itms" {
                if navigationAction.navigationType == .linkActivated { onAdClick?() } // CLICKED, user-activated only
                if let appID = appStoreID(from: url) {
                    let attribution = self.attribution
                    Task { @MainActor in CreativeCTARouter.presentStoreProduct(appID: appID, attribution: attribution) }
                } else {
                    // Couldn't extract app ID — let the system handle it
                    Task { @MainActor in UIApplication.shared.open(url) }
                }
                decisionHandler(.cancel)
                return
            }

            // User-initiated cross-domain clicks → resolve redirect chain first,
            // then open SKStoreProductViewController (App Store) or SFSafariViewController (other)
            if navigationAction.navigationType == .linkActivated,
               scheme == "http" || scheme == "https" {
                let currentHost = currentURL?.host?.lowercased() ?? ""
                let targetHost = url.host?.lowercased() ?? ""
                if !targetHost.isEmpty && currentHost != targetHost {
                    onAdClick?() // CLICKED (HTML creative); nil for the game iframe.
                    let attribution = self.attribution
                    Task { @MainActor in CreativeCTARouter.resolveAndRoute(url: url, attribution: attribution) }
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
                let scheme = url.scheme?.lowercased() ?? ""
                // Native ad: target="_blank" / window.open → external browser (PRD).
                if externalClickOnly {
                    if scheme == "http" || scheme == "https" {
                        onAdClick?()
                        // Prefer the server tracking URL (attribution-preserving); fall back to this URL.
                        openNativeCTA(fallback: url)
                    }
                    return nil
                }
                if scheme == "http" || scheme == "https" {
                    let currentHost = currentURL?.host?.lowercased() ?? ""
                    let targetHost = url.host?.lowercased() ?? ""
                    if !targetHost.isEmpty && currentHost != targetHost {
                        // Cross-domain → resolve redirects then route. Router entry
                        // point is `@MainActor`; this delegate runs on main, so hop
                        // explicitly rather than asserting isolation. `createWebViewWith`
                        // is only invoked for user-initiated new-window requests
                        // (target="_blank" / window.open), so this is a real click.
                        onAdClick?() // CLICKED (HTML creative); nil for the game iframe.
                        let attribution = self.attribution
                        Task { @MainActor in CreativeCTARouter.resolveAndRoute(url: url, attribution: attribution) }
                    } else {
                        // Same-origin → load in webview
                        webView.load(URLRequest(url: url))
                    }
                }
            }
            return nil
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if let body = message.body as? String {
                handleMessage(body)
            } else if let dict = message.body as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      let str = String(data: data, encoding: .utf8) {
                handleMessage(str)
            }
        }

        /// Injected (via `evaluateJavaScript`) after a native-ad creative loads: posts the content
        /// height to native (over the pool's `simulaSDK` channel) on load + whenever it changes, so
        /// the slot resizes to fit. A `<meta viewport width=device-width,initial-scale=1>` creative
        /// maps 1 CSS px → 1 point, so the reported value is used directly as the SwiftUI height.
        static let heightReportingScript = """
        (function () {
          var lastH = 0, timer = null;
          function measure() {
            var de = document.documentElement, b = document.body;
            if (!b) return de ? de.scrollHeight : 0;
            // Measure the creative's NATURAL content height, independent of the height the SDK gave the
            // WebView. A full-height creative (html,body{height:100%}) otherwise reports back the size we
            // set, which feeds back and grows the slot on every resize. Forcing height:auto for the
            // measurement (restored synchronously, before any paint) reads the true content height.
            var prevDe = de.style.height, prevB = b.style.height;
            de.style.height = 'auto';
            b.style.height = 'auto';
            var h = Math.max(de.scrollHeight, b.scrollHeight);
            de.style.height = prevDe;
            b.style.height = prevB;
            return h;
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
    private var last: CGFloat = -1

    /// Point the relay at the live `WKWebView` (or `nil` to detach on teardown).
    func bind(_ webView: WKWebView?) {
        self.webView = webView
        last = -1
    }

    /// Forward a 0..1 ratio to the creative, de-duped against the last forwarded value (~1%
    /// granularity). Guarded so it's a no-op until `window.onVisibility` is defined.
    func report(_ ratio: CGFloat) {
        let r = min(1, max(0, ratio))
        if last >= 0, abs(r - last) < 0.01 { return }
        last = r
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
    var onNavigationFinished: (() -> Void)?
    var onNavigationFailed: ((Error) -> Void)?
    var onMessageReceived: ((String) -> Void)?
    /// Accepted for signature parity with the iOS variant (the imperative HTML
    /// creative is iOS-only, so this is unused on macOS).
    var onAdClick: (() -> Void)?

    init(
        url: URL? = nil,
        htmlString: String? = nil,
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: ((Error) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil,
        onAdClick: (() -> Void)? = nil
    ) {
        self.url = url
        self.htmlString = htmlString
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onMessageReceived = onMessageReceived
        self.onAdClick = onAdClick
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
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMessageReceived: onMessageReceived
        )
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var onNavigationFinished: (() -> Void)?
        var onNavigationFailed: ((Error) -> Void)?
        var onMessageReceived: ((String) -> Void)?
        var currentURL: URL?
        var currentHTML: String?

        private let internalSchemes: Set<String> = ["about", "data", "blob"]

        init(
            onNavigationFinished: (() -> Void)?,
            onNavigationFailed: ((Error) -> Void)?,
            onMessageReceived: ((String) -> Void)?
        ) {
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMessageReceived = onMessageReceived
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigationFinished?()
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
