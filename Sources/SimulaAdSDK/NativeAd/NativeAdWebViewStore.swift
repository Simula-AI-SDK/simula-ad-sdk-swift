#if os(iOS)
import WebKit
import UIKit

/// Retains a small LRU of loaded native-ad `WKWebView`s keyed by impression id, so a slot that
/// scrolls out of a feed and back reattaches the **same, already-rendered** view instead of
/// re-acquiring a blank one from `WebViewPool` and reloading the creative (the blank-then-pop
/// "re-render on scroll" flash). Mirrors the Kotlin SDK's `NativeAdWebViewStore`.
///
/// A `Session` bundles the retained view with the stable `WebViewMessageForwarder` wired at its
/// creation, so a reattach only re-points `onMessage` at the new coordinator and re-sets the
/// delegates — the injected height-reporting script and the creative's DOM survive untouched.
/// While detached, the forwarder and delegates are unwired and a store-owned monitor watches for
/// web-content-process termination (an off-screen render death would otherwise go unobserved and
/// hand a permanently-blank view back to the next attach).
///
/// The LRU is bounded by `maxRetained`; the eldest **idle** session is destroyed when the cap is
/// exceeded, and everything idle is dropped on a memory warning. An attached (on-screen) session is
/// never destroyed by eviction — its representable still owns the view.
///
/// Blank impression ids (previews) never reach this store — `WebViewRepresentable` keeps them on
/// the ephemeral `WebViewPool` path, preserving the one-shot behavior for QA creatives.
@MainActor
final class NativeAdWebViewStore {
    static let shared = NativeAdWebViewStore()

    /// Retained-view cap. Each retained view pins a live Web Content process (~20-30 MB); three is
    /// enough for the handful of ads near the viewport, and idle sessions drop on memory warnings.
    /// Matches the Kotlin store's cap.
    static let maxRetained = 3

    /// One retained creative: its loaded web view + the stable message forwarder wired at creation.
    final class Session {
        let impressionId: String
        let webView: WKWebView
        let forwarder: WebViewMessageForwarder
        /// Identity of the creative loaded into `webView` (so a changed creative rebuilds fresh).
        let loadedKey: String
        /// True while mounted in a live representable — guards against stealing an on-screen view.
        var attached = true
        /// The view holds nothing valid to reattach: its web content process died, or its
        /// main-frame load failed (e.g. offline when the row scrolled in). Reattaching it as-is
        /// would show a blank ad AND suppress the reload that a remount of the still-cached fill
        /// is expected to retry — so the next attach discards it and rebuilds the creative.
        /// Cleared when a (recovery) load completes (`noteLoadSucceeded`).
        var unusable = false

        init(impressionId: String, webView: WKWebView, forwarder: WebViewMessageForwarder, loadedKey: String) {
            self.impressionId = impressionId
            self.webView = webView
            self.forwarder = forwarder
            self.loadedKey = loadedKey
        }
    }

    private var sessions: [String: Session] = [:]
    /// LRU recency: front = least-recently attached, back = most-recent. Kept in sync with `sessions`.
    private var accessOrder: [String] = []
    /// Store-owned navigation delegate installed on detached views (their coordinator delegate is
    /// unwired on release) so an off-screen render-process death is still observed. One shared
    /// instance — it identifies the session by the terminating view. `navigationDelegate` is weak,
    /// so the store holds it strongly.
    private let detachedMonitor = DetachedRenderMonitor()

