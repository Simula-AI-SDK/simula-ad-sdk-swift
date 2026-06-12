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

    /// Called (with the raw marker URL) when the creative navigates to a `simula://` end-screen marker,
    /// so the presenter can fire an `auto_store_redirect`. The navigation itself is consumed (never loaded).
    var onCreativeMarker: ((String) -> Void)?

    init(
        url: URL? = nil,
        htmlString: String? = nil,
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: ((Error) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil,
        onAdClick: (() -> Void)? = nil,
        bridge: CreativeBridge? = nil,
        attribution: AdAttribution? = nil,
        onCreativeMarker: ((String) -> Void)? = nil
    ) {
        self.url = url
        self.htmlString = htmlString
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onMessageReceived = onMessageReceived
        self.onAdClick = onAdClick
        self.bridge = bridge
        self.attribution = attribution
        self.onCreativeMarker = onCreativeMarker
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
            onCreativeMarker: onCreativeMarker
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
        /// Called when the creative navigates to a `simula://` end-screen marker (consumed, not loaded).
        var onCreativeMarker: ((String) -> Void)?
        /// The web view this coordinator drives — used to post `GET_*` replies back into the page.
        weak var webView: WKWebView?

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
            onCreativeMarker: ((String) -> Void)? = nil
        ) {
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMessageReceived = onMessageReceived
            self.onAdClick = onAdClick
            self.bridge = bridge
            self.attribution = attribution
            self.onCreativeMarker = onCreativeMarker
        }

        /// Routes a `window.postMessage` envelope from the creative: to the bridge (PRD §3)
        /// when one is attached — which posts `GET_*` replies back via this web view — else to
        /// the legacy `onMessageReceived` callback (game iframe).
        func handleMessage(_ body: String) {
            if let bridge {
                bridge.handle(body) { [weak self] js in
                    self?.webView?.evaluateJavaScript(js, completionHandler: nil)
                }
            } else {
                onMessageReceived?(body)
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Ignore the pool's prewarm load — only the real content load counts.
            if webView.url?.absoluteString == "about:blank" { return }
            onNavigationFinished?()
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

            // auto_store_redirect end-screen marker (simula://end-screen-1/2): the creative navigates
            // here when an end card renders. Consume the custom-scheme navigation (never load it) and
            // report the marker so the presenter can fire the redirect if its trigger matches.
            if scheme == "simula" {
                onCreativeMarker?(url.absoluteString)
                decisionHandler(.cancel)
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

            if navigationAction.targetFrame == nil || !navigationAction.targetFrame!.isMainFrame {
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
