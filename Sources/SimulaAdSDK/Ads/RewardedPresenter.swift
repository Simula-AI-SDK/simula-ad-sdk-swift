#if os(iOS)
import SwiftUI
import UIKit
import Combine

// MARK: - RewardedPresenter

/// Presents the imperative rewarded minigame full-screen in a dedicated `UIWindow`,
/// independent of the host app's view-controller stack (mirrors `InterstitialPresenter`).
///
/// Hosting in its own window (above `.normal`) lets the imperative API present from
/// anywhere — SwiftUI or UIKit hosts alike.
@MainActor
final class RewardedPresenter {
    private var window: UIWindow?
    /// Fired once on teardown with whether the reward was earned and the measured
    /// play time, so the caller can verify the play server-side.
    private var onClose: ((Bool, Double) -> Void)?
    /// The host's key window, captured before we take key. Restored on dismiss so the
    /// host regains touch/keyboard focus (a new key window doesn't auto-revert).
    private weak var originalKeyWindow: UIWindow?

    /// Presents the playable minigame iframe. `onClose` fires once the window has been
    /// torn down, carrying `(rewardEarned, elapsedPlayTime)`.
    ///
    /// - Returns: `true` if presented; `false` if no window scene was available (in
    ///   which case `onClose` is never called).
    @discardableResult
    func present(
        impressionId: String,
        apiKey: String,
        iframeUrl: String,
        renderedHtml: String = "",
        close: CloseBehavior? = nil,
        storePrompt: StorePrompt? = nil,
        trackingUrl: String? = nil,
        destination: AdDestination = .appstore,
        storeOpen: StoreOpen = .skstoreproduct,
        storeUrl: String? = nil,
        attribution: AdAttribution? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        previewHTML: String? = nil,
        onClick: @escaping () -> Void,
        onImpression: @escaping () -> Void,
        onClose: @escaping (Bool, Double) -> Void
    ) -> Bool {
        guard let scene = Self.activeWindowScene() else {
            return false
        }
        self.onClose = onClose

        // WebView ↔ SDK bridge (PRD §3): the creative can request early completion, haptics,
        // orientation lock, and device/audio/orientation queries. Owned here so the orientation
        // handler can reach the hosting controller + window created below.
        let bridge = CreativeBridge()

        let root = RewardedGameView(
            impressionId: impressionId,
            apiKey: apiKey,
            iframeUrl: iframeUrl,
            renderedHtml: renderedHtml,
            close: close,
            storePrompt: storePrompt,
            trackingUrl: trackingUrl,
            destination: destination,
            storeOpen: storeOpen,
            storeUrl: storeUrl,
            attribution: attribution,
            autoStoreRedirect: autoStoreRedirect,
            previewHTML: previewHTML,
            bridge: bridge,
            onClick: onClick,
            onImpression: onImpression,
            onFinish: { [weak self] earned, elapsed in
                self?.dismiss(earned: earned, elapsedPlayTime: elapsed)
            }
        )

        let hosting = OrientationLockingHostingController(rootView: root)
        // Opaque black (not clear) so the host app never shows through during the
        // present/dismiss opacity fade — matches Android's blank-screen transition.
        hosting.view.backgroundColor = .black

        originalKeyWindow = scene.keyWindow

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .black
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
        // Give the bridge the orientation host + window now that they exist.
        bridge.orientationHost = hosting
        bridge.window = window
        // Hide the status bar in hosts that opted out of VC-based appearance (e.g. React Native),
        // where `.hideStatusBar(true)` in the creative view is a no-op. No-op in native hosts.
        SimulaAppStatusBar.hide()
        return true
    }