    private init() {
        // Retained views each pin a Web Content process. Under memory pressure, drop every idle
        // session (a revisited row simply reloads its creative). Attached views are on screen and
        // deliberately left untouched — same policy as WebViewPool.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evictAllIdle() }
        }
    }

    /// The view to mount for `impressionId`: the retained, already-rendered one (rewired to the new
    /// `delegate`/`onMessage`; **no reload needed** — `alreadyLoaded` is true) or a fresh pool view
    /// adopted into a new session (`alreadyLoaded` false — the caller issues the load as usual).
    func attach(
        impressionId: String,
        creativeKey: String,
        delegate: WKNavigationDelegate & WKUIDelegate,
        onMessage: @escaping (String) -> Void
    ) -> (webView: WKWebView, alreadyLoaded: Bool) {
        if let session = sessions[impressionId] {
            if !session.attached, !session.unusable, session.loadedKey == creativeKey {
                // Reattach the retained view with its rendered DOM intact — the flash fix.
                touch(impressionId)
                session.attached = true
                session.forwarder.onMessage = onMessage
                session.webView.navigationDelegate = delegate
                session.webView.uiDelegate = delegate
                session.webView.removeFromSuperview() // clear any stale parent before SwiftUI re-adds it
                return (session.webView, true)
            }
            if session.attached {
                // The retained view is on screen in another slot (same serve rendered twice) — hand
                // out an ephemeral pool view instead; `detach` ignores it (identity mismatch) so it
                // returns to the pool on dismantle.
                return (WebViewPool.shared.acquire(delegate: delegate, onMessage: onMessage), false)
            }
            // Idle but unusable (render process died / load failed off-screen, or a different
            // creative now lives under this id) — destroy it and rebuild fresh below.
            remove(impressionId)
        }

        let webView = WebViewPool.shared.acquire(delegate: delegate, onMessage: onMessage)
        guard let forwarder = WebViewPool.shared.adopt(webView) else {
            // The pool kept ownership (shouldn't happen) — leave the view ephemeral.
            return (webView, false)
        }
        let session = Session(impressionId: impressionId, webView: webView, forwarder: forwarder, loadedKey: creativeKey)
        sessions[impressionId] = session
        touch(impressionId)
        evictIfNeeded()
        return (webView, false)
    }

    /// Scroll-out / teardown for a view previously handed out by `attach`. Returns `true` when the
    /// store owned the view and has handled it (retained it — or destroyed it if its render process
    /// died); the caller must NOT release it to `WebViewPool`. `false` for ephemeral/unknown views —
    /// the caller keeps today's pool-release path.
    func detach(_ webView: WKWebView, impressionId: String) -> Bool {
        guard let session = sessions[impressionId], session.webView === webView else { return false }
        session.attached = false
        if session.unusable {
            remove(impressionId)
            return true
        }
        // Retain: freeze callbacks, keep the DOM. The monitor keeps watching for a render death.
        session.forwarder.onMessage = nil
        webView.uiDelegate = nil
        webView.navigationDelegate = detachedMonitor
        webView.removeFromSuperview()
        return true
    }

    /// The view behind `viewID` no longer holds a valid creative — its web content process
    /// terminated (reported by the coordinator while attached, or by the detached monitor while
    /// idle) or its main-frame load failed. Flags the session so the blank view is never
    /// reattached; an idle unusable view is destroyed immediately.
    func noteUnusable(viewID: ObjectIdentifier) {
        guard let (key, session) = sessionByView(viewID) else { return }
        session.unusable = true
        if !session.attached { remove(key) }
    }

    /// A (possibly recovery) load completed cleanly on `viewID` — the view is healthy again.
    func noteLoadSucceeded(viewID: ObjectIdentifier) {
        sessionByView(viewID)?.session.unusable = false
    }

    /// Drop the retained view for `impressionId` (the slot was invalidated for a fresh ad). An
    /// attached view is skipped — its representable still owns it; it simply won't be retained with
    /// a matching creative once the refreshed slot remounts, and ages out of the LRU.
    func evict(impressionId: String) {
        guard let session = sessions[impressionId], !session.attached else { return }
        remove(impressionId)
    }

    /// Drop every idle retained session (memory warning / `invalidateNativeAds`).
    func evictAllIdle() {
        for key in accessOrder where sessions[key]?.attached == false {
            remove(key)
        }
    }

    // MARK: - Internals

    private func sessionByView(_ viewID: ObjectIdentifier) -> (key: String, session: Session)? {
        for (key, session) in sessions where ObjectIdentifier(session.webView) == viewID {
            return (key, session)
        }
        return nil
    }

    private func touch(_ key: String) {
        if let idx = accessOrder.firstIndex(of: key) { accessOrder.remove(at: idx) }
        accessOrder.append(key)
    }

    private func evictIfNeeded() {
        guard sessions.count > Self.maxRetained else { return }
        // Oldest idle first; attached sessions are skipped (their views are on screen).
        for key in accessOrder where sessions.count > Self.maxRetained {
            if sessions[key]?.attached == false { remove(key) }
        }
    }

    private func remove(_ key: String) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        if let idx = accessOrder.firstIndex(of: key) { accessOrder.remove(at: idx) }
        destroy(session)
    }

    /// Fully dismantle a session's view. It was adopted out of `WebViewPool` (never re-pooled), so
    /// after unwiring it deallocates with its Web Content process. Removing the script handler
    /// matters: the content controller otherwise strongly retains the forwarder past the view's death.
    private func destroy(_ session: Session) {
        session.forwarder.onMessage = nil
        session.webView.configuration.userContentController
            .removeScriptMessageHandler(forName: WebViewPool.messageHandlerName)
        session.webView.stopLoading()
        session.webView.navigationDelegate = nil
        session.webView.uiDelegate = nil
        session.webView.removeFromSuperview()
    }
}

/// Watches detached (off-screen) retained views for web-content-process termination — their
/// coordinator delegate was unwired on detach, so without this the death would go unobserved and
/// the store would reattach a permanently-blank view.
private final class DetachedRenderMonitor: NSObject, WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Telemetry.shared.recordError(
            signature: "webview:render_gone",
            errorCode: "render_terminated",
            breadcrumb: "native_ad_detached"
        )
        let viewID = ObjectIdentifier(webView)
        // Single-call task closure — see the task-shape note in TelemetryManager.
        Task { @MainActor in NativeAdWebViewStore.shared.noteUnusable(viewID: viewID) }
    }
}
#endif
