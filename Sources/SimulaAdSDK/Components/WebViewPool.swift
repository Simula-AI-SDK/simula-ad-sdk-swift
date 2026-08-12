import Foundation

/// Cross-platform-testable iOS retention policy. Android uses the same business limits with
/// Android-native low-RAM/heap signals; iOS uses physical RAM plus lifecycle/memory callbacks.
enum SimulaWebViewPolicy {
    static let normalIdleCap = 1
    static let normalRetainedCap = 3
    static let constrainedRetainedCap = 1
    static let cooldown: TimeInterval = 5 * 60
    private static let constrainedRamBytes: UInt64 = 2 * 1024 * 1024 * 1024

    static func isMemoryConstrained(totalRamBytes: UInt64) -> Bool {
        totalRamBytes <= constrainedRamBytes
    }

    static func idleCap(totalRamBytes: UInt64) -> Int {
        isMemoryConstrained(totalRamBytes: totalRamBytes) ? 0 : normalIdleCap
    }

    static func retainedCap(totalRamBytes: UInt64) -> Int {
        isMemoryConstrained(totalRamBytes: totalRamBytes) ? constrainedRetainedCap : normalRetainedCap
    }

    static func canRetain(
        maxIdle: Int,
        idleCount: Int,
        applicationActive: Bool,
        now: TimeInterval,
        blockedUntil: TimeInterval
    ) -> Bool {
        maxIdle > 0 && idleCount < maxIdle && applicationActive && now >= blockedUntil
    }
}