    /// Fires the close callback, then tears down the presentation window — in that order, so the
    /// callback can bring up the post-close fallback ad window (from a background prefetch, ready
    /// synchronously) on top of this still-visible window before it's hidden. Tearing down first
    /// flashed the app behind during the handoff.
    private func dismiss(earned: Bool, elapsedPlayTime: Double) {
        // Capture the window refs and clear `self`'s references BEFORE invoking the callback: the
        // callback nils the owner's reference to this presenter, so `self` may be deallocated by
        // the time it returns. Operate on the locals afterwards instead of touching `self`.
        let win = window
        let hostKeyWindow = originalKeyWindow
        window = nil
        originalKeyWindow = nil
        let callback = onClose
        onClose = nil
        callback?(earned, elapsedPlayTime)
        // Balanced with the present-time hide() (after the callback so a fallback presented in it
        // keeps the bar hidden across the handoff via the ref count).
        SimulaAppStatusBar.restore()
        win?.isHidden = true
        win?.rootViewController = nil
        // Restore the host's key window so it regains focus. A fallback window presented in the
        // callback stays visible on top and still receives touches via hit-testing.
        hostKeyWindow?.makeKey()
    }

    /// Finds a foreground window scene to attach the overlay window to.
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return active
        }
        return scenes.compactMap { $0 as? UIWindowScene }.first
    }
}

// MARK: - RewardedGameView

/// Full-screen playable minigame: the creative iframe in a pooled `WKWebView`, a
/// bottom-left close button (always available) and a bottom-right status pill
/// counting down the remaining play time. The reward is earned once `gateSeconds` of play
/// elapse; closing earlier prompts an exit confirmation so the user doesn't lose the
/// reward by accident. On a qualifying close, `onFinish(earned, elapsedPlayTime)`
/// fires after the dismiss fade.
private struct RewardedGameView: View {
    /// The impression id from /load/rewarded — drives the ad-info report overlay.
    let impressionId: String
    let apiKey: String
    let iframeUrl: String
    /// Server-rendered HTML creative; preferred over `iframeUrl` when non-empty.
    let renderedHtml: String
    /// Server `ad_behavior.close` treatment (hidden / countdown ring / progress bar / reward-or-close
    /// label) — rendered by the shared `CloseButtonView`, gated on play-to-earn. `nil` → default.
    /// Its `delaySeconds` is also the play-to-earn gate length (see `gateSeconds`).
    let close: CloseBehavior?
    // Mid-ad store prompt config + tap routing. `storePrompt == nil` → no badge.
    let storePrompt: StorePrompt?
    let trackingUrl: String?
    let destination: AdDestination
    let storeOpen: StoreOpen
    /// The serve's raw App Store link (`ios_store_url`) — drives the deterministic CTA / store-prompt
    /// route (in-app sheet from its app id, tracker fired in the background). `nil` → redirect-chain
    /// resolution as before.
    let storeUrl: String?
    /// Ad-network attribution tokens carried into the store sheet when the mid-ad store prompt is tapped.
    let attribution: AdAttribution?
    /// auto_store_redirect config — fires the store open once at the configured creative moment.
    let autoStoreRedirect: AutoStoreRedirect?
    /// When set, render this HTML instead of `iframeUrl` (preview / QA placeholder playable).
    let previewHTML: String?
    /// WebView ↔ SDK bridge (PRD §3). `AD_EARLY_COMPLETE` flips `earlyComplete` (observed below).
    let bridge: CreativeBridge
    /// Fired on a user-gesture CTA / store-prompt tap (the CLICKED signal); parity with the interstitial.
    let onClick: () -> Void
    /// Fired once, ~2s after begin-to-render (foreground time), for the billable IMPRESSION + PAID.
    let onImpression: () -> Void
    let onFinish: (Bool, Double) -> Void

    /// The timer runs only while the app is foregrounded AND no in-app store/Safari sheet covers the
    /// playable — tracked separately and reconciled in `reconcileTimer()`. The playable lives in a
    /// stand-alone `UIWindow`, where SwiftUI's `\.scenePhase` does NOT track the app lifecycle, so
    /// foreground state is driven by `UIApplication` background/foreground notifications instead.
    @State private var appForegrounded = true
    @State private var storeSheetPresented = false
    /// Store-exit funnel tracker (store_opened/returned/abandoned), created on appear.
    @State private var storeExit: StoreExitTracker?

