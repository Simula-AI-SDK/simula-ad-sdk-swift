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
/// paid serially right before the game must appear.
///
/// (WebKit manages Web Content process sharing automatically on iOS 15+, so no
/// explicit `WKProcessPool` is needed — the win here is the prewarm handoff.)
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()

    /// JS → native channel name. Must match the injected script below.
    static let messageHandlerName = "simulaSDK"

    private struct Pooled {
        let webView: WKWebView
        let forwarder: WebViewMessageForwarder
        /// Whether this view was built with a persistent data store. Tracked so a
        /// consent change (which flips the storage policy) doesn't hand back a view
        /// with a stale policy.
        let persistent: Bool
    }
    private var idle: [Pooled] = []
    /// Views currently handed out to a representable, retained so `release` can
    /// reset and re-pool them on `dismantleUIView` (recycling) instead of letting
    /// them deallocate and tear down their Web Content process.
    private var active: [ObjectIdentifier: Pooled] = [:]

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
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = controller

        // Honor TCF Purpose 1 / GDPR: when on-device storage is not permitted, use a
        // non-persistent data store so cookies & localStorage stay in memory for the
        // session and nothing is written to disk. In-session functionality is intact.
        let persistent = SimulaPrivacy.shared.currentSnapshot.allowsLocalStorage
        if !persistent {
            config.websiteDataStore = .nonPersistent()
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        return Pooled(webView: webView, forwarder: forwarder, persistent: persistent)
    }

    /// Create a warm web view ahead of time, if the pool has room. Loads
    /// `about:blank` to bring up the Web Content process so the later real load
    /// starts warm. The coordinator ignores `about:blank` navigations, so this
    /// never reaches the consumer's load callbacks.
    func prewarm() {
        guard idle.count < maxIdle else { return }
        let pooled = makePooled()
        if let blank = URL(string: "about:blank") {
            pooled.webView.load(URLRequest(url: blank))
        }
        idle.append(pooled)
    }

    /// Returns a web view wired to `delegate` and `onMessage`, reusing a
    /// prewarmed one when available. Schedules a refill so the next acquire
    /// (e.g. the post-game ad) is also warm.
    func acquire(
        delegate: WKNavigationDelegate & WKUIDelegate,
        onMessage: @escaping (String) -> Void
    ) -> WKWebView {
        let startNanos = DispatchTime.now().uptimeNanoseconds
        // Drop any prewarmed views whose storage policy no longer matches the
        // current consent, then reuse a matching one (or build fresh).
        let wantPersistent = SimulaPrivacy.shared.currentSnapshot.allowsLocalStorage
        while let last = idle.last, last.persistent != wantPersistent {
            idle.removeLast()
        }
        let reusedWarm = idle.last != nil
        let pooled = idle.popLast() ?? makePooled()

        pooled.forwarder.onMessage = onMessage
        pooled.webView.navigationDelegate = delegate
        pooled.webView.uiDelegate = delegate

        active[ObjectIdentifier(pooled.webView)] = pooled

        // Refill on the next runloop turn so this acquire returns immediately and
        // the following one (e.g. the post-game ad) is also warm.
        Task { @MainActor [weak self] in self?.prewarm() }

        // Warm (pool hit) vs cold (had to create) — surfaces prewarm effectiveness + cold cost.
        Telemetry.shared.recordOperation(
            name: reusedWarm ? "webview_acquire_warm" : "webview_acquire_cold",
            durationMs: Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000),
            success: true
        )
        return pooled.webView
    }

    /// Reset a finished web view and return it to the pool (or discard if full /
    /// privacy mismatch). Idempotent: a second call for the same view no-ops
    /// because `active` no longer holds it.
    func release(_ webView: WKWebView) {
        guard let pooled = active.removeValue(forKey: ObjectIdentifier(webView)) else {
            return
        }
        pooled.webView.stopLoading()
        pooled.webView.navigationDelegate = nil
        pooled.webView.uiDelegate = nil
        pooled.forwarder.onMessage = nil

        // Tear down the DOM so a recycled view never flashes the prior creative.
        if let blank = URL(string: "about:blank") {
            pooled.webView.load(URLRequest(url: blank))
        }

        // Only re-pool when the storage policy still matches current consent; a
        // mismatched view is dropped so the next acquire builds a fresh one.
        let wantPersistent = SimulaPrivacy.shared.currentSnapshot.allowsLocalStorage
        if pooled.persistent == wantPersistent && idle.count < maxIdle {
            idle.append(pooled)
        }
    }

    /// Flushes prewarmed idle web views. Called on a consent change so the next
    /// view is built with a data store matching the new storage policy (a
    /// prewarmed view bakes its policy in at creation time).
    func clear() {
        idle.removeAll()
    }
}
#endif
