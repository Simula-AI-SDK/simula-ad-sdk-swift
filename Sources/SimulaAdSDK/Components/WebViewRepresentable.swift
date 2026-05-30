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

    init(
        url: URL? = nil,
        htmlString: String? = nil,
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: ((Error) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil
    ) {
        self.url = url
        self.htmlString = htmlString
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onMessageReceived = onMessageReceived
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
        return WebViewPool.shared.acquire(
            delegate: coordinator,
            onMessage: { [weak coordinator] body in coordinator?.onMessageReceived?(body) }
        )
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

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMessageReceived: onMessageReceived
        )
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, SKStoreProductViewControllerDelegate {
        var onNavigationFinished: (() -> Void)?
        var onNavigationFailed: ((Error) -> Void)?
        var onMessageReceived: ((String) -> Void)?

        /// Tracks the currently loaded URL to avoid redundant loads
        var currentURL: URL?
        /// Tracks the currently loaded HTML to avoid redundant loads
        var currentHTML: String?

        /// Schemes that should be handled within the webview
        private let internalSchemes: Set<String> = ["about", "data", "blob"]

        /// Extracts App Store ID from URLs like:
        /// - https://apps.apple.com/app/id123456789
        /// - https://itunes.apple.com/app/id123456789
        /// - itms-apps://apps.apple.com/app/id123456789
        /// - itms-apps://itunes.apple.com/app/id123456789
        // Precompiled once — `range(of:options:.regularExpression)` would compile
        // the pattern on every navigation. Group 1 captures the numeric ID.
        private static let appStoreIDRegex = try! NSRegularExpression(pattern: #"id(\d+)"#)
        private static let appStorePathIDRegex = try! NSRegularExpression(pattern: #"/id(\d+)"#)

        private func capturedID(_ regex: NSRegularExpression, in string: String) -> String? {
            let range = NSRange(string.startIndex..., in: string)
            guard let match = regex.firstMatch(in: string, range: range),
                  match.numberOfRanges >= 2,
                  let idRange = Range(match.range(at: 1), in: string) else {
                return nil
            }
            return String(string[idRange])
        }

        private func appStoreID(from url: URL) -> String? {
            let scheme = url.scheme?.lowercased() ?? ""
            let host = url.host?.lowercased() ?? ""

            // For itms-apps:// and itms:// schemes, search the path for /id\d+
            // regardless of host (these are always App Store URLs)
            if scheme == "itms-apps" || scheme == "itms" {
                return capturedID(Self.appStoreIDRegex, in: url.absoluteString)
            }

            // For http/https, require known App Store hosts
            guard host.contains("apps.apple.com") || host.contains("itunes.apple.com") else {
                return nil
            }
            return capturedID(Self.appStorePathIDRegex, in: url.path)
        }

        private static var coordinatorKey: UInt8 = 0
        private var isShowingStoreProduct = false

        /// Presents SKStoreProductViewController in-app for the given App Store ID
        private func presentStoreProduct(appID: String) {
            guard !isShowingStoreProduct else { return }
            isShowingStoreProduct = true
            let storeVC = SKStoreProductViewController()
            storeVC.delegate = self
            objc_setAssociatedObject(storeVC, &Self.coordinatorKey, self, .OBJC_ASSOCIATION_RETAIN)
            storeVC.loadProduct(withParameters: [
                SKStoreProductParameterITunesItemIdentifier: NSNumber(value: Int(appID) ?? 0)
            ])
            presentViewController(storeVC)
        }

        // MARK: - SKStoreProductViewControllerDelegate

        func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
            isShowingStoreProduct = false
            viewController.dismiss(animated: true)
        }

        /// Presents SFSafariViewController for external links
        private func presentSafari(url: URL) {
            let safariVC = SFSafariViewController(url: url)
            presentViewController(safariVC)
        }

        private func presentViewController(_ vc: UIViewController) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(vc, animated: true)
        }

        /// Follows HTTP redirect chain to determine the final destination.
        /// If it resolves to an App Store URL → SKStoreProductViewController.
        /// Otherwise → SFSafariViewController with the final URL.
        private func resolveAndRoute(url: URL) {
            // Quick check — already an App Store URL?
            if let appID = appStoreID(from: url) {
                presentStoreProduct(appID: appID)
                return
            }

            let resolver = RedirectResolver { [weak self] finalURL in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let appID = self.appStoreID(from: finalURL) {
                        self.presentStoreProduct(appID: appID)
                    } else {
                        self.presentSafari(url: finalURL)
                    }
                    // Release the resolver and its (now-invalidated) session.
                    self.activeResolver = nil
                }
            }
            // Keep a strong reference so it isn't deallocated during the request
            self.activeResolver = resolver
            let session = URLSession(configuration: .default, delegate: resolver, delegateQueue: nil)
            resolver.session = session
            session.dataTask(with: URLRequest(url: url)).resume()
        }

        private var activeResolver: RedirectResolver?

        init(
            onNavigationFinished: (() -> Void)?,
            onNavigationFailed: ((Error) -> Void)?,
            onMessageReceived: ((String) -> Void)?
        ) {
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMessageReceived = onMessageReceived
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

            // Intercept App Store URLs → show in-app store sheet
            if let appID = appStoreID(from: url) {
                presentStoreProduct(appID: appID)
                decisionHandler(.cancel)
                return
            }

            // Intercept itms-apps:// and itms:// schemes (direct App Store links)
            if scheme == "itms-apps" || scheme == "itms" {
                if let appID = appStoreID(from: url) {
                    presentStoreProduct(appID: appID)
                } else {
                    // Couldn't extract app ID — let the system handle it
                    UIApplication.shared.open(url)
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
                    resolveAndRoute(url: url)
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
                        // Cross-domain → resolve redirects then route
                        resolveAndRoute(url: url)
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
                onMessageReceived?(body)
            } else if let dict = message.body as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      let str = String(data: data, encoding: .utf8) {
                onMessageReceived?(str)
            }
        }
    }
}