    @State private var elapsedPlayTime: Double = 0
    /// Smoothly-animated 0→1 fill for the close bar/ring. Driven by a linear animation over the
    /// remaining gate (re-anchored on pause/resume) so the indicator glides instead of stepping once
    /// per 1 s accrual tick — `closeProgress` below is the instantaneous truth used to anchor it.
    @State private var closeProgressAnim: Double = 0
    @State private var rewardEarned = false
    @State private var storePromptVisible = false
    @State private var visible = true
    @State private var timerTask: Task<Void, Never>?
    /// auto_store_redirect one-shot guard.
    @State private var autoRedirectFired = false

    // Billable IMPRESSION + PAID — fired once, after `fullscreenImpressionDelayMs` of foreground
    // on-screen time from begin-to-render. Independent of the play-to-earn timer / reward gate.
    @State private var impressionFired = false
    @State private var impressionTask: Task<Void, Never>?

    /// Matches the dismiss fade before the window is removed.
    private let dismissAnimationDuration: TimeInterval = 0.25

    /// Play-to-earn gate length, in seconds — sourced from `ad_behavior.close.delay_seconds` (the
    /// same value that ungates the close button). `nil` close → 0 → instantly earned.
    private var gateSeconds: Int { close?.delaySeconds ?? 0 }

    private var secondsLeft: Int {
        max(0, gateSeconds - Int(elapsedPlayTime))
    }

