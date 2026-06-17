#if os(iOS)
import SwiftUI
import UIKit
import Combine

// MARK: - InterstitialPresenter

/// Presents the imperative interstitial full-screen in a dedicated `UIWindow`,
/// independent of the host app's view-controller stack.
///
/// The presentation is a native full-screen creative: the server-rendered
/// `rendered_html` displayed in a web view, which owns its own CTA. Hosting in its
/// own window (above `.normal`) lets the imperative API present from anywhere —
/// SwiftUI or UIKit hosts alike.
@MainActor
final class InterstitialPresenter {
    private var window: UIWindow?
    private var onClose: (() -> Void)?
    /// The host's key window, captured before we take key. Restored on dismiss so
    /// the host regains touch/keyboard focus (a new key window doesn't auto-revert).
    private weak var originalKeyWindow: UIWindow?

    /// Presents the native HTML creative. `onClick` fires when a user-initiated link
    /// inside the creative is tapped (CLICKED); `onClose` fires once the window has
    /// been torn down (CLOSED).
    ///
    /// - Returns: `true` if the overlay was presented; `false` if no window scene
    ///   was available (in which case the callbacks are never called).
    @discardableResult
    func present(
        apiKey: String,
        response: AdLoadResponse,
        onClick: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> Bool {
        guard let scene = Self.activeWindowScene() else {
            // No scene to present in — caller decides how to surface this.
            return false
        }
        self.onClose = onClose

        // WebView ↔ SDK bridge (PRD §3). Owned here so the orientation handler can reach the
        // hosting controller + window created below.
        let bridge = CreativeBridge()

        let root = CreativeInterstitialView(
            apiKey: apiKey,
            response: response,
            bridge: bridge,
            onClick: onClick,
            onRequestDismiss: { [weak self] in self?.dismiss() }
        )

        let hosting = OrientationLockingHostingController(rootView: root)
        // Opaque black (not clear) so the host app never shows through during the
        // present/dismiss opacity fade — matches Android's blank-screen transition.
        hosting.view.backgroundColor = .black

        // Remember who held key so we can hand it back on dismiss.
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

    /// Fires the CLOSED callback, then tears down the presentation window — in that order.
    /// The callback brings up the post-close fallback ad window (from a background prefetch, so
    /// it's ready synchronously) on top of this still-visible window; only then do we hide it.
    /// Tearing down first left a frame with neither window covering the screen, which flashed the
    /// app/home behind during the handoff.
    private func dismiss() {
        // Capture the window refs and clear `self`'s references BEFORE invoking the callback: the
        // callback nils the owner's reference to this presenter, so `self` may be deallocated by
        // the time it returns. Operate on the locals afterwards instead of touching `self`.
        let win = window
        let hostKeyWindow = originalKeyWindow
        window = nil
        originalKeyWindow = nil
        let callback = onClose
        onClose = nil
        callback?()
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

// MARK: - CreativeInterstitialView

/// Full-screen native creative: the server-rendered `rendered_html` displayed in a web
/// view on black. The HTML owns its own CTA — a user-initiated link tap inside it is
/// intercepted by the web view's coordinator (which routes to the store/Safari sheet) and
/// reported here as CLICKED.
///
/// The close affordance is driven by the server's `ad_behavior` A/B config when present
/// (`CloseButtonView`: a delay gate plus one of the `treatment` styles); when `ad_behavior`
/// is absent it falls back to today's always-available top-right close button. A mid-ad
/// store-prompt badge (`store_prompt`) and an SKOverlay install banner (`skoverlay`) are
/// layered on per their config.
private struct CreativeInterstitialView: View {
    let apiKey: String
    let response: AdLoadResponse
    /// WebView ↔ SDK bridge (PRD §3). `AD_EARLY_COMPLETE` flips `earlyComplete` (observed below).
    let bridge: CreativeBridge
    let onClick: () -> Void
    let onRequestDismiss: () -> Void

    /// The countdown runs only while the app is foregrounded AND no in-app store/Safari sheet covers
    /// the ad — tracked separately and reconciled in `reconcileGate()`. The ad lives in a stand-alone
    /// `UIWindow`, where SwiftUI's `\.scenePhase` does NOT track the app lifecycle, so foreground
    /// state is driven by `UIApplication` background/foreground notifications instead.
    @State private var appForegrounded = true
    @State private var storeSheetPresented = false

    @State private var visible = true

    /// Whether the close button may be shown/tapped. Starts `false` when a close delay
    /// (`close.delay_seconds`) applies and unlocks once it elapses.
    @State private var closeEnabled: Bool
    /// Cancellable close-delay gate timer. Cancelled in `.onDisappear` so it can't fire
    /// after the surface is gone.
    @State private var gateTask: Task<Void, Never>?
    /// Remaining whole seconds for the close-delay countdown (drives the `reward_or_close_label` copy).
    @State private var closeRemaining: Int
    /// 0→1 fill for the close-delay countdown (`countdown_circle` ring / `progress_bar`).
    @State private var closeProgress: Double = 0
    /// Monotonic anchor (`systemUptime`) for the gate, so a re-`onAppear` resumes the countdown
    /// from where it was instead of restarting it. `nil` until first set.
    @State private var gateStartedAt: TimeInterval?
    /// Total time the gate spent paused (app not foreground-active), excluded from the dwell so
    /// leaving the app pauses the countdown instead of letting it elapse in the background.
    @State private var gatePausedTotal: TimeInterval = 0
    /// `systemUptime` when the current pause began; `nil` while running.
    @State private var gatePausedAt: TimeInterval?

    // Mid-ad store prompt (`store_prompt`) — a tappable badge shown from `closeTime / 2` until the
    // real close button appears.
    @State private var storePromptVisible = false
    @State private var storePromptScheduled = false
    @State private var storePromptTask: Task<Void, Never>?

    // SKOverlay install banner (`skoverlay`) — resolved app id + one-shot presentation.
    @State private var resolvedAppID: String?
    @State private var skOverlayPresented = false
    @State private var skOverlayTask: Task<Void, Never>?

    // auto_store_redirect — fires the store open once, the first time the creative reports the
    // configured moment.
    @State private var autoRedirectFired = false

    /// Matches the dismiss fade before the window is removed.
    private let dismissAnimationDuration: TimeInterval = 0.25

    init(
        apiKey: String,
        response: AdLoadResponse,
        bridge: CreativeBridge,
        onClick: @escaping () -> Void,
        onRequestDismiss: @escaping () -> Void
    ) {
        self.apiKey = apiKey
        self.response = response
        self.bridge = bridge
        self.onClick = onClick
        self.onRequestDismiss = onRequestDismiss
        // Close starts enabled unless the server-driven `close.delay_seconds` gates it.
        let closeDelay = response.adBehavior?.close.delaySeconds ?? 0
        _closeEnabled = State(initialValue: closeDelay <= 0)
        // Initial label count (`reward_or_close_label`): whole seconds of the close delay.
        _closeRemaining = State(initialValue: max(0, closeDelay))
    }

    /// Whether the `reward_or_close_label` should read "Reward in X" (vs "Close in X"), inferred
    /// from the creative's declared ad-unit type.
    private var isRewardCopy: Bool { response.adUnitType == .rewarded }

    /// The close config to render: the server's `ad_behavior.close` when present, else a default
    /// (compact, always-available top-right X) so ads without `ad_behavior` still get a small close.
    private var closeConfig: CloseBehavior { response.adBehavior?.close ?? CloseBehavior() }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The server-rendered HTML creative, full-screen. It owns its own CTA.
            if let html = response.htmlCreative {
                htmlCreativeView(html)
            }

            // Close button — always shown with the compact AppLovin-style chrome. Driven by
            // `ad_behavior.close` when present; otherwise a default config (top-right, always
            // available) so ads with no `ad_behavior` still get the small close, not a big one.
            CloseButtonView(
                treatment: closeConfig.treatment,
                position: closeConfig.position,
                progressBarColor: closeConfig.progressBarColor,
                isRewardCopy: isRewardCopy,
                enabled: closeEnabled,
                remaining: closeRemaining,
                progress: closeProgress,
                onClose: { handleClose() }
            )

            // Mid-ad store prompt — independent of the close button and SKOverlay. Pinned to the
            // corner opposite the close button (the SDK mirrors the close position horizontally)
            // during the [closeTime/2, closeTime) window; `!closeEnabled` removes it the instant
            // the real close button appears.
            if let prompt = response.adBehavior?.storePrompt, prompt.enabled, storePromptVisible, !closeEnabled {
                // Center the badge in the same 44pt touch-target band as the close button (so they line up).
                StorePromptBadge(prompt: prompt, closePosition: closeConfig.position, rowHeight: 44, onTap: { trackStorePromptClick(); handleStorePromptTap() })
            }

            // Persistent ad-info "i" + report sheet (required disclosure). Last in the ZStack so the
            // report sheet overlays the creative + close button when open.
            AdInfoReportOverlay(
                adId: response.impressionId,
                apiKey: apiKey,
                // A genuine bottom-left ✕ shares the bottom-left corner with the "i" (shrink its hit area);
                // a progress_bar bottom ✕ relocates to top-right, leaving the "i" its full hit area.
                closeAtBottomLeft: closeConfig.position == .bottomLeft && !closeBarAtBottom(closeConfig.treatment, closeConfig.position)
            )
        }
        .opacity(visible ? 1 : 0)
        // Once a dismiss starts (`visible == false`) the surface is still on screen during the
        // 0.25s fade — opacity 0 does NOT stop hit-testing. Disable touches so a second close tap
        // in that window can't double-fire.
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: dismissAnimationDuration), value: visible)
        .hideStatusBar(true)
        .onAppear {
            startGate()
            startStorePromptTrigger()
            startSKOverlay()
            // PLAYABLE_END: if the close button is already available (delay 0), fire immediately.
            fireAutoStoreRedirectIfCloseShown()
        }
        .onDisappear {
            gateTask?.cancel()
            gateTask = nil
            storePromptTask?.cancel()
            storePromptTask = nil
            skOverlayTask?.cancel()
            skOverlayTask = nil
            // Tear the install banner down with the ad so it doesn't leak into the host app.
            if skOverlayPresented, #available(iOS 14.0, *) {
                SKOverlayPresenter.dismiss()
            }
        }
        // Pause the close countdown while the app is backgrounded OR an in-app store/Safari sheet
        // covers the ad; resume only when both clear, so the gate can't elapse off-screen.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            appForegrounded = false
            reconcileGate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            appForegrounded = true
            reconcileGate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetWillPresent)) { _ in
            storeSheetPresented = true
            reconcileGate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetDidDismiss)) { _ in
            storeSheetPresented = false
            reconcileGate()
        }
        // AD_EARLY_COMPLETE (PRD §3): the creative finished early, so unlock the close button
        // immediately, cancelling the close-delay gate.
        .onReceive(bridge.$earlyComplete) { earlyComplete in
            guard earlyComplete, !closeEnabled else { return }
            gateTask?.cancel()
            gateTask = nil
            withAnimation(.easeInOut(duration: 0.2)) { closeEnabled = true }
        }
        // PLAYABLE_END (auto_store_redirect): open the store the moment the close button appears.
        .onChange(of: closeEnabled) { enabled in
            if enabled { fireAutoStoreRedirectIfCloseShown() }
        }
    }

    // MARK: auto_store_redirect

    /// Opens the advertiser store once (no user tap) — shared by every auto_store_redirect trigger.
    private func fireAutoStoreRedirect() {
        guard !autoRedirectFired else { return }
        autoRedirectFired = true
        handleStorePromptTap()
    }

    /// PLAYABLE_END — fire once the close button is available (SDK-native, no bridge).
    /// (END_SCREEN_1/2_OPEN are handled in the post-close fallback flow, by index — see
    /// `SimulaInterstitialAd.presentFallbackAds` / `FallbackAdPresenter`.)
    private func fireAutoStoreRedirectIfCloseShown() {
        guard closeEnabled,
              let redirect = response.adBehavior?.autoStoreRedirect, redirect.enabled,
              redirect.trigger == .playableEnd else { return }
        fireAutoStoreRedirect()
    }

    // MARK: HTML creative

    @ViewBuilder
    private func htmlCreativeView(_ html: String) -> some View {
        WebViewRepresentable(
            htmlString: html,
            onAdClick: { handleHtmlClick() },
            bridge: bridge,
            attribution: response.adBehavior?.attribution
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        // Sits below the safe area (the black backdrop fills the notch / home-indicator region).
    }

    // MARK: Actions

    /// Fired when a user-initiated link inside the HTML creative is intercepted by the web view.
    /// The coordinator routes the tapped link to the store/Safari sheet (which presents over this
    /// still-live interstitial window), so here we only emit CLICKED and, when configured, present
    /// an `on_click`-timed SKOverlay. We intentionally do NOT auto-dismiss: tearing the window down
    /// would destroy the just-presented sheet. Dismissal is driven by the close button.
    private func handleHtmlClick() {
        onClick() // CLICKED
        presentSKOverlayOnClickIfNeeded()
    }

    private func handleClose() {
        // Fade the whole surface out, then remove the hosting window.
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            onRequestDismiss()
        }
    }

    /// Close-delay gate. The interstitial gates its close button on the server-driven
    /// `close.delay_seconds`. The active `treatment` drives the affordance: `countdown_circle`/
    /// `progress_bar` fill `closeProgress`, `reward_or_close_label` ticks `closeRemaining`,
    /// `hidden` shows nothing until it unlocks.
    private func startGate() {
        // Don't double-start: a running gate is paused via `pauseGate()` (which nils `gateTask`).
        guard gateTask == nil else { return }
        guard let close = response.adBehavior?.close else { return }
        let treatment = close.treatment
        let total = TimeInterval(close.delaySeconds)

        guard total > 0, !closeEnabled else { return }

        // Resume from the monotonic anchor so a re-`onAppear` doesn't restart the countdown.
        let remaining = remainingGateTime(total: total)
        if remaining <= 0 {
            closeEnabled = true
            return
        }

        // Ring / bar treatments fill linearly over the remaining delay (resuming from the fraction
        // already elapsed, so a re-`onAppear` doesn't snap the fill back to 0).
        if treatment == .countdownCircle || treatment == .progressBar {
            closeProgress = (total - remaining) / total
            withAnimation(.linear(duration: remaining)) { closeProgress = 1 }
        }

        // Cancellable gate: a fire-and-forget asyncAfter would still fire after dismiss and mutate
        // dead @State. The Task is cancelled in `.onDisappear`.
        gateTask = Task { @MainActor in
            if treatment == .rewardOrCloseLabel {
                var left = Int(ceil(remaining))
                closeRemaining = left
                while left > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    left -= 1
                    closeRemaining = left
                }
            } else {
                // UInt64(negative or non-finite) traps; only sleep for a sane positive duration.
                let sleepNs = remaining * 1_000_000_000
                if sleepNs.isFinite, sleepNs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(sleepNs))
                }
            }
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.2)) { closeEnabled = true }
        }
    }

    /// Pauses the close-delay countdown when the app leaves the foreground: stops accruing dwell and
    /// freezes the in-flight ring/bar fill so it can't elapse while backgrounded.
    private func pauseGate() {
        guard let close = response.adBehavior?.close, close.delaySeconds > 0, !closeEnabled else { return }
        gateTask?.cancel()
        gateTask = nil
        if gatePausedAt == nil { gatePausedAt = ProcessInfo.processInfo.systemUptime }
        if close.treatment == .countdownCircle || close.treatment == .progressBar {
            let total = TimeInterval(close.delaySeconds)
            let fraction = min(1, max(0, (total - remainingGateTime(total: total)) / total))
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { closeProgress = fraction }
        }
    }

    /// Resumes the countdown when the app returns to the foreground: folds the paused interval into
    /// the excluded total and restarts from where it left off.
    private func resumeGate() {
        if let pausedAt = gatePausedAt {
            gatePausedTotal += ProcessInfo.processInfo.systemUptime - pausedAt
            gatePausedAt = nil
        }
        startGate()
    }

    /// Runs the gate only while the app is foregrounded and no in-app store sheet covers the ad.
    private func reconcileGate() {
        if appForegrounded && !storeSheetPresented { resumeGate() } else { pauseGate() }
    }

    // MARK: Store prompt (mid-ad)

    /// Schedules the mid-ad store prompt at the halfway point to the close button (`closeTime / 2`,
    /// where closeTime is the server-driven close delay). The badge is removed once the real close
    /// button appears (the `!closeEnabled` render guard). When the close is immediately available
    /// (no gate) there is no pre-close window, so it never schedules.
    private func startStorePromptTrigger() {
        guard let prompt = response.adBehavior?.storePrompt, prompt.enabled,
              !storePromptScheduled, !storePromptVisible else { return }
        let closeDelay = response.adBehavior?.close.delaySeconds ?? 0
        guard closeDelay > 0 else { return }
        storePromptScheduled = true
        storePromptTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Double(closeDelay) / 2 * 1_000_000_000))
            if Task.isCancelled { return }
            showStorePrompt()
        }
    }

    /// Reveals the store prompt. Idempotent — driven by the `closeTime / 2` timer.
    private func showStorePrompt() {
        guard !storePromptVisible else { return }
        withAnimation(.easeInOut(duration: 0.25)) { storePromptVisible = true }
    }

    /// Routes a store-prompt tap to the same destination as the CTA (shared router).
    private func handleStorePromptTap() {
        let storeOpen = response.adBehavior?.storeOpen ?? .skstoreproduct
        CreativeCTARouter.open(
            trackingUrl: response.trackingUrl,
            destination: response.destinationKind,
            storeOpen: storeOpen,
            attribution: response.adBehavior?.attribution
        )
    }

    /// Mid-store-prompt click beacon. Wired only to the badge's `onTap` — `handleStorePromptTap` is
    /// also reused by `fireAutoStoreRedirect` (no user tap), which must NOT count as a click.
    private func trackStorePromptClick() {
        let adId = response.impressionId
        let apiKey = self.apiKey
        Task { await SimulaAPI.shared.trackClick(adId: adId, apiKey: apiKey) }
    }

    // MARK: SKOverlay (install banner)

    /// Resolves the advertised app id once, then presents the SKOverlay per its timing. `duringPlay`
    /// / `delayed` present automatically (after the optional `delay_seconds`); `onClick` waits for
    /// the CTA tap. iOS 14+ only — below that the config is simply ignored.
    private func startSKOverlay() {
        guard let config = response.adBehavior?.skoverlay, config.enabled, resolvedAppID == nil else { return }
        guard #available(iOS 14.0, *) else { return }
        CreativeCTARouter.resolveAppStoreID(
            trackingUrl: response.trackingUrl,
            destination: response.destinationKind
        ) { id in
            resolvedAppID = id
            if config.timing == .duringPlay || config.timing == .delayed {
                scheduleSKOverlayPresent(config: config)
            }
        }
    }

    private func scheduleSKOverlayPresent(config: SKOverlayConfig) {
        guard !skOverlayPresented, resolvedAppID != nil else { return }
        skOverlayTask?.cancel()
        skOverlayTask = Task { @MainActor in
            if config.delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(config.delaySeconds) * 1_000_000_000)
            }
            if Task.isCancelled { return }
            presentSKOverlay(config: config)
        }
    }

    /// Presents the SKOverlay once the app id is known. Best-effort: a nil id (unresolvable store
    /// link) safely no-ops with a console warning.
    private func presentSKOverlay(config: SKOverlayConfig) {
        guard !skOverlayPresented, let appID = resolvedAppID, !appID.isEmpty else {
            if resolvedAppID == nil || resolvedAppID?.isEmpty == true {
                print("[Simula] SKOverlay skipped: could not resolve an App Store id for this creative.")
            }
            return
        }
        guard #available(iOS 14.0, *) else { return }
        skOverlayPresented = true
        SKOverlayPresenter.present(appID: appID, config: config, attribution: response.adBehavior?.attribution)
    }

    /// Presents an `onClick`-timed SKOverlay when the CTA is tapped (the app id was resolved on appear).
    private func presentSKOverlayOnClickIfNeeded() {
        guard let config = response.adBehavior?.skoverlay, config.enabled, config.timing == .onClick else { return }
        presentSKOverlay(config: config)
    }

    /// Seconds left on the active gate, anchored to a monotonic clock the first time it's asked.
    /// Reusing one anchor across `onAppear` calls means the countdown resumes instead of resetting.
    private func remainingGateTime(total: TimeInterval) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        let startedAt = gateStartedAt ?? now
        if gateStartedAt == nil { gateStartedAt = startedAt }
        // Subtract time spent paused (app backgrounded / not foreground-active) so the dwell only
        // counts foreground time — leaving the app pauses the countdown.
        return total - (now - startedAt - gatePausedTotal)
    }
}