// MARK: - RedirectResolver

/// URLSession delegate that follows HTTP redirect chains and stops when it
/// encounters an App Store URL or non-HTTP scheme. Used to pre-resolve
/// AppsFlyer/onelink redirects before deciding whether to show
/// SKStoreProductViewController or SFSafariViewController.
private class RedirectResolver: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    let completion: (URL) -> Void
    /// The session driving this resolution. Held so it can be invalidated on
    /// completion: a delegate-based URLSession otherwise retains its delegate
    /// (and an operation-queue thread) indefinitely until `invalidate` is called.
    var session: URLSession?
    private var completed = false

    init(completion: @escaping (URL) -> Void) {
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url else {
            finish(with: task.currentRequest?.url ?? request.url!)
            completionHandler(nil)
            return
        }

        let scheme = redirectURL.scheme?.lowercased() ?? ""
        let host = redirectURL.host?.lowercased() ?? ""

        // Stop at App Store URLs or non-HTTP schemes
        if host.contains("apps.apple.com") || host.contains("itunes.apple.com")
            || scheme == "itms-apps" || scheme == "itms" {
            finish(with: redirectURL)
            completionHandler(nil)
            return
        }

        // Continue following redirect chain
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Chain completed (no more redirects) — use the final URL
        if let finalURL = task.currentRequest?.url {
            finish(with: finalURL)
        }
    }

    private func finish(with url: URL) {
        guard !completed else { return }
        completed = true
        // Allow the in-flight task to finish, then tear down the session so its
        // delegate (self) and backing thread are released.
        session?.finishTasksAndInvalidate()
        completion(url)
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

    init(
        url: URL? = nil,
        htmlString: String? = nil,
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: ((Error) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil
    ) {
        self.url = url
        self.htmlString = htmlString
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onMessageReceived = onMessageReceived
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "simulaSDK")

        let postMessageScript = WKUserScript(
            source: """
            window.addEventListener('message', function(event) {
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
