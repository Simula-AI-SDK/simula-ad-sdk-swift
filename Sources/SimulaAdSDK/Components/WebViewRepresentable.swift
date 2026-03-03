#if os(iOS)
import SwiftUI
import WebKit

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
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Add message handler for game→SDK communication (equivalent to window.postMessage listener)
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "simulaSDK")

        // Inject a script that forwards window.postMessage to our handler
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
        webView.scrollView.isScrollEnabled = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // Match the iframe sandbox attributes from React:
        // sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-forms"
        // WKWebView handles these by default; scripts and forms are always allowed.

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

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMessageReceived: onMessageReceived
        )
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onNavigationFinished: (() -> Void)?
        var onNavigationFailed: ((Error) -> Void)?
        var onMessageReceived: ((String) -> Void)?

        /// Tracks the currently loaded URL to avoid redundant loads
        var currentURL: URL?
        /// Tracks the currently loaded HTML to avoid redundant loads
        var currentHTML: String?

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
            onNavigationFinished?()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onNavigationFailed?(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onNavigationFailed?(error)
        }

        // Allow navigation to external URLs (for ad click-throughs)
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Open external links in the system browser (like target="_blank" in React iframes)
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
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

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onNavigationFinished: (() -> Void)?
        var onNavigationFailed: ((Error) -> Void)?
        var onMessageReceived: ((String) -> Void)?
        var currentURL: URL?
        var currentHTML: String?

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