// MARK: - CloseButtonView

/// Height of the `progressBar` gate bar.
let closeProgressBarHeight: CGFloat = 4
/// When the gate bar sits at the bottom (progressBar at bottomLeft), raise it this far above the safe
/// edge so it clears the bottom-left info "i" (a 16pt circle inset 6pt from the corner ≈ 22pt tall).
let closeBottomBarLift: CGFloat = 26

/// True for the `progressBar` treatment pinned to `bottomLeft`: the gate bar then spans the bottom,
/// so the ✕ moves up to the top-right (it can't sit on the bar) and the bar itself is raised to sit
/// just above the info "i" (which keeps its corner spot). For every OTHER bottomLeft close the ✕ stays
/// bottom-left. (The store prompt sits top-right for any bottomLeft close — see `StorePromptBadge`.)
func closeBarAtBottom(_ treatment: CloseTreatment, _ position: ClosePosition) -> Bool {
    treatment == .progressBar && position == .bottomLeft
}

/// The `ad_behavior`-driven close button. Renders the assigned `treatment` at the configured
/// corner: `hidden` shows nothing until the gate unlocks, `countdownCircle` draws a ring,
/// `progressBar` a top-edge bar, `rewardOrCloseLabel` a counting-down text pill. `progressBarColor`
/// tints the ring/bar fill. The `rewardOrCloseLabel` copy is reward- vs interstitial-aware.
struct CloseButtonView: View {
    let treatment: CloseTreatment
    let position: ClosePosition
    let progressBarColor: String
    /// `true` → "Reward in X"; `false` → "Close in X" (only used by `rewardOrCloseLabel`).
    let isRewardCopy: Bool
    let enabled: Bool
    let remaining: Int
    let progress: Double
    let onClose: () -> Void

