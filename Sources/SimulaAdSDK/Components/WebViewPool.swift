#if os(iOS)
import WebKit

// MARK: - MessageForwarder

/// A stable `WKScriptMessageHandler` installed on a web view at creation time.
///
/// A web view is prewarmed *before* the per-instance coordinator that ultimately
/// wants its messages exists, so we can't register the coordinator directly.
/// Instead we register this forwarder up front (the only reliable way to attach a
/// handler is before the web view is created) and simply repoint its `onMessage`
/// closure when the view is handed out. The closure captures the coordinator
/// weakly, so it introduces no retain cycle through the content controller.
final class WebViewMessageForwarder: NSObject, WKScriptMessageHandler {
    var onMessage: ((String) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let body = message.body as? String {
            onMessage?(body)
        } else if let dict = message.body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let str = String(data: data, encoding: .utf8) {
            onMessage?(str)
        }
    }
}

// MARK: - WebViewPool

/// Prewarms and reuses `WKWebView` instances to keep the cold-start cost off the
/// ad path.
///
/// The first `WKWebView` an app creates is expensive: it allocates the view,
/// initializes WebKit, and brings up a Web Content process. By creating a web
/// view *before* the user taps a game (when the menu opens), that cost overlaps
/// with menu browsing and the `getMinigame` network round-trip instead of being
/// paid serially right before the game must appear. All web views also share a
/// single `WKProcessPool` so they reuse process infrastructure.
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()

    /// JS → native channel name. Must match the injected script below.
    static let messageHandlerName = "simulaSDK"

    /// Shared so every SDK web view reuses one Web Content process pool rather
    /// than each spinning up its own.
    private let processPool = WKProcessPool()

    private struct Pooled {
        let webView: WKWebView
        let forwarder: WebViewMessageForwarder
    }
    private var idle: [Pooled] = []

    /// How many warm web views to keep on hand. The game and post-game ad are
    /// shown sequentially, so a small buffer is enough; `acquire` refills.
    private let maxIdle = 2

    private init() {}

    /// Forwards `window.postMessage` payloads to the native message handler.
    /// Installed once per web view at creation time.
    private static let postMessageScript = WKUserScript(
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

    private func makePooled() -> Pooled {
        let forwarder = WebViewMessageForwarder()

        let controller = WKUserContentController()
        controller.add(forwarder, name: WebViewPool.messageHandlerName)
        controller.addUserScript(WebViewPool.postMessageScript)

        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        return Pooled(webView: webView, forwarder: forwarder)
    }

    /// Create a warm web view ahead of time, if the pool has room. Loads
    /// `about:blank` to bring up the Web Content process so the later real load
    /// starts warm. The coordinator ignores `about:blank` navigations, so this
    /// never reaches the consumer's load callbacks.
    func prewarm() {
        guard idle.count < maxIdle else { return }
        SimulaTelemetry.shared.startSpan("WKWebViewPrewarm")
        let pooled = makePooled()
        if let blank = URL(string: "about:blank") {
            pooled.webView.load(URLRequest(url: blank))
        }
        idle.append(pooled)
        SimulaTelemetry.shared.endSpan("WKWebViewPrewarm", additionalInfo: "idle: \(idle.count)")
    }

    /// Returns a web view wired to `delegate` and `onMessage`, reusing a
    /// prewarmed one when available. Schedules a refill so the next acquire is
    /// also warm. `wasPooled` indicates whether a warm view was reused.
    func acquire(
        delegate: WKNavigationDelegate & WKUIDelegate,
        onMessage: @escaping (String) -> Void
    ) -> (webView: WKWebView, wasPooled: Bool) {
        let wasPooled = !idle.isEmpty
        let pooled = idle.popLast() ?? makePooled()

        pooled.forwarder.onMessage = onMessage
        pooled.webView.navigationDelegate = delegate
        pooled.webView.uiDelegate = delegate

        // Refill on the next runloop turn so this acquire returns immediately and
        // the following one (e.g. the post-game ad) is also warm.
        Task { @MainActor [weak self] in self?.prewarm() }

        return (pooled.webView, wasPooled)
    }
}
#endif