#if os(iOS)
import WebKit
import UIKit
import os

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

    /// One spare matches Android and is enough for sequential game/post-game use. Constrained
    /// devices keep no speculative idle view; a required acquire still builds cold.
    private let maxIdle = SimulaWebViewPolicy.idleCap(totalRamBytes: ProcessInfo.processInfo.physicalMemory)
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var poolingBlockedUntil: TimeInterval = 0
    private let signposter = OSSignposter(subsystem: "ad.simula.sdk", category: "WebView")

    var allowsRetention: Bool {
        SimulaWebViewPolicy.canRetain(
            maxIdle: maxIdle,
            idleCount: idle.count,
            applicationActive: applicationActive && UIApplication.shared.applicationState == .active,
            now: ProcessInfo.processInfo.systemUptime,
            blockedUntil: poolingBlockedUntil
        )
    }

    /// Native retained views have their own cap; they share only lifecycle/cooldown eligibility.
    var allowsNativeRetention: Bool {
        applicationActive
            && UIApplication.shared.applicationState == .active
            && ProcessInfo.processInfo.systemUptime >= poolingBlockedUntil
    }

    private init() {
        // Each idle web view keeps a Web Content process resident. Under memory pressure, drop the
        // warm buffer so the SDK isn't holding a tens-of-MB floor in the host (a cold `acquire` simply
        // rebuilds one). `active` views are on screen, so they're deliberately left untouched.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMemoryPressure() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleBackground() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleActive() }
        }
    }

    /// Forwards `window.postMessage` payloads to the native message handler.
    /// Installed once per web view at creation time.
    private static let postMessageScript = WKUserScript(
        source: """
        window.addEventListener('message', function(event) {
            // The SDK delivers query responses back via window.postMessage carrying this
            // marker; don't forward those to native (they're for the creative, not us).
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

    /// Forwards creative JS errors (`window.onerror`) to native via the same `simulaSDK` handler, where
    /// the coordinator records them as telemetry. Document-start so early errors are caught too.
    private static let errorCaptureScript = WKUserScript(
        source: """
        window.addEventListener('error', function(e) {
            try {
                window.webkit.messageHandlers.simulaSDK.postMessage(JSON.stringify({
                    type: 'SIMULA_JS_ERROR',
                    message: (e && e.message) ? String(e.message) : 'error',
                    line: (e && e.lineno) ? e.lineno : 0
                }));
            } catch (_) {}
        });
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private func makePooled() -> Pooled {
        let interval = signposter.beginInterval("WebViewCreate")
        defer { signposter.endInterval("WebViewCreate", interval) }
        let forwarder = WebViewMessageForwarder()

        let controller = WKUserContentController()
        controller.add(forwarder, name: WebViewPool.messageHandlerName)
        controller.addUserScript(WebViewPool.postMessageScript)
        controller.addUserScript(WebViewPool.errorCaptureScript)

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

    /// Fully dismantle a view we're **discarding** (not re-pooling). `WKUserContentController.add`
    /// holds a strong reference to the forwarder; without removing the handler, the controller keeps
    /// the forwarder (and anything it captures) alive until the system eventually reaps the dropped
    /// `WKWebView` — a leak in long sessions. Re-pooled views deliberately keep their handler.
    private func teardown(_ pooled: Pooled) {
        pooled.forwarder.onMessage = nil
        pooled.webView.stopLoading()
        pooled.webView.navigationDelegate = nil
        pooled.webView.uiDelegate = nil
        pooled.webView.configuration.userContentController
            .removeScriptMessageHandler(forName: WebViewPool.messageHandlerName)
    }

    /// Create a warm web view ahead of time, if the pool has room. Loads
    /// `about:blank` to bring up the Web Content process so the later real load
    /// starts warm. The coordinator ignores `about:blank` navigations, so this
    /// never reaches the consumer's load callbacks.
    func prewarm(trigger: String = "demand") {
        guard allowsRetention else { return }
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let interval = signposter.beginInterval("WebViewPrewarm")
        defer { signposter.endInterval("WebViewPrewarm", interval) }
        let pooled = makePooled()
        if let blank = URL(string: "about:blank") {
            pooled.webView.load(URLRequest(url: blank))
        }
        idle.append(pooled)
        Telemetry.shared.recordOperation(
            name: "webview_prewarm",
            durationMs: Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000),
            success: true,
            breadcrumb: "trigger=\(Self.prewarmTrigger(trigger));result=warmed"
        )
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
            teardown(last)
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
        Task { @MainActor [weak self] in self?.prewarm(trigger: "acquire_refill") }

        // Warm (pool hit) vs cold (had to create) — surfaces prewarm effectiveness + cold cost.
        Telemetry.shared.recordOperation(
            name: reusedWarm ? "webview_acquire_warm" : "webview_acquire_cold",
            durationMs: Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000),
            success: true
        )
        return pooled.webView
    }

    /// Transfers ownership of an active (handed-out) web view to the caller — the native-ad
    /// retained store — so a later `release` no-ops instead of resetting it to `about:blank`.
    /// Returns the stable message forwarder wired at creation (the new owner re-points its
    /// `onMessage` on each reattach); `nil` when the view isn't pool-active (already released
    /// or adopted), in which case ownership does not transfer.
    func adopt(_ webView: WKWebView) -> WebViewMessageForwarder? {
        active.removeValue(forKey: ObjectIdentifier(webView))?.forwarder
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

        // Only re-pool when the storage policy still matches current consent; a
        // mismatched view is dropped so the next acquire builds a fresh one.
        let wantPersistent = SimulaPrivacy.shared.currentSnapshot.allowsLocalStorage
        if pooled.persistent == wantPersistent && allowsRetention {
            // Tear down the DOM only when recycling. Starting an about:blank load immediately
            // before discarding can race callbacks into a deallocated WebView.
            if let blank = URL(string: "about:blank") {
                pooled.webView.load(URLRequest(url: blank))
            }
            idle.append(pooled)
        } else {
            // Not re-pooled → discard it fully so the content controller doesn't retain the forwarder.
            teardown(pooled)
        }
    }

    /// Flushes prewarmed idle web views. Called on a consent change so the next
    /// view is built with a data store matching the new storage policy (a
    /// prewarmed view bakes its policy in at creation time).
    func clear() {
        let interval = signposter.beginInterval("WebViewPoolClear")
        defer { signposter.endInterval("WebViewPoolClear", interval) }
        idle.forEach { teardown($0) }
        idle.removeAll()
    }

    private func handleMemoryPressure() {
        poolingBlockedUntil = max(
            poolingBlockedUntil,
            ProcessInfo.processInfo.systemUptime + SimulaWebViewPolicy.cooldown
        )
        clear()
    }

    private func handleBackground() {
        applicationActive = false
        poolingBlockedUntil = max(
            poolingBlockedUntil,
            ProcessInfo.processInfo.systemUptime + SimulaWebViewPolicy.cooldown
        )
        clear()
    }

    private func handleActive() {
        applicationActive = true
        // Demand callers may prewarm after the cooldown; never allocate automatically here.
    }

    private static func prewarmTrigger(_ value: String) -> String {
        switch value {
        case "native_load", "interstitial_ready", "rewarded_ready", "minigame_menu",
             "minigame_game", "acquire_refill":
            return value
        default:
            return "demand"
        }
    }
}
#endif