    // Visible close affordance sized to match AppLovin (a compact ~22pt circle); the tappable frame
    // stays at the 44pt HIG minimum (see `minTouchTarget`), close to IAB MRAID's 50×50dp close
    // region. The visible graphic and the touch target are deliberately decoupled.
    private let glyphSize: CGFloat = 10
    private let circleSize: CGFloat = 16
    private let minTouchTarget: CGFloat = 44

    /// Tappable footprint, used identically by the in-delay indicator and the unlocked button so the
    /// glyph keeps the same size/position and doesn't jump when the close button activates.
    private var touchSize: CGFloat { max(minTouchTarget, circleSize) }

    /// Fill tint for the ring / bar. Validated upstream, so `Color(hex:)` always gets clean input.
    private var tint: Color { Color(hex: progressBarColor) }

    /// For the progress_bar treatment, the gate bar takes the bottom edge when pinned bottom_left.
    private var barAtBottom: Bool { closeBarAtBottom(treatment, position) }

    /// The ✕ honors its configured corner, EXCEPT progress_bar at bottom_left: the gate bar takes the
    /// bottom edge there, so the ✕ moves up to the top-right.
    private var cornerAlignment: Alignment {
        if barAtBottom { return .topTrailing }
        switch position {
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        case .bottomLeft: return .bottomLeading
        }
    }

