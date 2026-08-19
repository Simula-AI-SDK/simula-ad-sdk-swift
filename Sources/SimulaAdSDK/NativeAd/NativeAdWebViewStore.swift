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
/// exceeded, and everything idle is dropped on a memory warning or background transition. An
/// attached (on-screen) session is never destroyed by eviction — its representable still owns it.
///
/// Blank impression ids (previews) never reach this store — `WebViewRepresentable` keeps them on
/// the ephemeral `WebViewPool` path, preserving the one-shot behavior for QA creatives.
@MainActor
final class NativeAdWebViewStore {
    static let shared = NativeAdWebViewStore()

    /// Retained-view cap. Each retained view pins a live Web Content process (~20-30 MB); three is
    /// enough for the handful of ads near the viewport, and idle sessions drop on memory warnings.
    /// Matches the Kotlin store's cap.
    static let maxRetained = SimulaWebViewPolicy.retainedCap(
        totalRamBytes: ProcessInfo.processInfo.physicalMemory
    )

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
        /// True once a creative load actually finished (`noteLoadSucceeded`). A session detached
        /// mid-load has a view with no rendered DOM yet — reattaching it as `alreadyLoaded` would
        /// suppress the remount's reload and leave an empty slot, so `attach` requires this flag
        /// for the no-reload path and rebuilds fresh otherwise.
        var loadCompleted = false

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
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var retentionBlockedUntil: TimeInterval = 0
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
            if !session.attached, !session.unusable, session.loadCompleted, session.loadedKey == creativeKey {
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
            // Idle but not reattachable (render process died / load failed off-screen, the load
            // never finished before the row was dismantled, or a different creative now lives
            // under this id) — destroy it and rebuild fresh below.
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

    /// Whether this serve can remount its completed DOM immediately. NativeAdSlot uses this on
    /// appearance to skip frame admission only for a genuine retained reattach; a missing,
    /// attached, stale, or unusable session still goes through NativeAdMountScheduler.
    func canReattach(impressionId: String, creativeKey: String) -> Bool {
        guard let session = sessions[impressionId] else { return false }
        return !session.attached
            && !session.unusable
            && session.loadCompleted
            && session.loadedKey == creativeKey
    }

    /// Scroll-out / teardown for a view previously handed out by `attach`. Returns `true` when the
    /// store owned the view and has handled it (retained it — or destroyed it if its render process
    /// died); the caller must NOT release it to `WebViewPool`. `false` for ephemeral/unknown views —
    /// the caller keeps today's pool-release path.
    func detach(_ webView: WKWebView, impressionId: String) -> Bool {
        guard let session = sessions[impressionId], session.webView === webView else { return false }
        session.attached = false
        if session.unusable || !session.loadCompleted {
            // Unusable — or the creative never finished loading (fast fling past a still-loading
            // ad). A mid-load view has no rendered DOM worth keeping, and its didFinish would land
            // on the DetachedRenderMonitor unobserved, so `loadCompleted` could never be set —
            // retaining it would leave a permanently-unattachable session pinning a Web Content
            // process. Destroy it; the remount reloads from the cached fill (pre-store behavior;
            // matches the Kotlin store).
            remove(impressionId)
            return true
        }
        guard allowsRetention else {
            // Background/pressure policy: do not pin an off-screen Web Content process. Attached
            // views are never yanked; this runs only after their representable released ownership.
            remove(impressionId)
            return true
        }
        // Retain: freeze callbacks, keep the DOM. The monitor keeps watching for a render death.
        session.forwarder.onMessage = nil
        webView.uiDelegate = nil
        webView.navigationDelegate = detachedMonitor
        webView.removeFromSuperview()
        // More than the cap may have been attached simultaneously and therefore unevictable.
        // Re-run now that this session is idle so the documented bound becomes enforceable.
        evictIfNeeded()
        return true
    }

    /// The slot was recycled to a different serve IN PLACE (`updateUIView` saw a new impression
    /// id on the same representable — host list recycling, e.g. RN FlashList, updates props
    /// without remaking the view): a different creative is about to load into the web view
    /// retained under `oldImpressionId`. Without re-keying, that session would keep its
    /// still-matching `loadedKey` over the WRONG DOM — a later revisit of the old serve would
    /// reattach the new serve's creative (misattributed impressions/clicks) — and, because
    /// dismantle detaches under the NEW id, the old entry would stay `attached` forever, pinning
    /// its Web Content process past every eviction.
    ///
    /// Re-keys the session to `newImpressionId` with a fresh `loadedKey` and `loadCompleted`
    /// reset (the new creative's didFinish sets it again), so the new serve keeps the flash-fix
    /// retention and the old serve rebuilds fresh on its next attach. When re-keying isn't
    /// possible (blank new id, or the new serve already holds an attached session in another
    /// slot) the view is orphaned instead: dropped from the store untouched — it lives out this
    /// mount and deallocates on dismantle (`detach` won't match, and the pool no longer owns it).
    func rebind(_ webView: WKWebView, from oldImpressionId: String, to newImpressionId: String?, creativeKey: String) {
        guard let session = sessions[oldImpressionId], session.webView === webView else { return }
        sessions.removeValue(forKey: oldImpressionId)
        if let idx = accessOrder.firstIndex(of: oldImpressionId) { accessOrder.remove(at: idx) }
        guard let newId = newImpressionId, !newId.isEmpty else { return }
        if let existing = sessions[newId] {
            if existing.attached { return } // other slot owns the retention — orphan this view
            remove(newId) // idle duplicate for the same serve — the live in-place view supersedes it
        }
        let rebound = Session(impressionId: newId, webView: webView, forwarder: session.forwarder, loadedKey: creativeKey)
        sessions[newId] = rebound
        touch(newId)
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

    /// Same as `noteUnusable(viewID:)`, keyed by impression id. Used by `NativeAdSlot` when it
    /// collapses a slot the store can't see failing itself — e.g. the missing-height watchdog: the
    /// creative loaded cleanly (`loadCompleted` is set) but never reported a height, so without
    /// this flag a remount would reattach it `alreadyLoaded`, skip the reload, and show the same
    /// blank creative while the still-cached fill expects a retry.
    func noteUnusable(impressionId: String) {
        guard let session = sessions[impressionId] else { return }
        session.unusable = true
        if !session.attached { remove(impressionId) }
    }

    /// A (possibly recovery) load completed cleanly on `viewID` — the view is healthy again.
    func noteLoadSucceeded(viewID: ObjectIdentifier) {
        guard let session = sessionByView(viewID)?.session else { return }
        session.unusable = false
        session.loadCompleted = true
    }

    /// Synchronous entry to `noteUnusable` for WebKit delegate callbacks. Those arrive on the
    /// main thread, and a `detach`/`attach` can run in the same runloop turn — a deferred
    /// `Task { @MainActor in ... }` would let the store retain (or reattach) a dead view before
    /// the flag lands. The main-thread check makes `assumeIsolated` trap-free; the Task fallback
    /// covers any off-main caller (single-call closure — see the task-shape note in TelemetryManager).
    nonisolated static func markUnusable(viewID: ObjectIdentifier) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.noteUnusable(viewID: viewID) }
        } else {
            Task { @MainActor in shared.noteUnusable(viewID: viewID) }
        }
    }

    /// Synchronous entry to `noteLoadSucceeded` — same rationale as `markUnusable(viewID:)`.
    nonisolated static func markLoadSucceeded(viewID: ObjectIdentifier) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.noteLoadSucceeded(viewID: viewID) }
        } else {
            Task { @MainActor in shared.noteLoadSucceeded(viewID: viewID) }
        }
    }

    /// Drop the retained view for `impressionId` (the slot was invalidated for a fresh ad). An
    /// attached view is never yanked off screen — its representable still owns it — but it IS
    /// flagged `unusable`: the fill is gone from the cache, so retaining its DOM on scroll-out
    /// would let a later remount of the same serve reattach the stale creative with no reload.
    /// The flag makes `detach` destroy it instead.
    func evict(impressionId: String) {
        guard let session = sessions[impressionId] else { return }
        if session.attached {
            session.unusable = true
            return
        }
        remove(impressionId)
    }

    /// Drop the retained views for a batch of impression ids (cache-eviction path — the fills are
    /// gone from `NativeAdCache`, so their retained views can never be reattached again).
    func evictAll(impressionIds: [String]) {
        for id in impressionIds { evict(impressionId: id) }
    }

    /// Drop every idle retained session (memory warning). Attached (on-screen) sessions stay
    /// fully usable — memory pressure doesn't invalidate their content, and they remain
    /// retainable on scroll-out.
    func evictAllIdle() {
        // Snapshot: remove(_:) mutates accessOrder mid-loop (for-in already iterates the value
        // captured at loop start, but keep the copy explicit).
        for key in Array(accessOrder) where sessions[key]?.attached == false {
            remove(key)
        }
    }

    private var allowsRetention: Bool {
        applicationActive
            && ProcessInfo.processInfo.systemUptime >= retentionBlockedUntil
            && WebViewPool.shared.allowsNativeRetention
    }

    private func handleMemoryPressure() {
        retentionBlockedUntil = SimulaWebViewPolicy.blockedUntil(
            current: retentionBlockedUntil,
            now: ProcessInfo.processInfo.systemUptime,
            event: .memoryPressure
        )
        evictAllIdle()
    }

    func handleRendererDeath() {
        retentionBlockedUntil = SimulaWebViewPolicy.blockedUntil(
            current: retentionBlockedUntil,
            now: ProcessInfo.processInfo.systemUptime,
            event: .rendererDeath
        )
        evictAllIdle()
    }

    private func handleBackground() {
        applicationActive = false
        retentionBlockedUntil = SimulaWebViewPolicy.blockedUntil(
            current: retentionBlockedUntil,
            now: ProcessInfo.processInfo.systemUptime,
            event: .background
        )
        evictAllIdle()
    }

    private func handleActive() {
        applicationActive = true
    }

    /// Nothing currently retained may ever be REATTACHED again — a consent change rebuilt the
    /// storage policy every view baked in at creation, or `invalidateNativeAds` dropped every
    /// cached fill these views render. Idle sessions are destroyed now; attached (on-screen) ones
    /// are never yanked — they're flagged `unusable` so `detach` destroys them on scroll-out
    /// instead of retaining them. Mirror of `WebViewPool.clear()` for the retained native-ad path.
    func invalidateAllSessions() {
        for key in Array(accessOrder) {
            guard let session = sessions[key] else { continue }
            if session.attached {
                session.unusable = true
            } else {
                remove(key)
            }
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
        // Snapshot: remove(_:) mutates accessOrder mid-loop (see evictAllIdle).
        for key in Array(accessOrder) where sessions.count > Self.maxRetained {
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

/// Watches detached (off-screen) retained views for anything that invalidates their content —
/// web-content-process termination AND main-frame load failures (a row dismantled mid-load can
/// still have its navigation fail while idle). Their coordinator delegate was unwired on detach,
/// so without this the failure would go unobserved, the session would stay "usable", and the next
/// attach would hand back a blank/error view as `alreadyLoaded` (skipping the reload).
private final class DetachedRenderMonitor: NSObject, WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Telemetry.shared.recordError(
            signature: "webview:render_gone",
            errorCode: "render_terminated",
            breadcrumb: "native_ad_detached"
        )
        WebViewPool.shared.handleRendererDeath()
        NativeAdWebViewStore.shared.handleRendererDeath()
        NativeAdWebViewStore.markUnusable(viewID: ObjectIdentifier(webView))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteLoadFailed(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        noteLoadFailed(webView, error: error)
    }

    /// Main-frame HTTP 4xx/5xx never reaches `didFail` — WKWebView renders the error body as a
    /// successful navigation. Mirror the coordinator's check so an idle view showing an error page
    /// is never reattached.
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
        NativeAdWebViewStore.markUnusable(viewID: ObjectIdentifier(webView))
    }

    private func noteLoadFailed(_ webView: WKWebView, error: Error) {
        // A cancelled load isn't a failure (superseded navigation) — same rule as the coordinator.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        NativeAdWebViewStore.markUnusable(viewID: ObjectIdentifier(webView))
    }
}
#endif
