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
    private var creativeBridge: CreativeBridge?
    /// Fired once on teardown with whether the reward was earned and the measured
    /// play time, so the caller can verify the play server-side.
    private var onClose: ((Bool, Double, FullscreenPresentationLease, UIWindow?) -> Void)?
    private var presentationLease: FullscreenPresentationLease?
    /// The host's key window, captured before we take key. Restored on dismiss so the
    /// host regains touch/keyboard focus (a new key window doesn't auto-revert).
    private weak var originalKeyWindow: UIWindow?
    /// Deliberate self-retention while the window is on screen. The presentation must survive
    /// its owning ad object: a host can release the ad mid-unit (e.g. React Native's
    /// `destroy()` on unmount, or an error handler recreating the instance), and since UIKit
    /// does not retain windows, dropping the last reference to this presenter would deallocate
    /// the window and rip the ad off screen. Set on a successful `present`, released in
    /// `dismiss` (the only teardown path — close remains user-driven).
    private var retainedWhilePresenting: RewardedPresenter?

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
        onWillPresent: () -> Void = {},
        onClick: @escaping (ClickInteraction) -> Void,
        onImpression: @escaping () -> Void,
        onClose: @escaping (Bool, Double, FullscreenPresentationLease, UIWindow?) -> Void
    ) -> Bool {
        guard presentationLease == nil else { return false }
        let presentationLease = FullscreenPresentationRegistry.shared.claim()
        guard let scene = preferredForegroundActiveWindowScene() else {
            presentationLease.releaseAfterPresentationFailure()
            return false
        }
        self.presentationLease = presentationLease
        self.onClose = onClose

        // WebView ↔ SDK bridge (PRD §3): the creative can request early completion, haptics,
        // orientation lock, and device/audio/orientation queries. Owned here so the orientation
        // handler can reach the hosting controller + window created below.
        let bridge = CreativeBridge()
        creativeBridge = bridge

        let root = RewardedGameView(
            impressionId: impressionId,
            apiKey: apiKey,
            originatingScene: scene,
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
        // Apply StoreKit prewarm policy before SwiftUI `onAppear` can fire an automatic route.
        onWillPresent()
        window.makeKeyAndVisible()
        self.window = window
        retainedWhilePresenting = self
        // Give the bridge the orientation host + window now that they exist.
        bridge.orientationHost = hosting
        bridge.window = window
        // Hide the status bar in hosts that opted out of VC-based appearance (e.g. React Native),
        // where `.hideStatusBar(true)` in the creative view is a no-op. No-op in native hosts.
        SimulaAppStatusBar.hide()
        return true
    }

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
        onWillPresent: () -> Void = {},
        onClick: @escaping () -> Void,
        onImpression: @escaping () -> Void,
        onClose: @escaping (Bool, Double, FullscreenPresentationLease, UIWindow?) -> Void
    ) -> Bool {
        present(
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
            onWillPresent: onWillPresent,
            onClick: { _ in onClick() },
            onImpression: onImpression,
            onClose: onClose
        )
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
        let bridge = creativeBridge
        creativeBridge = nil
        bridge?.stop()
        window = nil
        originalKeyWindow = nil
        let callback = onClose
        onClose = nil
        let presentationLease = presentationLease
        self.presentationLease = nil
        // Release the presentation-scoped self-retention. The caller's reference keeps `self`
        // alive through this method even when this was the last strong reference.
        retainedWhilePresenting = nil
        if let presentationLease {
            if let callback {
                callback(earned, elapsedPlayTime, presentationLease, hostKeyWindow)
            } else {
                presentationLease.finishPostCloseTeardown()
            }
        }
        let shouldRestoreHostKeyWindow = win?.isKeyWindow == true
        // Balanced with the present-time hide() (after the callback so a fallback presented in it
        // keeps the bar hidden across the handoff via the ref count).
        SimulaAppStatusBar.restore()
        win?.isHidden = true
        win?.rootViewController = nil
        // Restore the host only when the primary still owns key status. A successor fallback or
        // loading window made key by the callback owns the handoff until its final dismiss.
        if shouldRestoreHostKeyWindow {
            hostKeyWindow?.makeKey()
        }
        presentationLease?.finishPrimaryTeardown()
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
    let originatingScene: UIWindowScene
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
    let onClick: (ClickInteraction) -> Void
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

    @State private var gateClock = RewardedGateClock()
    /// Smoothly-animated 0→1 fill for the close bar/ring. Driven by a linear animation over the
    /// remaining gate (re-anchored on pause/resume) so the indicator glides instead of stepping once
    /// per 1 s accrual tick — `closeProgress` below is the instantaneous truth used to anchor it.
    @State private var closeProgressAnim: Double = 0
    @State private var rewardEarned = false
    @State private var storePromptVisible = false
    @State private var storePromptGestureGuard = StorePromptGestureGuard()
    @State private var clickHandoffs = FullscreenClickHandoffState()
    @State private var attributionRouteLifecycle = AttributionRouteLifecycle()
    @State private var visible = true
    @State private var timerTask: Task<Void, Never>?
    // Billable IMPRESSION + PAID — fired once, after `fullscreenImpressionDelayMs` of foreground
    // on-screen time from begin-to-render. Independent of the play-to-earn timer / reward gate.
    @State private var impressionFired = false
    @State private var impressionTask: Task<Void, Never>?

    /// Matches the dismiss fade before the window is removed.
    private let dismissAnimationDuration: TimeInterval = 0.25

    /// Play-to-earn gate length, in seconds — sourced from `ad_behavior.close.delay_seconds` (the
    /// same value that ungates the close button). `nil` close → 0 → instantly earned.
    private var gateSeconds: Int { close?.delaySeconds ?? 0 }

    private var gateDuration: TimeInterval { TimeInterval(gateSeconds) }

    private var secondsLeft: Int {
        gateClock.secondsRemaining(total: gateDuration)
    }

    /// Instantaneous 0→1 play-to-earn fraction. Not rendered directly — `closeProgressAnim` glides
    /// between these values and re-anchors here when the timer pauses or resumes.
    private var closeProgress: Double {
        gateClock.progress(total: gateDuration)
    }

    private var clickHandoffPending: Bool { clickHandoffs.isPending }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Sits below the safe area (the black backdrop fills the notch / home-indicator region).
            // ctaDestination/ctaStoreUrl thread the serve's routing context into the coordinator so
            // an in-playable CTA opens the store deterministically (in-app sheet + background
            // tracker fire) instead of sniffing the tracker's redirect chain.
            if let previewHTML {
                creativeWebView(html: previewHTML)
            } else if !renderedHtml.isEmpty {
                // Prefer the server-rendered HTML (parity with the interstitial, which fills the
                // surface); fall back to the iframe URL. A user-gesture CTA tap fires CLICKED via
                // onAdClick and routes through the store sheet carrying any SKAN attribution.
                creativeWebView(html: renderedHtml)
            } else if let url = URL(string: iframeUrl) {
                creativeWebView(url: url)
            }

            // Close button — honors the server `ad_behavior.close` treatment (hidden / countdown ring /
            // progress bar / reward-or-close label) exactly like the interstitial, but gated on the
            // play-to-earn progress: the ✕ unlocks only once the reward is earned.
            CloseButtonView(
                treatment: (close ?? CloseBehavior()).treatment,
                position: (close ?? CloseBehavior()).position,
                progressBarColor: (close ?? CloseBehavior()).progressBarColor,
                isRewardCopy: true,
                enabled: canDismissFullscreen(
                    dismissUnlocked: rewardEarned,
                    clickHandoffPending: clickHandoffPending
                ),
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
                StorePromptBadge(prompt: prompt, closePosition: (close ?? CloseBehavior()).position, edgePadding: 8, rowHeight: 44, onTap: { handleStorePromptClick() })
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
            attributionRouteLifecycle.activate()
            if storeExit == nil { storeExit = StoreExitTracker(adId: impressionId, adFormat: "rewarded") }
            startTimer()
            startImpressionTimer()
            // PLAYABLE_END: if the reward was already earned (duration 0), fire immediately.
            fireAutoStoreRedirectIfCloseShown()
        }
        .onDisappear {
            attributionRouteLifecycle.deactivate()
            timerTask?.cancel()
            timerTask = nil
            impressionTask?.cancel()
            impressionTask = nil
            storeExit?.onAdClosed() // resolve any outstanding store visit as an abandon
            storePromptGestureGuard.release()
            clickHandoffs.reset()
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
            storePromptGestureGuard.releaseAfterExternalReturn()
            reconcileTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetWillPresent)) { _ in
            storeSheetPresented = true
            storeExit?.onAway()
            reconcileTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetDidDismiss)) { _ in
            storeSheetPresented = false
            storeExit?.onReturn()
            storePromptGestureGuard.releaseAfterExternalReturn()
            reconcileTimer()
        }
        // AD_EARLY_COMPLETE (PRD §3): the creative finished early (e.g. survey done), so grant the
        // reward and reveal the close button immediately, bypassing the play timer.
        .onReceive(bridge.$earlyComplete) { earlyComplete in
            guard earlyComplete, !rewardEarned else { return }
            timerTask?.cancel()
            timerTask = nil
            gateClock.pause(at: ProcessInfo.processInfo.systemUptime, total: gateDuration)
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
        guard visible else { return }
        attributionRouteLifecycle.automaticRoutes.requestAutomaticRoute(
            scope: attributionRouteLifecycle.automaticRouteScope
        ) {
            let execution = AttributionRouteExecution(
                originatingScene: originatingScene,
                isActive: {
                    attributionRouteLifecycle.isActive
                        && visible
                        && UIApplication.shared.applicationState == .active
                },
                onOutcome: { outcome in
                    recordAttributionRoute(outcome: outcome, source: .autoRedirect)
                    if outcome.success { storeExit?.recordStoreOpen("auto_redirect") }
                }
            )
            handleStorePromptTap(execution: execution)
        }
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
        // Glide the bar/ring fill linearly to full over the remaining gate. The monotonic clock keeps
        // fractional elapsed time so pausing for StoreKit cannot snap the indicator to a prior second.
        gateClock.resume(at: ProcessInfo.processInfo.systemUptime)
        let remaining = gateClock.remaining(total: gateDuration)
        closeProgressAnim = closeProgress
        if remaining > 0 {
            withAnimation(.linear(duration: remaining)) { closeProgressAnim = 1 }
        }
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        timerTask = Task { await runPlayTimer() }
    }

    /// Play-to-earn timer task body (named method — see the task-shape note in TelemetryManager).
    @MainActor
    private func runPlayTimer() async {
        while gateClock.elapsed < gateDuration && !Task.isCancelled {
            // Resume at the next elapsed-second boundary rather than starting a fresh one-second
            // sleep, preserving the countdown phase after a fractional StoreKit pause.
            let sleepSeconds = gateClock.timeUntilNextTick(total: gateDuration)
            let sleepNanos = sleepSeconds * 1_000_000_000
            guard sleepNanos.isFinite, sleepNanos > 0, sleepNanos < Double(UInt64.max) else { return }
            // do/catch, not `try?` — see the task-shape note in TelemetryManager.
            do { try await Task.sleep(nanoseconds: UInt64(sleepNanos)) } catch { return }
            if Task.isCancelled { return }
            gateClock.update(at: ProcessInfo.processInfo.systemUptime, total: gateDuration)
            applyElapsedPlayTime()
        }
    }

    private func applyElapsedPlayTime() {
        // Reveal the store prompt at the halfway point to the reward (mid play-to-earn).
        if gateClock.elapsed >= gateDuration / 2, !storePromptVisible {
            withAnimation(.easeInOut(duration: 0.25)) { storePromptVisible = true }
        }
        if gateClock.elapsed >= gateDuration {
            rewardEarned = true
        }
    }

    /// Fires the billable IMPRESSION + PAID once, after the playable has been on screen for
    /// `fullscreenImpressionDelayMs` of FOREGROUND time from begin-to-render — independent of the
    /// play-to-earn gate. OMID measures viewability but does not gate us (PRD). Accrues only while
    /// foreground-active and no store/Safari sheet covers the playable (same gating as the play timer),
    /// so a backgrounded playable can't accrue the delay. Cancelled in `.onDisappear`.
    private func startImpressionTimer() {
        guard !impressionFired, impressionTask == nil else { return }
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        impressionTask = Task { await runImpressionTimer() }
    }

    /// Impression timer task body (named method — see the task-shape note in TelemetryManager).
    @MainActor
    private func runImpressionTimer() async {
        var accruedMs: Double = 0
        var lastTick = ProcessInfo.processInfo.systemUptime
        while accruedMs < fullscreenImpressionDelayMs {
            // do/catch, not `try?` — see the task-shape note in TelemetryManager.
            do { try await Task.sleep(nanoseconds: impressionTickNanos) } catch { return }
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

    /// Runs the play-to-earn timer only while foreground-active and no in-app store sheet covers the
    /// playable.
    private func reconcileTimer() {
        if appForegrounded && !storeSheetPresented {
            if !rewardEarned { startTimer() }
        } else {
            timerTask?.cancel()
            timerTask = nil
            gateClock.pause(at: ProcessInfo.processInfo.systemUptime, total: gateDuration)
            applyElapsedPlayTime()
            // Freeze the animated fill at the true elapsed fraction so it stops gliding while paused
            // (disable the implicit animation so it doesn't tween toward the frozen value).
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { closeProgressAnim = closeProgress }
        }
    }

    /// A user-gesture CTA tap inside the playable surfaces CLICKED to the publisher. The WebView
    /// coordinator reports the terminal route outcome separately, and only a successful route marks
    /// the store-exit funnel.
    private func handleHtmlClick(_ interaction: ClickInteraction) {
        onClick(interaction)
    }

    private func creativeWebView(url: URL? = nil, html: String? = nil) -> some View {
        WebViewRepresentable(
            url: url,
            htmlString: html,
            onAdClick: { handleHtmlClick($0) },
            onClickHandoffPendingChanged: {
                clickHandoffs.set(.creative, pending: $0)
            },
            onAttributionRouteOutcome: { outcome in
                if outcome.success { storeExit?.recordStoreOpen("cta") }
            },
            attributionRouteLifecycle: attributionRouteLifecycle,
            clickBeaconImpressionId: impressionId,
            bridge: bridge,
            attribution: attribution,
            ctaTrackingUrl: trackingUrl,
            ctaDestination: destination,
            ctaStoreOpen: storeOpen,
            ctaStoreUrl: storeUrl,
            telemetryAdFormat: "rewarded"
        )
        .allowsHitTesting(!clickHandoffPending)
    }

    /// Routes a store-prompt tap to the advertised destination (shared CTA router).
    private func handleStorePromptTap(execution: AttributionRouteExecution) {
        CreativeCTARouter.open(
            trackingUrl: trackingUrl,
            destination: destination,
            storeOpen: storeOpen,
            storeUrl: storeUrl,
            attribution: attribution,
            execution: execution
        )
    }

    private func handleStorePromptClick() {
        guard !clickHandoffs.isPending(.creative), storePromptGestureGuard.claim() else { return }
        guard let automaticUserHandoff = attributionRouteLifecycle.automaticRoutes.beginUserHandoff(
            scope: attributionRouteLifecycle.automaticRouteScope
        ) else {
            storePromptGestureGuard.release()
            return
        }
        clickHandoffs.set(.storePrompt, pending: true)
        let gestureGuard = storePromptGestureGuard
        let interaction = ClickInteraction(source: .storePrompt)
        onClick(interaction)
        ClickHandoffPersistence.wait(
            interaction: interaction,
            beaconImpressionId: impressionId
        ) {
            DispatchQueue.main.async {
                let execution = AttributionRouteExecution(
                    originatingScene: originatingScene,
                    isActive: {
                        attributionRouteLifecycle.isActive
                            && visible
                            && UIApplication.shared.applicationState == .active
                    },
                    allowsDetachedDeterministicAttribution: true,
                    survivesPresentationTeardownAfterBegin: true,
                    canCompleteAfterPresentationTeardown: committedRouteTerminalAvailability(
                        originatingScene: originatingScene
                    ),
                    onUIHandoffReleased: {
                        clickHandoffs.set(.storePrompt, pending: false)
                    },
                    onOutcome: { outcome in
                        recordAttributionRoute(outcome: outcome, source: .storePrompt)
                        if outcome.success { storeExit?.recordStoreOpen("store_prompt") }
                        if let generation = gestureGuard.complete() {
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + StorePromptGestureGuard.routedReleaseTimeout
                            ) {
                                gestureGuard.releaseRoutedFallback(generation: generation)
                            }
                        } else {
                            gestureGuard.release()
                        }
                    }
                )
                routeCommittedUserHandoff(
                    coordinator: attributionRouteLifecycle.automaticRoutes,
                    handoff: automaticUserHandoff,
                    scope: attributionRouteLifecycle.automaticRouteScope,
                    execution: execution,
                    route: handleStorePromptTap
                )
            }
        }
    }

    // MARK: Close

    private func finish(earned: Bool) {
        guard canDismissFullscreen(
            dismissUnlocked: earned,
            clickHandoffPending: clickHandoffPending
        ) else { return }
        let elapsed = gateClock.elapsed
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            onFinish(earned, elapsed)
        }
    }
}
#endif