    var body: some View {
        ZStack {
            // `progress_bar` treatment: a full-width bar, shown during the delay and tinted by color.
            // Pinned to the top edge by default; at bottom_left it sits on the bottom edge instead.
            if !enabled && treatment == .progressBar {
                progressBar
            }

            // The button (or its in-delay indicator), pinned to the configured corner. An explicit
            // fill-and-align frame is used (NOT VStack/HStack + Spacer): the Spacer approach can
            // collapse to center when this view sits beside the `.ignoresSafeArea()` web view and
            // isn't proposed a full-size container, which made every position render at the same spot.
            // A tight 8pt inset keeps the button close to the corner (AdMob / AppLovin-style).
            buttonOrIndicator
                // Center every state in the touch-target band so the gated pill / ring and the
                // unlocked ✕ share one centerline (and line up with the store badge).
                .frame(height: touchSize)
                .padding(8)
                // A genuine bottom-left ✕ nudges right to clear the info "i" beside it; the relocated
                // (top-right) ✕ of the progress_bar bottom layout doesn't need it.
                .padding(.leading, (position == .bottomLeft && !barAtBottom) ? 4 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cornerAlignment)
        }
    }

    /// The full-width progress bar for the `progress_bar` treatment — spanning edge-to-edge, pinned
    /// just inside the top safe-area inset (clearing the notch); at bottom_left it sits near the
    /// bottom, raised just above the info "i" so the two don't overlap (the "i" keeps its corner spot).
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.25))
                Rectangle().fill(tint)
                    .frame(width: max(0, geo.size.width * progress))
            }
        }
        .frame(height: closeProgressBarHeight)
        .padding(.bottom, barAtBottom ? closeBottomBarLift : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: barAtBottom ? .bottom : .top)
    }

    @ViewBuilder
    private var buttonOrIndicator: some View {
        if enabled {
            // Unlocked: the compact ✕ for every treatment (matches all other close buttons).
            Button(action: onClose) {
                closeGlyph
                    .frame(width: touchSize, height: touchSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        } else {
            switch treatment {
            case .hidden, .progressBar:
                EmptyView() // nothing in the corner during the delay (the bar shows separately)
            case .countdownCircle:
                ZStack {
                    closeGlyph.opacity(0.5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: circleSize, height: circleSize)
                }
                // Same footprint as the unlocked button so the glyph doesn't jump when it activates.
                .frame(width: touchSize, height: touchSize)
            case .rewardOrCloseLabel:
                labelPill(text: "\(isRewardCopy ? "Reward" : "Close") in \(remaining)")
            }
        }
    }

    /// The circular "X" glyph — a gray / translucent dark circle with a white X (AdMob / AppLovin
    /// style), rather than an opaque white circle.
    private var closeGlyph: some View {
        Image(systemName: "xmark")
            .font(.system(size: glyphSize, weight: .bold))
            .foregroundColor(.white)
            .frame(width: circleSize, height: circleSize)
            .background(Circle().fill(Color.black.opacity(0.5)))
    }

    /// The text pill used by the `rewardOrCloseLabel` treatment (counting down, then "Close").
    /// Compact, to match the small close chrome of the other treatments.
    private func labelPill(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.black.opacity(0.5)))
    }
}

