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
    private var videoPlayer: FullscreenVideoPlayer?
    private var videoPreparationOwnership: FullscreenVideoPreparationOwnership?
    private var videoAssetLease: VideoAssetLease?
    /// Fired once on teardown with whether the reward was earned and the measured
    /// play time, so the caller can verify the play server-side.
    private var onClose: ((Bool, Double, RewardCompletionReason?, FullscreenPresentationLease, UIWindow?) -> Void)?
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
        adUnitId: String? = nil,
        serveId: String? = nil,
        renderedHtml: String = "",
        creative: Creative? = nil,
        videoBehavior: VideoBehavior = VideoBehavior(),
        progressBarBehavior: ProgressBarBehavior = ProgressBarBehavior(),
        videoPlayer: FullscreenVideoPlayer? = nil,
        videoPreparationOwnership: FullscreenVideoPreparationOwnership? = nil,
        videoAssetLease: VideoAssetLease? = nil,
        videoPlanScope: VideoPlanPresentationScope? = nil,
        admission: FullscreenPresentationAdmission,
        storeExitTracker: StoreExitTracker? = nil,
        close: CloseBehavior? = nil,
        storePrompt: StorePrompt? = nil,
        trackingUrl: String? = nil,
        destination: AdDestination = .appstore,
        storeOpen: StoreOpen = .skstoreproduct,
        storeUrl: String? = nil,
        attribution: AdAttribution? = nil,
        skOverlay: SKOverlayConfig? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        previewHTML: String? = nil,
        onWillPresent: () -> Void = {},
        onVideoStarted: @escaping () -> Void = {},
        onRewardGateOpened: @escaping () -> Void = {},
        onClick: @escaping (ClickInteraction) -> Void,
        onClose: @escaping (Bool, Double, RewardCompletionReason?, FullscreenPresentationLease, UIWindow?) -> Void
    ) -> Bool {
        guard presentationLease == nil else { return false }
        let presentationLease = FullscreenPresentationRegistry.shared.claim()
        guard let scene = preferredForegroundActiveWindowScene() else {
            presentationLease.releaseAfterPresentationFailure()
            return false
        }
        self.presentationLease = presentationLease
        self.onClose = onClose
        self.videoPlayer = videoPlayer
        self.videoPreparationOwnership = videoPreparationOwnership
        self.videoAssetLease = videoAssetLease
        videoPlayer?.attachVideoPlanScope(videoPlanScope)

        // WebView ↔ SDK bridge (PRD §3): the creative can request early completion, haptics,
        // orientation lock, and device/audio/orientation queries. Owned here so the orientation
        // handler can reach the hosting controller + window created below.
        let bridge = CreativeBridge()
        creativeBridge = bridge

        let root = RewardedGameView(
            impressionId: impressionId,
            apiKey: apiKey,
            adUnitId: adUnitId,
            serveId: serveId,
            originatingScene: scene,
            renderedHtml: renderedHtml,
            creative: creative,
            videoBehavior: videoBehavior,
            progressBarBehavior: progressBarBehavior,
            videoPlayer: videoPlayer,
            videoPlanScope: videoPlanScope,
            admission: admission,
            storeExit: storeExitTracker,
            close: close,
            storePrompt: storePrompt,
            trackingUrl: trackingUrl,
            destination: destination,
            storeOpen: storeOpen,
            storeUrl: storeUrl,
            attribution: attribution,
            skOverlay: skOverlay,
            autoStoreRedirect: autoStoreRedirect,
            previewHTML: previewHTML,
            bridge: bridge,
            onVideoStarted: onVideoStarted,
            onRewardGateOpened: onRewardGateOpened,
            onClick: onClick,
            onFinish: { [weak self] earned, elapsed, completionReason in
                self?.dismiss(
                    earned: earned,
                    elapsedPlayTime: elapsed,
                    completionReason: completionReason
                )
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
        adUnitId: String? = nil,
        serveId: String? = nil,
        renderedHtml: String = "",
        creative: Creative? = nil,
        videoBehavior: VideoBehavior = VideoBehavior(),
        progressBarBehavior: ProgressBarBehavior = ProgressBarBehavior(),
        videoPlayer: FullscreenVideoPlayer? = nil,
        videoPreparationOwnership: FullscreenVideoPreparationOwnership? = nil,
        videoAssetLease: VideoAssetLease? = nil,
        videoPlanScope: VideoPlanPresentationScope? = nil,
        admission: FullscreenPresentationAdmission,
        storeExitTracker: StoreExitTracker? = nil,
        close: CloseBehavior? = nil,
        storePrompt: StorePrompt? = nil,
        trackingUrl: String? = nil,
        destination: AdDestination = .appstore,
        storeOpen: StoreOpen = .skstoreproduct,
        storeUrl: String? = nil,
        attribution: AdAttribution? = nil,
        skOverlay: SKOverlayConfig? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        previewHTML: String? = nil,
        onWillPresent: () -> Void = {},
        onVideoStarted: @escaping () -> Void = {},
        onRewardGateOpened: @escaping () -> Void = {},
        onClick: @escaping () -> Void,
        onClose: @escaping (Bool, Double, RewardCompletionReason?, FullscreenPresentationLease, UIWindow?) -> Void
    ) -> Bool {
        present(
            impressionId: impressionId,
            apiKey: apiKey,
            adUnitId: adUnitId,
            serveId: serveId,
            renderedHtml: renderedHtml,
            creative: creative,
            videoBehavior: videoBehavior,
            progressBarBehavior: progressBarBehavior,
            videoPlayer: videoPlayer,
            videoPreparationOwnership: videoPreparationOwnership,
            videoAssetLease: videoAssetLease,
            videoPlanScope: videoPlanScope,
            admission: admission,
            storeExitTracker: storeExitTracker,
            close: close,
            storePrompt: storePrompt,
            trackingUrl: trackingUrl,
            destination: destination,
            storeOpen: storeOpen,
            storeUrl: storeUrl,
            attribution: attribution,
            skOverlay: skOverlay,
            autoStoreRedirect: autoStoreRedirect,
            previewHTML: previewHTML,
            onWillPresent: onWillPresent,
            onVideoStarted: onVideoStarted,
            onRewardGateOpened: onRewardGateOpened,
            onClick: { _ in onClick() },
            onClose: onClose
        )
    }

    /// Fires the close callback, then tears down the presentation window — in that order, so the
    /// callback can bring up the post-close fallback ad window (from a background prefetch, ready
    /// synchronously) on top of this still-visible window before it's hidden. Tearing down first
    /// flashed the app behind during the handoff.
    private func dismiss(
        earned: Bool,
        elapsedPlayTime: Double,
        completionReason: RewardCompletionReason?
    ) {
        // Capture the window refs and clear `self`'s references BEFORE invoking the callback: the
        // callback nils the owner's reference to this presenter, so `self` may be deallocated by
        // the time it returns. Operate on the locals afterwards instead of touching `self`.
        let win = window
        let hostKeyWindow = originalKeyWindow
        let bridge = creativeBridge
        creativeBridge = nil
        bridge?.stop()
        let player = videoPlayer
        videoPlayer = nil
        let videoPreparationOwnership = videoPreparationOwnership
        self.videoPreparationOwnership = nil
        if videoPreparationOwnership == nil {
            player?.stop()
        } else {
            _ = videoPreparationOwnership?.releaseFromPresentation()
        }
        let videoAssetLease = videoAssetLease
        self.videoAssetLease = nil
        videoAssetLease?.release()
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
                callback(earned, elapsedPlayTime, completionReason, presentationLease, hostKeyWindow)
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
    let adUnitId: String?
    let serveId: String?
    let originatingScene: UIWindowScene
    /// Server-rendered playable HTML.
    let renderedHtml: String
    let creative: Creative?
    let videoBehavior: VideoBehavior
    let progressBarBehavior: ProgressBarBehavior
    let videoPlayer: FullscreenVideoPlayer?
    let videoPlanScope: VideoPlanPresentationScope?
    let admission: FullscreenPresentationAdmission
    let admissionOwner: FullscreenVisualSurfaceToken
    let storeExit: StoreExitTracker?
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
    /// Native install-banner configuration. The destination remains server-owned by the response.
    let skOverlay: SKOverlayConfig?
    /// auto_store_redirect config — fires the store open once at the configured creative moment.
    let autoStoreRedirect: AutoStoreRedirect?
    /// When set, render this local HTML instead of the response creative (preview / QA).
    let previewHTML: String?
    /// WebView ↔ SDK bridge (PRD §3). `AD_EARLY_COMPLETE` flips `earlyComplete` (observed below).
    let bridge: CreativeBridge
    let onVideoStarted: () -> Void
    let onRewardGateOpened: () -> Void
    /// Fired on a user-gesture CTA / store-prompt tap (the CLICKED signal); parity with the interstitial.
    let onClick: (ClickInteraction) -> Void
    let onFinish: (Bool, Double, RewardCompletionReason?) -> Void

    /// The timer runs only while the app is foregrounded AND no in-app store/Safari sheet covers the
    /// playable — tracked separately and reconciled in `reconcileTimer()`. The playable lives in a
    /// stand-alone `UIWindow`, where SwiftUI's `\.scenePhase` does NOT track the app lifecycle, so
    /// foreground state is driven by `UIApplication` background/foreground notifications instead.
    @State private var appForegrounded = true
    @State private var storeSheetPresented = false
    @State private var viewAppeared = false
    @State private var gateClock = FullscreenGateClock()
    @State private var videoGate: VideoPlaybackGate
    @State private var videoFailureHandled = false
    @State private var videoStartRecorded = false
    @State private var videoCompletionHandled = false
    @State private var videoPlanBlockerOwner = VideoPlanBlockerOwner()
    @State private var videoPlanBlockerGeneration: UInt64 = 0
    @State private var primaryCreativeReady = false
    @State private var admittedVideoPlayerIdentity: ObjectIdentifier?
    @State private var htmlReadinessDeadline: RewardedHTMLReadinessDeadlineState
    @State private var htmlTerminalFailure = RewardedHTMLTerminalFailureState()
    @State private var terminalState = DeferredTerminalState<RewardedTerminalOutcome>()
    /// Smoothly-animated 0→1 fill for the close bar/ring. Driven by a linear animation over the
    /// remaining gate (re-anchored on pause/resume) so the indicator glides instead of stepping once
    /// per 1 s accrual tick — `closeProgress` below is the instantaneous truth used to anchor it.
    @State private var closeProgressAnim: Double = 0
    /// Bumped on every pause; keyed into `CloseButtonView`'s `.id()` so pausing discards the
    /// in-flight linear fill animation along with the old view identity. SwiftUI animations are
    /// additive and a non-animated write alone cannot cancel a running delta — without this the
    /// fill jumps backwards when a store sheet pauses the timer, and repeated pause/resume cycles
    /// stack deltas until the displayed fill pins at zero.
    @State private var closeGateGeneration = 0
    @State private var rewardCompletion = RewardCompletionState()
    @State private var earlyCompletion = RewardedEarlyCompletionState()
    @State private var storePromptVisible = false
    @State private var storePromptGestureGuard = StorePromptGestureGuard()
    @State private var clickHandoffs = FullscreenClickHandoffState()
    @State private var attributionRouteLifecycle = AttributionRouteLifecycle()
    @State private var visible = true
    @State private var timerTask: Task<Void, Never>?
    @State private var htmlReadinessTask: Task<Void, Never>?
    @State private var resolvedAppID: String?
    @State private var skOverlayState = SKOverlayPresentationState<SKOverlayOwnershipToken>()
    @State private var skOverlayTask: Task<Void, Never>?
    @State private var skOverlayResolutionStarted = false

    init(
        impressionId: String,
        apiKey: String,
        adUnitId: String?,
        serveId: String?,
        originatingScene: UIWindowScene,
        renderedHtml: String,
        creative: Creative?,
        videoBehavior: VideoBehavior,
        progressBarBehavior: ProgressBarBehavior,
        videoPlayer: FullscreenVideoPlayer?,
        videoPlanScope: VideoPlanPresentationScope?,
        admission: FullscreenPresentationAdmission,
        storeExit: StoreExitTracker?,
        close: CloseBehavior?,
        storePrompt: StorePrompt?,
        trackingUrl: String?,
        destination: AdDestination,
        storeOpen: StoreOpen,
        storeUrl: String?,
        attribution: AdAttribution?,
        skOverlay: SKOverlayConfig?,
        autoStoreRedirect: AutoStoreRedirect?,
        previewHTML: String?,
        bridge: CreativeBridge,
        onVideoStarted: @escaping () -> Void,
        onRewardGateOpened: @escaping () -> Void,
        onClick: @escaping (ClickInteraction) -> Void,
        onFinish: @escaping (Bool, Double, RewardCompletionReason?) -> Void
    ) {
        self.impressionId = impressionId
        self.apiKey = apiKey
        self.adUnitId = adUnitId
        self.serveId = serveId
        self.originatingScene = originatingScene
        self.renderedHtml = renderedHtml
        self.creative = creative
        self.videoBehavior = videoBehavior
        self.progressBarBehavior = progressBarBehavior
        self.videoPlayer = videoPlayer
        self.videoPlanScope = videoPlanScope
        self.admission = admission
        self.admissionOwner = FullscreenVisualSurfaceToken()
        self.storeExit = storeExit
        self.close = close
        self.storePrompt = storePrompt
        self.trackingUrl = trackingUrl
        self.destination = destination
        self.storeOpen = storeOpen
        self.storeUrl = storeUrl
        self.attribution = attribution
        self.skOverlay = skOverlay
        self.autoStoreRedirect = autoStoreRedirect
        self.previewHTML = previewHTML
        self.bridge = bridge
        self.onVideoStarted = onVideoStarted
        self.onRewardGateOpened = onRewardGateOpened
        self.onClick = onClick
        self.onFinish = onFinish
        _videoGate = State(initialValue: VideoPlaybackGate(
            configuredDelay: TimeInterval(close?.delaySeconds ?? 0)
        ))
        _htmlReadinessDeadline = State(initialValue: RewardedHTMLReadinessDeadlineState(
            configuredCloseDelay: TimeInterval(close?.delaySeconds ?? 0)
        ))
    }

    /// Matches the dismiss fade before the window is removed.
    private let dismissAnimationDuration: TimeInterval = 0.25

    /// Play-to-earn gate length, in seconds — sourced from `ad_behavior.close.delay_seconds` (the
    /// same value that ungates the close button). `nil` close → 0 → instantly earned.
    private var gateSeconds: Int { close?.delaySeconds ?? 0 }

    private var gateDuration: TimeInterval { TimeInterval(gateSeconds) }

    private var secondsLeft: Int {
        videoPlayer == nil ? gateClock.secondsRemaining(total: gateDuration) : videoGate.secondsRemaining
    }

    /// Instantaneous 0→1 play-to-earn fraction. Not rendered directly — `closeProgressAnim` glides
    /// between these values and re-anchors here when the timer pauses or resumes.
    private var closeProgress: Double {
        gateClock.progress(total: gateDuration)
    }

    private var clickHandoffPending: Bool { clickHandoffs.isPending }
    private var rewardEarned: Bool { rewardCompletion.earned }
    private var presentationActive: Bool {
        viewAppeared && visible && appForegrounded && !storeSheetPresented
    }
    private var usesVideoPlanV2: Bool {
        videoPlanScope != nil && creative?.mediaType == .video
    }
    private var suppressesLegacySKOverlay: Bool {
        !isLegacySKOverlayEligible(usesVideoPlanV2: usesVideoPlanV2)
    }
    private var videoTelemetryBehavior: AdBehavior {
        AdBehavior(
            skoverlay: skOverlay,
            video: videoBehavior,
            reward: RewardBehavior(),
            progressBar: progressBarBehavior
        )
    }
    private var videoChromeVisibility: VideoPreFirstFrameChromeVisibility {
        guard let videoPlayer else {
            return videoPreFirstFrameChromeVisibility(
                hasVideo: false,
                firstFrameAdmitted: false,
                terminal: false
            )
        }
        return videoPreFirstFrameChromeVisibility(
            hasVideo: true,
            firstFrameAdmitted: primaryCreativeReady || videoPlayer.hasAdmittedFirstVisualFrame,
            terminal: videoFailureHandled || videoPlayer.status.isFailure
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Sits below the safe area (the black backdrop fills the notch / home-indicator region).
            // ctaDestination/ctaStoreUrl thread the serve's routing context into the coordinator so
            // an in-playable CTA opens the store deterministically (in-app sheet + background
            // tracker fire) instead of sniffing the tracker's redirect chain.
            if let previewHTML {
                creativeWebView(html: previewHTML)
            } else if let videoPlayer {
                videoCreativeView(videoPlayer)
            } else if !renderedHtml.isEmpty {
                creativeWebView(html: renderedHtml)
            }

            // Close button — honors the server `ad_behavior.close` treatment (hidden / countdown ring /
            // progress bar / reward-or-close label) exactly like the interstitial, but gated on the
            // play-to-earn progress: the ✕ unlocks only once the reward is earned.
            if videoChromeVisibility.showsServerControl {
                CloseButtonView(
                    treatment: (close ?? CloseBehavior()).treatment,
                    position: (close ?? CloseBehavior()).position,
                    progressBarColor: (close ?? CloseBehavior()).progressBarColor,
                    progressBarStyle: videoTelemetryBehavior.progressBar.style,
                    action: (close ?? CloseBehavior()).action,
                    isRewardCopy: true,
                    enabled: canDismissFullscreen(
                        dismissUnlocked: rewardEarned,
                        clickHandoffPending: clickHandoffPending
                    ),
                    remaining: secondsLeft,
                    progress: closeProgressAnim,
                    mediaProgress: videoMediaProgress,
                    gateFraction: videoGateFraction,
                    onClose: { finish(earned: true) }
                )
                // Identity keyed to the pause generation — see `closeGateGeneration`.
                .id(closeGateGeneration)
                .animation(.default, value: rewardEarned)
            }

            if let videoPlayer, videoChromeVisibility.showsEscape {
                VideoPreFirstFrameEscapeButton(
                    action: { handleVideoPreFirstFrameEscape(player: videoPlayer) },
                    accessibilityLabel: "Close ad without reward"
                )
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

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
                // A genuine bottom-left control shares the corner with the "i" (shrink its hit area).
                // Any bottom bar relocates that control, leaving the disclosure its full hit area.
                closeAtBottomLeft: (close ?? CloseBehavior()).position == .bottomLeft && !closeBarAtBottom(
                    (close ?? CloseBehavior()).treatment,
                    (close ?? CloseBehavior()).position,
                    progressBarStyle: progressBarBehavior.style
                )
            )
        }
        .opacity(visible ? 1 : 0)
        // Opacity 0 does not stop hit-testing during the fade; disable touches so a
        // second close tap can't double-fire.
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: dismissAnimationDuration), value: visible)
        .hideStatusBar(true)
        .onAppear {
            appForegrounded = UIApplication.shared.applicationState == .active
            storeSheetPresented = CreativeCTARouter.isExternalPresentationActive(
                ownershipToken: attributionRouteLifecycle.storeProductOwnership
            )
            admission.setBlocked(fullscreenPresentationBlocked(
                appForegrounded: appForegrounded,
                storeSheetPresented: storeSheetPresented
            ))
            viewAppeared = true
            attributionRouteLifecycle.activate()
            reconcileTimer()
            if !suppressesLegacySKOverlay { startSKOverlay() }
            videoPlanBlockerGeneration &+= 1
            videoPlanScope?.activateBlocker(
                owner: videoPlanBlockerOwner,
                generation: videoPlanBlockerGeneration,
                blocked: !appForegrounded || storeSheetPresented
            )
            // PLAYABLE_END: if the reward was already earned (duration 0), fire immediately.
            fireAutoStoreRedirectIfCloseShown()
        }
        .onDisappear {
            viewAppeared = false
            attributionRouteLifecycle.deactivate()
            timerTask?.cancel()
            timerTask = nil
            applyHTMLReadinessDeadline(
                htmlReadinessDeadline.reconcile(
                    now: ProcessInfo.processInfo.systemUptime,
                    eligible: false
                )
            )
            gateClock.pause(at: ProcessInfo.processInfo.systemUptime, total: gateDuration)
            if videoPlayer != nil { admission.visualBecameUnavailable(owner: admissionOwner) }
            dismissSKOverlay()
            storePromptGestureGuard.release()
            clickHandoffs.reset()
            videoPlayer?.setPresentationBlocked(true)
            videoPlanScope?.deactivateBlocker(
                owner: videoPlanBlockerOwner,
                generation: videoPlanBlockerGeneration
            )
        }
        // Pause the play-to-earn timer while the app is backgrounded OR an in-app store/Safari sheet
        // covers the playable; resume only when both clear, so the reward can't be earned off-screen.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            appForegrounded = false
            updateVideoPlanBlocker(true)
            admission.setBlocked(true)
            storeExit?.onAppAway()
            reconcileTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            appForegrounded = true
            updateVideoPlanBlocker(storeSheetPresented)
            admission.setBlocked(storeSheetPresented)
            storeExit?.onAppForeground()
            storePromptGestureGuard.releaseAfterExternalReturn()
            reconcileTimer()
            presentRequestedSKOverlayIfNeeded()
            completeDeferredTerminalIfPossible()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { notification in
            guard let scene = notification.object as? UIWindowScene, scene === originatingScene else { return }
            presentRequestedSKOverlayIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetWillPresent)) { notification in
            guard (notification.object as? StoreProductOwnershipToken) === attributionRouteLifecycle.storeProductOwnership else { return }
            storeSheetPresented = true
            updateVideoPlanBlocker(true)
            admission.setBlocked(true)
            storeExit?.onSheetPresented()
            reconcileTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetDidDismiss)) { notification in
            guard (notification.object as? StoreProductOwnershipToken) === attributionRouteLifecycle.storeProductOwnership else { return }
            storeSheetPresented = false
            updateVideoPlanBlocker(!appForegrounded)
            admission.setBlocked(!appForegrounded)
            storeExit?.onSheetDismissed()
            storePromptGestureGuard.releaseAfterExternalReturn()
            reconcileTimer()
            completeDeferredTerminalIfPossible()
        }
        // AD_EARLY_COMPLETE (PRD §3): the creative finished early (e.g. survey done), so grant the
        // reward and reveal the close button immediately, bypassing the play timer.
        .onReceive(bridge.$earlyComplete) { earlyComplete in
            guard videoPlayer != nil || !htmlTerminalFailure.gatePermanentlyIneligible else { return }
            guard earlyCompletion.receive(
                signaled: earlyComplete,
                requiresCreativeReadiness: videoPlayer != nil,
                primaryCreativeReady: primaryCreativeReady,
                rewardEarned: rewardEarned
            ) else { return }
            applyEarlyCompletion()
        }
        // PLAYABLE_END (auto_store_redirect): open the store the moment the close button appears
        // (here, when the reward is earned and the reward/close pill becomes a close button).
        .onChange(of: rewardEarned) { earned in
            if earned {
                storePromptVisible = false
                fireAutoStoreRedirectIfCloseShown()
            }
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
                    if let route = outcome.storeDwellRoute {
                        storeExit?.recordStoreOpen(
                            ClickSource.autoRedirect.storeDwellTrigger,
                            route: route
                        )
                    }
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

    /// HTML readiness is allowed at least ten foreground seconds (Android parity), extended to the
    /// configured close delay for heavy playables. Background and SDK-owned sheets pause this budget.
    private func reconcileHTMLReadinessDeadline() {
        let action = htmlReadinessDeadline.reconcile(
            now: ProcessInfo.processInfo.systemUptime,
            eligible: videoPlayer == nil && visible && !primaryCreativeReady
                && !htmlTerminalFailure.gatePermanentlyIneligible
                && appForegrounded && !storeSheetPresented
        )
        applyHTMLReadinessDeadline(action)
    }

    private func applyHTMLReadinessDeadline(_ action: RewardedHTMLReadinessDeadlineAction) {
        switch action {
        case .none:
            break
        case .schedule(let delay):
            htmlReadinessTask = Task { await runHTMLReadinessDeadline(after: delay) }
        case .cancel:
            htmlReadinessTask?.cancel()
            htmlReadinessTask = nil
        case .fail:
            htmlReadinessTask?.cancel()
            htmlReadinessTask = nil
            handleLegacyHTMLTerminalFailure("readiness_timeout")
        }
    }

    @MainActor
    private func runHTMLReadinessDeadline(after delay: TimeInterval) async {
        let nanos = delay * 1_000_000_000
        guard nanos.isFinite, nanos > 0, nanos < Double(UInt64.max) else { return }
        do { try await Task.sleep(nanoseconds: UInt64(nanos)) } catch { return }
        if Task.isCancelled { return }
        htmlReadinessTask = nil
        applyHTMLReadinessDeadline(
            htmlReadinessDeadline.deadlineFired(now: ProcessInfo.processInfo.systemUptime)
        )
    }

    private func startTimer() {
        guard videoPlayer == nil, timerTask == nil,
              !htmlTerminalFailure.gatePermanentlyIneligible else { return }
        // A zero/negative gate is earned immediately (no gate).
        if let reason = rewardedHTMLGateCompletionReason(
            actualElapsedPlayTime: gateClock.elapsed,
            gateDuration: gateDuration
        ) {
            earnReward(reason: reason)
            return
        }
        // Glide the bar/ring fill linearly to full over the remaining gate. The monotonic clock keeps
        // fractional elapsed time so pausing for StoreKit cannot snap the indicator to a prior second.
        let remaining = gateClock.remaining(total: gateDuration)
        guard remaining > 0 else {
            earnReward(reason: .durationElapsed)
            return
        }
        gateClock.resume(at: ProcessInfo.processInfo.systemUptime)
        closeProgressAnim = closeProgress
        withAnimation(.linear(duration: remaining)) { closeProgressAnim = 1 }
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        timerTask = Task { await runPlayTimer() }
    }

    private func applyEarlyCompletion() {
        guard videoPlayer != nil || !htmlTerminalFailure.gatePermanentlyIneligible else { return }
        timerTask?.cancel()
        timerTask = nil
        gateClock.pause(at: ProcessInfo.processInfo.systemUptime, total: gateDuration)
        earnReward(reason: .creativeCompleted)
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
        guard !htmlTerminalFailure.gatePermanentlyIneligible else { return }
        // Reveal the store prompt at the halfway point to the reward (mid play-to-earn).
        if gateClock.elapsed >= gateDuration / 2, !storePromptVisible {
            withAnimation(.easeInOut(duration: 0.25)) { storePromptVisible = true }
        }
        if let reason = rewardedHTMLGateCompletionReason(
            actualElapsedPlayTime: gateClock.elapsed,
            gateDuration: gateDuration
        ) {
            earnReward(reason: reason)
        }
    }

    /// Runs the play-to-earn timer only while foreground-active and no in-app store sheet covers the
    /// playable.
    private func reconcileTimer() {
        reconcileHTMLReadinessDeadline()
        let blocked = !appForegrounded || storeSheetPresented
        if let videoPlayer {
            videoPlayer.setPresentationBlocked(blocked)
        } else if !blocked {
            if shouldRunRewardedHTMLGate(
                appForegrounded: appForegrounded,
                storeSheetPresented: storeSheetPresented,
                rewardEarned: rewardEarned,
                gatePermanentlyIneligible: htmlTerminalFailure.gatePermanentlyIneligible
            ) {
                startTimer()
            }
        } else {
            timerTask?.cancel()
            timerTask = nil
            gateClock.pause(at: ProcessInfo.processInfo.systemUptime, total: gateDuration)
            applyElapsedPlayTime()
            // Freeze the animated fill at the true elapsed fraction so it stops gliding while paused
            // (disable the implicit animation so it doesn't tween toward the frozen value).
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) {
                closeProgressAnim = closeProgress
                closeGateGeneration += 1
            }
        }
    }

    private func updateVideoPlanBlocker(_ blocked: Bool) {
        videoPlanScope?.updateBlocker(
            owner: videoPlanBlockerOwner,
            generation: videoPlanBlockerGeneration,
            blocked: blocked
        )
    }

    /// A user-gesture CTA tap inside the playable surfaces CLICKED to the publisher. The WebView
    /// coordinator reports the terminal route outcome separately, and only a successful route marks
    /// the store-exit funnel.
    private func handleHtmlClick(_ interaction: ClickInteraction) {
        onClick(interaction)
        presentSKOverlayOnClickIfNeeded()
    }

    private func creativeWebView(html: String) -> some View {
        WebViewRepresentable(
            htmlString: html,
            onNavigationCommitted: { handleLegacyHTMLBillingCallback(.mainFrameCommitted) },
            onNavigationFinished: { handlePlayableReady() },
            onNavigationFailed: { _ in handleLegacyHTMLBillingCallback(.navigationFailed) },
            onWebContentProcessTerminated: {
                handleLegacyHTMLBillingCallback(.webContentProcessTerminated)
            },
            onAdClick: { handleHtmlClick($0) },
            onClickHandoffPendingChanged: {
                updateClickHandoff(.creative, pending: $0)
            },
            onAttributionRouteOutcome: { outcome in
                if let route = outcome.storeDwellRoute {
                    storeExit?.recordStoreOpen(ClickSource.primaryCTA.storeDwellTrigger, route: route)
                }
            },
            onStoreOverlayShowRequest: { showSKOverlayFromCreative() },
            onStoreDismissRequest: { dismissSKOverlay() },
            storeProductOwnershipToken: attributionRouteLifecycle.storeProductOwnership,
            attributionRouteLifecycle: attributionRouteLifecycle,
            clickSource: .primaryUnknown,
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

    private func handleLegacyHTMLTerminalFailure(_ reason: String) {
        applyHTMLReadinessDeadline(
            htmlReadinessDeadline.complete(now: ProcessInfo.processInfo.systemUptime)
        )
        recordLegacyHTMLTelemetry(reason)
        switch htmlTerminalFailure.terminalFailure(rewardAlreadyEarned: rewardEarned) {
        case .none, .preserveFailOpen:
            return
        case .terminate(let earned):
            admission.htmlNavigationDidFail()
            stopHTMLRewardGate()
            requestTerminal(earned: earned)
        }
    }

    private func stopHTMLRewardGate() {
        timerTask?.cancel()
        timerTask = nil
        gateClock.pause(at: ProcessInfo.processInfo.systemUptime, total: gateDuration)
        earlyCompletion.cancel()
        storePromptVisible = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            closeProgressAnim = closeProgress
            closeGateGeneration += 1
        }
    }

    private func recordLegacyHTMLTelemetry(_ reason: String) {
        Telemetry.shared.recordLifecycle(
            stage: "creative_fail", adFormat: "rewarded", adUnitId: nil,
            adId: impressionId, serveId: nil, errorCode: reason
        )
    }

    private func handleLegacyHTMLBillingCallback(_ callback: LegacyHTMLBillingCallback) {
        switch legacyHTMLBillingCallbackAction(for: callback) {
        case .confirm:
            guard htmlTerminalFailure.visualDidCommit() else { return }
            applyHTMLReadinessDeadline(
                htmlReadinessDeadline.complete(now: ProcessInfo.processInfo.systemUptime)
            )
            admission.htmlNavigationDidCommit()
        case .suppressUncommitted:
            handleLegacyHTMLTerminalFailure("navigation_failed")
        case .telemetryOnly:
            recordLegacyHTMLTelemetry("renderer_terminated")
        }
    }

    private func handlePlayableReady() {
        guard visible, !videoFailureHandled, !primaryCreativeReady,
              videoPlayer != nil || !htmlTerminalFailure.gatePermanentlyIneligible else { return }
        primaryCreativeReady = true
        applyHTMLReadinessDeadline(
            htmlReadinessDeadline.complete(now: ProcessInfo.processInfo.systemUptime)
        )
        if earlyCompletion.primaryCreativeBecameReady(rewardEarned: rewardEarned) {
            applyEarlyCompletion()
            return
        }
        reconcileTimer()
    }

    @ViewBuilder
    private func videoCreativeView(_ player: FullscreenVideoPlayer) -> some View {
        FullscreenVideoSurface(
            videoPlayer: player,
            presentationActive: presentationActive,
            onTap: { handleVideoClick() },
            onFirstFrame: { handleVideoFirstFrame(player: player) },
            controlsEnabled: canUseVideoControls(
                firstFrameAdmitted: primaryCreativeReady,
                displayAdmitted: admission.hasAdmittedDisplay
            ),
            chromeConfiguration: videoChromeConfiguration(
                creative: creative,
                behavior: videoTelemetryBehavior,
                isVideoPlanV2: usesVideoPlanV2
            ),
            effectiveClosePosition: effectiveVideoClosePosition(
                treatment: (close ?? CloseBehavior()).treatment,
                position: (close ?? CloseBehavior()).position,
                progressBarStyle: progressBarBehavior.style
            ),
            bottomProgressBarObstructsChrome: videoBottomProgressBarObstructsChrome(
                treatment: (close ?? CloseBehavior()).treatment,
                position: (close ?? CloseBehavior()).position,
                progressBarStyle: progressBarBehavior.style
            ),
            storePromptVisible: storePromptVisible && !rewardEarned,
            storePromptSharesMuteCorner: videoStorePromptSharesMuteCorner(
                configuredClosePosition: (close ?? CloseBehavior()).position
            ),
            onMuteChanged: { muted in
                guard usesVideoPlanV2 else { return }
                videoPlanScope?.updateMuted(muted)
                recordFullscreenVideoLifecycle(
                    stage: FullscreenVideoTelemetryStage.muteToggle,
                    adFormat: "rewarded", adUnitId: adUnitId, adId: impressionId, serveId: serveId,
                    isVideoPlanV2: usesVideoPlanV2,
                    creative: creative, behavior: videoTelemetryBehavior,
                    muted: muted,
                    mutedWatchMs: player.mutedWatchMilliseconds,
                    unmutedWatchMs: player.unmutedWatchMilliseconds,
                    videoPositionS: player.currentMediaPositionSeconds,
                    durationS: player.duration,
                    secondsSinceVideoStart: player.secondsSinceVideoStart
                )
            },
            telemetryPauseReason: { videoPauseReason },
            onTelemetryEvent: usesVideoPlanV2
                ? { event in recordVideoSurfaceTelemetry(event, player: player) }
                : nil,
            segments: creative?.segments ?? []
        )
            .allowsHitTesting(!clickHandoffPending)
            .onReceive(player.$status) { handleVideoStatus($0, player: player) }
            .onReceive(player.$mediaPositionSeconds) { _ in
                updateVideoGate(player: player, played: player.playedSeconds)
            }
            .onReceive(player.$duration) { _ in updateVideoGate(player: player, played: player.playedSeconds) }
    }

    private func handleVideoStatus(
        _ status: FullscreenVideoStatus,
        player: FullscreenVideoPlayer,
        terminalAlreadyClaimed: Bool = false
    ) {
        switch status {
        case .ready, .paused:
            updateVideoGate(player: player, played: player.playedSeconds)
        case .playing:
            updateVideoGate(player: player, played: player.playedSeconds)
        case .ended:
            guard primaryCreativeReady, !videoCompletionHandled,
                  terminalAlreadyClaimed || claimVideoPlanTerminalIfNeeded(
                      player: player,
                      event: .completion
                  ) else { return }
            videoCompletionHandled = true
            updateVideoGate(player: player, played: player.playedSeconds, ended: true)
            recordFullscreenVideoLifecycle(
                stage: FullscreenVideoTelemetryStage.complete,
                adFormat: "rewarded", adUnitId: adUnitId, adId: impressionId, serveId: serveId,
                isVideoPlanV2: usesVideoPlanV2,
                creative: creative, behavior: videoTelemetryBehavior,
                muted: player.isMuted,
                mutedWatchMs: player.mutedWatchMilliseconds,
                unmutedWatchMs: player.unmutedWatchMilliseconds,
                videoPositionS: player.currentMediaPositionSeconds,
                durationS: player.duration,
                secondsSinceVideoStart: player.secondsSinceVideoStart
            )
            if shouldAutomaticallyAdvanceCompletedVideo(
                usesVideoPlanV2: usesVideoPlanV2,
                status: status
            ) {
                requestTerminal(earned: true)
            }
        case .failed(let reason):
            guard !videoFailureHandled,
                  claimVideoPlanTerminalIfNeeded(player: player, event: .failure) else { return }
            videoFailureHandled = true
            admission.visualBecameUnavailable(owner: admissionOwner)
            recordFullscreenVideoLifecycle(
                stage: FullscreenVideoTelemetryStage.fail,
                adFormat: "rewarded", adUnitId: adUnitId, adId: impressionId, serveId: serveId,
                isVideoPlanV2: usesVideoPlanV2,
                creative: creative, behavior: videoTelemetryBehavior,
                muted: player.isMuted,
                mutedWatchMs: player.mutedWatchMilliseconds,
                unmutedWatchMs: player.unmutedWatchMilliseconds,
                errorCode: reason.rawValue,
                videoPositionS: player.currentMediaPositionSeconds,
                durationS: player.duration,
                secondsSinceVideoStart: player.secondsSinceVideoStart
            )
            Telemetry.shared.recordError(
                signature: "video:playback_failed",
                errorCode: reason.rawValue,
                breadcrumb: "surface=rewarded"
            )
            markVideoHandoff(player: player, reason: FullscreenVideoTerminationReason.failed)
            requestTerminalAdvance()
        case .preparing:
            break
        }
    }

    private func handleVideoFirstFrame(player: FullscreenVideoPlayer) -> Bool {
        guard shouldAcceptFullscreenVideoFirstFrameCallback(
            presentationActive: presentationActive,
            failureHandled: videoFailureHandled,
            callbackPlayerIdentity: ObjectIdentifier(player),
            currentPlayerIdentity: videoPlayer.map(ObjectIdentifier.init),
            status: player.status,
            isStopped: player.isStopped
        ) else { return false }
        if primaryCreativeReady {
            guard admittedVideoPlayerIdentity == ObjectIdentifier(player),
                  player.hasAdmittedFirstVisualFrame else { return false }
            if !admission.visualIsActive {
                admission.visualBecameReady(owner: admissionOwner)
            }
            return true
        }
        let admittedAt = ProcessInfo.processInfo.systemUptime
        primaryCreativeReady = true
        admittedVideoPlayerIdentity = ObjectIdentifier(player)
        admission.visualBecameReady(owner: admissionOwner)
        runVideoFirstFrameStartSequence(
            shouldRecordStart: !videoStartRecorded,
            recordStart: {
                videoStartRecorded = true
                recordFullscreenVideoLifecycle(
                    stage: FullscreenVideoTelemetryStage.start,
                    adFormat: "rewarded", adUnitId: adUnitId, adId: impressionId, serveId: serveId,
                    isVideoPlanV2: usesVideoPlanV2,
                    creative: creative, behavior: videoTelemetryBehavior,
                    muted: player.isMuted,
                    videoPositionS: player.currentMediaPositionSeconds,
                    durationS: player.duration,
                    secondsSinceVideoStart: player.secondsSinceVideoStart
                )
            },
            startOverlay: {
                videoPlanScope?.firstVideoFrame(
                    playerID: player.videoPlanPresentationID,
                    creative: creative,
                    behavior: videoTelemetryBehavior,
                    adFormat: "rewarded",
                    adUnitId: adUnitId,
                    adId: impressionId,
                    serveId: serveId,
                    config: skOverlay,
                    trackingUrl: trackingUrl,
                    destination: destination,
                    storeUrl: storeUrl,
                    attribution: attribution,
                    originatingScene: originatingScene,
                    admittedAt: admittedAt,
                    blocked: !appForegrounded || storeSheetPresented
                )
            },
            notifyStarted: onVideoStarted
        )
        updateVideoGate(player: player, played: player.playedSeconds)
        return true
    }

    private func handleVideoPreFirstFrameEscape(player: FullscreenVideoPlayer) {
        guard let decision = videoPreFirstFrameEscapeDecision(
            surface: .rewarded,
            presentationMounted: viewAppeared && visible,
            firstFrameAdmitted: primaryCreativeReady || player.hasAdmittedFirstVisualFrame,
            terminal: videoFailureHandled || player.status.isTerminal
        ), decision.action == .finishRewardedUnearned,
              claimVideoPlanTerminalIfNeeded(player: player, event: decision.terminalEvent) else { return }
        recordVideoClose(player: player, reason: decision.telemetryReason)
        videoFailureHandled = true
        requestTerminalAdvance()
    }

    private func updateVideoGate(
        player: FullscreenVideoPlayer,
        played: TimeInterval,
        ended: Bool = false
    ) {
        guard primaryCreativeReady else { return }
        videoGate.update(
            duration: player.duration,
            played: played,
            mediaPosition: player.currentMediaPositionSeconds,
            ended: ended
        )
        let progress = videoGate.progress
        if closeProgressAnim != progress { closeProgressAnim = progress }
        if primaryCreativeReady, shouldShowVideoStorePrompt(
            enabled: storePrompt?.enabled == true,
            reachedMidpoint: videoGate.reachedAssetMidpoint,
            dismissUnlocked: rewardEarned
        ), !storePromptVisible {
            withAnimation(.easeInOut(duration: 0.25)) { storePromptVisible = true }
        }
        if primaryCreativeReady, let reason = videoGate.earnedCompletionReason {
            earnReward(reason: reason)
            storePromptVisible = false
        }
    }

    private var videoMediaProgress: Double {
        guard let player = videoPlayer, let duration = player.duration,
              duration.isFinite, duration > 0 else { return closeProgressAnim }
        return min(1, max(0, player.mediaPositionSeconds / duration))
    }

    private var videoGateFraction: Double {
        guard let duration = videoPlayer?.duration else { return 1 }
        return progressBarGateFraction(gateSeconds: gateDuration, mediaDuration: duration)
    }

    private var videoPauseReason: String {
        if !appForegrounded { return FullscreenVideoTerminationReason.backgrounded }
        if storeSheetPresented { return FullscreenVideoTerminationReason.storePresented }
        if videoPlayer?.hasActiveAudioInterruption == true {
            return FullscreenVideoTerminationReason.audioInterruption
        }
        return FullscreenVideoTerminationReason.playback
    }

    private func recordVideoSurfaceTelemetry(
        _ event: VideoSurfaceTelemetryEvent,
        player: FullscreenVideoPlayer
    ) {
        let stage: String
        var segmentEvent: VideoSegmentTelemetryEvent?
        var quartile: Int?
        var reason: String?
        var pausedMs: Double?
        switch event {
        case .segment(let value):
            stage = value.stage
            segmentEvent = value
            quartile = value.stage == FullscreenVideoTelemetryStage.duration ? 50 : nil
        case .quartile(let value):
            stage = FullscreenVideoTelemetryStage.duration
            quartile = value
        case .pause(let value):
            stage = FullscreenVideoTelemetryStage.pause
            reason = value
        case .resume(let value, let duration):
            stage = FullscreenVideoTelemetryStage.resume
            reason = value
            pausedMs = duration
        }
        recordFullscreenVideoLifecycle(
            stage: stage,
            adFormat: "rewarded", adUnitId: adUnitId,
            adId: impressionId, serveId: serveId,
            isVideoPlanV2: usesVideoPlanV2,
            creative: creative, behavior: videoTelemetryBehavior,
            muted: player.isMuted,
            mutedWatchMs: player.mutedWatchMilliseconds,
            unmutedWatchMs: player.unmutedWatchMilliseconds,
            videoPositionS: player.currentMediaPositionSeconds,
            durationS: player.duration,
            quartile: quartile,
            reason: reason,
            pausedMs: pausedMs,
            secondsSinceVideoStart: player.secondsSinceVideoStart,
            on: stage == FullscreenVideoTelemetryStage.pause
                || stage == FullscreenVideoTelemetryStage.resume ? "video" : nil,
            segmentEvent: segmentEvent
        )
    }

    private func earnReward(reason: RewardCompletionReason) {
        if rewardCompletion.earn(reason: reason) { onRewardGateOpened() }
    }

    private func handleVideoClick() {
        guard canUseVideoControls(
            firstFrameAdmitted: primaryCreativeReady,
            displayAdmitted: admission.hasAdmittedDisplay
        ), !clickHandoffs.isPending, visible,
           hasRoutableVideoDestination(
               trackingUrl: trackingUrl,
               destination: destination,
               storeUrl: storeUrl
           ) else { return }
        guard let automaticUserHandoff = attributionRouteLifecycle.automaticRoutes.beginUserHandoff(
            scope: attributionRouteLifecycle.automaticRouteScope
        ) else { return }
        let interaction = ClickInteraction(source: .primaryCTA)
        updateClickHandoff(.creative, pending: true)
        onClick(interaction)
        ClickHandoffPersistence.wait(interaction: interaction, beaconImpressionId: impressionId) {
            DispatchQueue.main.async {
                let execution = AttributionRouteExecution(
                    originatingScene: originatingScene,
                    isActive: {
                        attributionRouteLifecycle.isActive && visible
                            && UIApplication.shared.applicationState == .active
                    },
                    allowsDetachedDeterministicAttribution: true,
                    survivesPresentationTeardownAfterBegin: true,
                    canCompleteAfterPresentationTeardown: committedRouteTerminalAvailability(
                        originatingScene: originatingScene
                    ),
                    onUIHandoffReleased: { updateClickHandoff(.creative, pending: false) },
                    onOutcome: { outcome in
                        recordAttributionRoute(outcome: outcome, source: .primaryCTA)
                        if let route = outcome.storeDwellRoute {
                            storeExit?.recordStoreOpen(ClickSource.primaryCTA.storeDwellTrigger, route: route)
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
        presentSKOverlayOnClickIfNeeded()
    }

    /// Routes a store-prompt tap to the advertised destination (shared CTA router).
    private func handleStorePromptTap(execution: AttributionRouteExecution) {
        CreativeCTARouter.open(
            trackingUrl: trackingUrl,
            destination: destination,
            storeOpen: storeOpen,
            storeUrl: storeUrl,
            attribution: attribution,
            storeProductOwnership: attributionRouteLifecycle.storeProductOwnership,
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
        updateClickHandoff(.storePrompt, pending: true)
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
                        updateClickHandoff(.storePrompt, pending: false)
                    },
                    onOutcome: { outcome in
                        recordAttributionRoute(outcome: outcome, source: .storePrompt)
                        if let route = outcome.storeDwellRoute {
                            storeExit?.recordStoreOpen(
                                ClickSource.storePrompt.storeDwellTrigger,
                                route: route
                            )
                        }
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

    // MARK: SKOverlay

    private func startSKOverlay() {
        guard !suppressesLegacySKOverlay else { return }
        let config = skOverlay
        guard config?.enabled == true || skOverlayState.creativePresentationRequested,
              resolvedAppID == nil, !skOverlayResolutionStarted,
              !skOverlayState.suppressPending else { return }
        guard #available(iOS 14.0, *) else { return }
        skOverlayResolutionStarted = true
        CreativeCTARouter.resolveAppStoreID(
            trackingUrl: trackingUrl,
            destination: destination,
            storeUrl: storeUrl
        ) { id in
            guard !skOverlayState.suppressPending else { return }
            resolvedAppID = id
            if skOverlayState.creativePresentationRequested {
                presentSKOverlay(config: creativeRequestedSKOverlayConfig(from: config))
            } else if let config, config.enabled,
                      config.timing == .duringPlay || config.timing == .delayed {
                scheduleSKOverlayPresent(config: config)
            }
        }
    }

    private func scheduleSKOverlayPresent(config: SKOverlayConfig) {
        guard skOverlayState.canPresent(hasResolvedAppID: resolvedAppID != nil) else { return }
        skOverlayTask?.cancel()
        skOverlayTask = Task { await runSKOverlayPresent(config: config) }
    }

    @MainActor
    private func runSKOverlayPresent(config: SKOverlayConfig) async {
        if config.delaySeconds > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(config.delaySeconds) * 1_000_000_000) } catch { return }
        }
        if Task.isCancelled { return }
        presentSKOverlay(config: config)
    }

    private func presentSKOverlay(config: SKOverlayConfig) {
        guard !suppressesLegacySKOverlay else { return }
        guard skOverlayState.canPresent(hasResolvedAppID: resolvedAppID?.isEmpty == false),
              let appID = resolvedAppID else { return }
        guard visible, attributionRouteLifecycle.isActive,
              UIApplication.shared.applicationState == .active,
              originatingScene.activationState == .foregroundActive else { return }
        guard #available(iOS 14.0, *) else { return }
        var claimReservation: SKOverlayPresentationClaim.Reservation?
        if let videoPlanScope {
            guard let reservation = videoPlanScope.reserveLegacySKOverlay() else { return }
            claimReservation = reservation
        }
        guard let ownership = SKOverlayPresenter.present(
            appID: appID,
            config: config,
            attribution: attribution,
            originatingScene: originatingScene
        ) else {
            if let claimReservation {
                videoPlanScope?.legacySKOverlayDidFail(claimReservation)
            }
            return
        }
        guard skOverlayState.install(ownership) else {
            SKOverlayPresenter.dismiss(ownershipToken: ownership)
            if let claimReservation {
                videoPlanScope?.legacySKOverlayDidFail(claimReservation)
            }
            return
        }
        if let claimReservation,
           videoPlanScope?.legacySKOverlayDidPresent(claimReservation) != true {
            if let installed = skOverlayState.dismiss() {
                SKOverlayPresenter.dismiss(ownershipToken: installed)
            }
        }
    }

    private func presentSKOverlayOnClickIfNeeded() {
        guard !suppressesLegacySKOverlay else { return }
        guard let config = skOverlay, config.enabled, config.timing == .onClick else { return }
        // A configured product sheet remains foreground when both StoreKit surfaces are selected;
        // the overlay stays exactly owned by this scene/presentation behind it.
        presentSKOverlay(config: config)
    }

    private func showSKOverlayFromCreative() {
        guard !suppressesLegacySKOverlay else { return }
        guard skOverlayState.requestCreativePresentation() else { return }
        skOverlayTask?.cancel()
        skOverlayTask = nil
        startSKOverlay()
        presentRequestedSKOverlayIfNeeded()
    }

    private func presentRequestedSKOverlayIfNeeded() {
        guard !suppressesLegacySKOverlay,
              skOverlayState.creativePresentationRequested,
              resolvedAppID?.isEmpty == false else { return }
        presentSKOverlay(config: creativeRequestedSKOverlayConfig(from: skOverlay))
    }

    private func dismissSKOverlay() {
        skOverlayTask?.cancel()
        skOverlayTask = nil
        let ownership = skOverlayState.dismiss()
        guard let ownership, #available(iOS 14.0, *) else { return }
        SKOverlayPresenter.dismiss(ownershipToken: ownership)
    }

    // MARK: Close

    private func finish(earned: Bool) {
        guard !terminalState.isTerminal, canDismissFullscreen(
            dismissUnlocked: earned,
            clickHandoffPending: clickHandoffPending
        ) else { return }
        if let player = videoPlayer, usesVideoPlanV2 {
            guard videoCompletionHandled || claimVideoPlanTerminalIfNeeded(
                player: player, event: .userClose
            ) else { return }
            markVideoHandoff(
                player: player,
                reason: videoCompletionHandled
                    ? FullscreenVideoTerminationReason.completed : FullscreenVideoTerminationReason.user
            )
        }
        requestTerminal(earned: earned)
    }

    private func recordVideoClose(player: FullscreenVideoPlayer, reason: String) {
        let watchTotals = player.flushPresentationWatchAccounting()
        recordFullscreenVideoLifecycle(
            stage: FullscreenVideoTelemetryStage.close,
            adFormat: "rewarded", adUnitId: adUnitId,
            adId: impressionId, serveId: serveId,
            isVideoPlanV2: usesVideoPlanV2,
            creative: creative, behavior: videoTelemetryBehavior,
            muted: player.isMuted,
            mutedWatchMs: watchTotals?.mutedMilliseconds ?? player.mutedWatchMilliseconds,
            unmutedWatchMs: watchTotals?.unmutedMilliseconds ?? player.unmutedWatchMilliseconds,
            videoPositionS: player.currentMediaPositionSeconds,
            durationS: player.duration,
            reason: reason,
            secondsSinceVideoStart: player.secondsSinceVideoStart
        )
    }

    private func markVideoHandoff(player: FullscreenVideoPlayer, reason: String) {
        guard usesVideoPlanV2 else { return }
        let watchTotals = player.flushPresentationWatchAccounting()
        videoPlanScope?.videoTerminated(VideoPlanHandoffTelemetry(
            adFormat: "rewarded",
            adUnitId: adUnitId,
            adId: impressionId,
            serveId: serveId,
            creative: creative,
            behavior: videoTelemetryBehavior,
            muted: player.isMuted,
            mutedWatchMs: watchTotals?.mutedMilliseconds ?? player.mutedWatchMilliseconds,
            unmutedWatchMs: watchTotals?.unmutedMilliseconds ?? player.unmutedWatchMilliseconds,
            videoPositionS: player.currentMediaPositionSeconds,
            durationS: player.duration,
            secondsSinceVideoStart: player.secondsSinceVideoStart,
            reason: reason
        ))
    }

    private func claimVideoPlanTerminalIfNeeded(
        player: FullscreenVideoPlayer,
        event: VideoPlanTerminalEvent
    ) -> Bool {
        guard usesVideoPlanV2 else { return true }
        return videoPlanScope?.claimVideoTerminal(
            playerID: player.videoPlanPresentationID,
            event: event
        ) == true
    }

    private func requestTerminalAdvance() {
        requestTerminal(earned: rewardEarned)
    }

    private func requestTerminal(earned: Bool) {
        let outcome = rewardedTerminalOutcome(
            earned: earned,
            actualElapsedPlayTime: videoPlayer?.playedSeconds ?? gateClock.elapsed,
            completionReason: rewardCompletion.reason
        )
        guard let admitted = terminalState.request(outcome, blocked: terminalBlocked) else { return }
        performTerminal(admitted)
    }

    private func updateClickHandoff(_ owner: FullscreenClickHandoffOwner, pending: Bool) {
        clickHandoffs.set(owner, pending: pending)
        completeDeferredTerminalIfPossible()
    }

    private var terminalBlocked: Bool { clickHandoffPending || storeSheetPresented || !appForegrounded }

    private func completeDeferredTerminalIfPossible() {
        guard let outcome = terminalState.blockersDidChange(blocked: terminalBlocked) else { return }
        performTerminal(outcome)
    }

    private func performTerminal(_ outcome: RewardedTerminalOutcome) {
        guard visible else { return }
        admission.visualBecameUnavailable(owner: admissionOwner)
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            onFinish(outcome.earned, outcome.elapsedPlayTime, outcome.completionReason)
        }
    }
}
#endif