    /// Instantaneous 0→1 play-to-earn fraction (whole-second granularity). Not rendered directly —
    /// `closeProgressAnim` glides between these values; this is the anchor the animation snaps to on
    /// pause/resume.
    private var closeProgress: Double {
        gateSeconds > 0 ? min(1.0, max(0.0, elapsedPlayTime / Double(gateSeconds))) : 1.0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Sits below the safe area (the black backdrop fills the notch / home-indicator region).
            // ctaDestination/ctaStoreUrl thread the serve's routing context into the coordinator so
            // an in-playable CTA opens the store deterministically (in-app sheet + background
            // tracker fire) instead of sniffing the tracker's redirect chain.
            if let previewHTML {
                WebViewRepresentable(htmlString: previewHTML, onAdClick: { handleHtmlClick() }, bridge: bridge, attribution: attribution, ctaDestination: destination, ctaStoreUrl: storeUrl, telemetryAdFormat: "rewarded")
            } else if !renderedHtml.isEmpty {
                // Prefer the server-rendered HTML (parity with the interstitial, which fills the
                // surface); fall back to the iframe URL. A user-gesture CTA tap fires CLICKED via
                // onAdClick and routes through the store sheet carrying any SKAN attribution.
                WebViewRepresentable(htmlString: renderedHtml, onAdClick: { handleHtmlClick() }, bridge: bridge, attribution: attribution, ctaDestination: destination, ctaStoreUrl: storeUrl, telemetryAdFormat: "rewarded")
            } else if let url = URL(string: iframeUrl) {
                WebViewRepresentable(url: url, onAdClick: { handleHtmlClick() }, bridge: bridge, attribution: attribution, ctaDestination: destination, ctaStoreUrl: storeUrl, telemetryAdFormat: "rewarded")
            }

            // Close button — honors the server `ad_behavior.close` treatment (hidden / countdown ring /
            // progress bar / reward-or-close label) exactly like the interstitial, but gated on the
            // play-to-earn progress: the ✕ unlocks only once the reward is earned.
            CloseButtonView(
                treatment: (close ?? CloseBehavior()).treatment,
                position: (close ?? CloseBehavior()).position,
                progressBarColor: (close ?? CloseBehavior()).progressBarColor,
                isRewardCopy: true,
                enabled: rewardEarned,
                remaining: secondsLeft,
                progress: closeProgressAnim,
                onClose: { finish(earned: true) }
            )
            .animation(.default, value: rewardEarned)

            // Mid-ad store prompt — appears at half the play-to-earn gate and is removed the instant
            // the reward unlocks (the reward/close pill takes over). Pinned to the corner opposite the
            // reward/close pill (the SDK mirrors the close position); a tap routes to the advertised store.
            if let prompt = storePrompt, prompt.enabled, storePromptVisible, !rewardEarned {
                // Match the reward/close pill's 8pt inset and center the badge in the same 44pt
                // touch-target band so the two share one centerline (parity with the interstitial).
                StorePromptBadge(prompt: prompt, closePosition: (close ?? CloseBehavior()).position, edgePadding: 8, rowHeight: 44, onTap: { onClick(); trackStorePromptClick(); storeExit?.recordStoreOpen("store_prompt"); handleStorePromptTap() })
            }

            // Persistent ad-info "i" + report sheet (required disclosure). Last so its sheet overlays.
            AdInfoReportOverlay(
                adId: impressionId,
                apiKey: apiKey,
                // A genuine bottom-left ✕ shares the bottom-left corner with the "i" (shrink its hit area);
                // a progress_bar bottom ✕ relocates to top-right, leaving the "i" its full hit area.
                closeAtBottomLeft: (close ?? CloseBehavior()).position == .bottomLeft && !closeBarAtBottom((close ?? CloseBehavior()).treatment, (close ?? CloseBehavior()).position)
            )
        }
        .opacity(visible ? 1 : 0)
        // Opacity 0 does not stop hit-testing during the fade; disable touches so a
        // second close tap can't double-fire.
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: dismissAnimationDuration), value: visible)
        .hideStatusBar(true)
        .onAppear {
            if storeExit == nil { storeExit = StoreExitTracker(adId: impressionId, adFormat: "rewarded") }
            startTimer()
            startImpressionTimer()
            // PLAYABLE_END: if the reward was already earned (duration 0), fire immediately.
            fireAutoStoreRedirectIfCloseShown()
        }
        .onDisappear {
            timerTask?.cancel()
            timerTask = nil
            impressionTask?.cancel()
            impressionTask = nil
            storeExit?.onAdClosed() // resolve any outstanding store visit as an abandon
        }
        // Pause the play-to-earn timer while the app is backgrounded OR an in-app store/Safari sheet
        // covers the playable; resume only when both clear, so the reward can't be earned off-screen.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            appForegrounded = false
            storeExit?.onAway()
            reconcileTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            appForegrounded = true
            storeExit?.onReturn()
            reconcileTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetWillPresent)) { _ in
            storeSheetPresented = true
            // A store/Safari sheet only appears from a CTA tap — handled inside the playable's web
            // view, so the trigger isn't known here. Tag it as a CTA open if nothing else claimed it.
            storeExit?.recordStoreOpenIfUntracked("cta")
            storeExit?.onAway()
            reconcileTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetDidDismiss)) { _ in
            storeSheetPresented = false
            storeExit?.onReturn()
            reconcileTimer()
        }
        // AD_EARLY_COMPLETE (PRD §3): the creative finished early (e.g. survey done), so grant the
        // reward and reveal the close button immediately, bypassing the play timer.
        .onReceive(bridge.$earlyComplete) { earlyComplete in
            guard earlyComplete, !rewardEarned else { return }
            timerTask?.cancel()
            timerTask = nil
            rewardEarned = true
        }
        // PLAYABLE_END (auto_store_redirect): open the store the moment the close button appears
        // (here, when the reward is earned and the reward/close pill becomes a close button).
        .onChange(of: rewardEarned) { earned in
            if earned { fireAutoStoreRedirectIfCloseShown() }
        }
    }

    // MARK: auto_store_redirect

    /// Opens the advertiser store once (no user tap) — shared by every auto_store_redirect trigger.
    private func fireAutoStoreRedirect() {
        guard !autoRedirectFired else { return }
        autoRedirectFired = true
        storeExit?.recordStoreOpen("auto_redirect")
        handleStorePromptTap()
    }

    /// PLAYABLE_END — fire once the close button appears (the reward is earned). SDK-native, no bridge.
    /// (END_SCREEN_1/2_OPEN are handled in the post-close fallback flow, by index — see
    /// `SimulaRewardedAd.presentFallbackAds` / `FallbackAdPresenter`.)
    private func fireAutoStoreRedirectIfCloseShown() {
        guard rewardEarned, let redirect = autoStoreRedirect, redirect.enabled,
              redirect.trigger == .playableEnd else { return }
        fireAutoStoreRedirect()
    }


    // MARK: Timer

    private func startTimer() {
        guard timerTask == nil else { return }
        // A zero/negative gate is earned immediately (no gate).
        guard gateSeconds > 0 else {
            rewardEarned = true
            return
        }
        // Glide the bar/ring fill linearly to full over the remaining gate (resuming from the
        // fraction already elapsed). The 1 s accrual loop below only drives gate / store-prompt /
        // reward logic — the indicator is animated, not stepped, so it no longer looks laggy.
        let remaining = Double(gateSeconds) - elapsedPlayTime
        closeProgressAnim = closeProgress
        if remaining > 0 {
            withAnimation(.linear(duration: remaining)) { closeProgressAnim = 1 }
        }
        timerTask = Task { @MainActor in
            while elapsedPlayTime < Double(gateSeconds) && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                elapsedPlayTime += 1
                // Reveal the store prompt at the halfway point to the reward (mid play-to-earn).
                if elapsedPlayTime >= Double(gateSeconds) / 2 {
                    withAnimation(.easeInOut(duration: 0.25)) { storePromptVisible = true }
                }
                if elapsedPlayTime >= Double(gateSeconds) {
                    rewardEarned = true
                }
            }
        }
    }

    /// Fires the billable IMPRESSION + PAID once, after the playable has been on screen for
    /// `fullscreenImpressionDelayMs` of FOREGROUND time from begin-to-render — independent of the
    /// play-to-earn gate. OMID measures viewability but does not gate us (PRD). Accrues only while
    /// foreground-active and no store/Safari sheet covers the playable (same gating as the play timer),
    /// so a backgrounded playable can't accrue the delay. Cancelled in `.onDisappear`.
    private func startImpressionTimer() {
        guard !impressionFired, impressionTask == nil else { return }
        impressionTask = Task { @MainActor in
            var accruedMs: Double = 0
            var lastTick = ProcessInfo.processInfo.systemUptime
            while accruedMs < fullscreenImpressionDelayMs {
                try? await Task.sleep(nanoseconds: impressionTickNanos)
                if Task.isCancelled { return }
                let now = ProcessInfo.processInfo.systemUptime
                let delta = (now - lastTick) * 1000
                lastTick = now
                if appForegrounded && !storeSheetPresented { accruedMs += delta }
            }
            if Task.isCancelled || impressionFired { return }
            impressionFired = true
            onImpression()
        }
    }

    /// Runs the play-to-earn timer only while foreground-active and no in-app store sheet covers the
    /// playable.
    private func reconcileTimer() {
        if appForegrounded && !storeSheetPresented {
            if !rewardEarned { startTimer() }
        } else {
            timerTask?.cancel()
            timerTask = nil
            // Freeze the animated fill at the true elapsed fraction so it stops gliding while paused
            // (disable the implicit animation so it doesn't tween toward the frozen value).
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { closeProgressAnim = closeProgress }
        }
    }

    /// A user-gesture CTA tap inside the playable: surface CLICKED to the publisher, then mark the
    /// store-exit funnel (the creative's CTA opens the advertiser store). Mirrors the interstitial's
    /// `handleHtmlClick` (minus SKOverlay — the rewarded uses post-close fallback ads instead). The
    /// WebView coordinator does the actual store routing.
    private func handleHtmlClick() {
        onClick()
        storeExit?.recordStoreOpen("cta")
    }

    /// Routes a store-prompt tap to the advertised destination (shared CTA router).
    private func handleStorePromptTap() {
        CreativeCTARouter.open(trackingUrl: trackingUrl, destination: destination, storeOpen: storeOpen, storeUrl: storeUrl, attribution: attribution)
    }

    /// Mid-store-prompt click beacon. Wired only to the badge's `onTap` — `handleStorePromptTap` is
    /// also reused by `fireAutoStoreRedirect` (no user tap), which must NOT count as a click.
    private func trackStorePromptClick() {
        // Durable click beacon (was a fire-and-forget trackClick).
        AdBeaconManager.shared.enqueue(impressionId: impressionId, action: "click", adFormat: "rewarded")
    }

    // MARK: Close

    private func finish(earned: Bool) {
        let elapsed = elapsedPlayTime
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            onFinish(earned, elapsed)
        }
    }
}
#endif