// MARK: - StorePromptBadge

/// The mid-ad store prompt (`store_prompt`): a tappable skip-next ▶| badge labelled "App Store" / "Google Play"
/// rendered at the server-resolved corner. The SDK never recomputes the position — it trusts the
/// backend's collision resolution (opposite the close button). Shared with the rewarded minigame
/// (`RewardedPresenter`).
struct StorePromptBadge: View {
    let prompt: StorePrompt
    /// The close button's CONFIG corner. The badge sits top-right for a bottom_left close (diagonally
    /// opposite a bottom-left ✕, or sharing the corner with a progress_bar bottom ✕ that relocated
    /// there), and in the horizontal mirror of the close corner otherwise (top-right ↔ top-left). The
    /// server's `store_prompt.position` is not used for layout.
    let closePosition: ClosePosition
    /// Inset from the safe-area edge. Both the interstitial and the rewarded minigame use 8 so the
    /// badge shares its close affordance's baseline.
    var edgePadding: CGFloat = 8
    /// When set, the pill is vertically centered within this height so it lines up with a close
    /// button whose glyph sits in a touch-target band (the interstitial). nil → bare pill (rewarded).
    var rowHeight: CGFloat? = nil
    let onTap: () -> Void

    private var label: String {
        prompt.platform == .android ? "Google Play" : "App Store"
    }
    private var cornerAlignment: Alignment {
        switch closePosition {
        case .topRight: return .topLeading               // mirror of a top-right close
        // top_left mirrors to top-right; bottom_left relocates to top-right (same corner as the ✕).
        case .topLeft, .bottomLeft: return .topTrailing
        }
    }

    var body: some View {
        badge
            // nil → bare pill (rewarded); set → centered within the band so it lines up with the
            // interstitial close button's touch-target row.
            .frame(height: rowHeight)
            .padding(edgePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cornerAlignment)
    }

    // Compact AppLovin-style pill: the filled skip-next glyph (`forward.end.fill` ≈ ▶|) then the
    // store name, with tight padding, a fully-rounded (capsule) outline, and a small gap between
    // the two.
    private var badge: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 8, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Capsule().fill(Color.black.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Install")
    }
}
#endif
