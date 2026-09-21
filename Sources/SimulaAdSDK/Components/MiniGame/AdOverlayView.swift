import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

/// Pure navigation-generation state for `AdOverlayView`'s load watchdog. Late timeout/completion
/// callbacks can mutate state only while they still own the current loading generation.
struct AdOverlayLoadCoordinator {
    static let watchdogTimeout: TimeInterval = 10

    enum Phase: Equatable {
        case idle
        case loading(Int)
        case timedOut(Int)
        case finished(Int)
        case failed(Int)
    }

    private(set) var generation = 0
    private(set) var phase = Phase.idle

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var isIdle: Bool { phase == .idle }

    var isTimedOut: Bool {
        if case .timedOut = phase { return true }
        return false
    }

    mutating func beginLoad() -> Int {
        generation += 1
        phase = .loading(generation)
        return generation
    }

    mutating func finishCurrentLoad() -> Bool {
        guard case .loading(let owner) = phase else { return false }
        phase = .finished(owner)
        return true
    }

    mutating func failCurrentLoad() -> Bool {
        switch phase {
        case .loading(let owner), .timedOut(let owner), .finished(let owner):
            phase = .failed(owner)
            return true
        case .idle, .failed:
            return false
        }
    }

    mutating func timeout(generation expectedGeneration: Int) -> Bool {
        guard phase == .loading(expectedGeneration) else { return false }
        phase = .timedOut(expectedGeneration)
        return true
    }

    mutating func cancel() {
        generation += 1
        phase = .idle
    }
}

/// One-shot ownership for the screen-installed event. A SwiftUI re-appearance or a late WebView
/// callback cannot manufacture another END_SCREEN_N_OPEN trigger for the same overlay identity.
struct AdOverlayScreenMountCoordinator {
    private enum Phase { case idle, scheduled, delivered }
    private var phase: Phase = .idle
    var isMounted: Bool { phase == .delivered }

    mutating func scheduleIfNeeded() -> Bool {
        guard phase == .idle else { return false }
        phase = .scheduled
        return true
    }

    mutating func markDelivered() -> Bool {
        guard phase == .scheduled else { return false }
        phase = .delivered
        return true
    }

    mutating func cancelScheduled() {
        if phase == .scheduled { phase = .idle }
    }
}

struct PendingFirstFrameHandoff<Token: Hashable> {
    private(set) var accepting = true
    private(set) var active: Token?
    private(set) var pending: Token?
    private(set) var admitted: Token?
    private(set) var terminal: Token?

    mutating func activate(_ token: Token) {
        accepting = true
        guard active != token else { return }
        active = token
        pending = nil
        admitted = nil
        terminal = nil
    }

    mutating func receive(_ token: Token, parentAppeared: Bool) -> Bool {
        guard accepting else { return false }
        if active == nil { active = token }
        guard active == token, admitted != token, terminal != token else { return false }
        guard parentAppeared else {
            pending = token
            return false
        }
        pending = nil
        admitted = token
        return true
    }

    mutating func replay(_ token: Token) -> Bool {
        guard active == token, pending == token, admitted != token, terminal != token else {
            return false
        }
        pending = nil
        admitted = token
        return true
    }

    mutating func fail(_ token: Token) -> Bool {
        guard accepting else { return false }
        if active == nil { active = token }
        guard active == token, terminal != token else { return false }
        pending = nil
        admitted = nil
        terminal = token
        return true
    }

    mutating func claimPreFirstFrameFailure(_ token: Token) -> Bool {
        guard accepting, active == token, admitted != token, terminal != token else { return false }
        pending = nil
        terminal = token
        return true
    }

    func isTerminal(_ token: Token) -> Bool { terminal == token }

    mutating func clearPending() {
        pending = nil
        admitted = nil
    }

    mutating func invalidate() {
        accepting = false
        active = nil
        pending = nil
        admitted = nil
        terminal = nil
    }
}

private struct AdOverlayVideoSurfaceIdentity: Hashable {
    let creative: String
    let player: ObjectIdentifier
}

#if os(iOS)
final class AdOverlayWindowSceneView: UIView {
    var onSceneChanged: ((UIWindowScene?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scene = window?.windowScene
        let callback = onSceneChanged
        if let scene {
            DispatchQueue.main.async { [weak self] in
                guard self?.window?.windowScene === scene else { return }
                callback?(scene)
            }
        } else {
            // The callback must survive this view's deallocation so stale scene state is cleared.
            DispatchQueue.main.async { callback?(nil) }
        }
    }
}

private struct AdOverlayWindowSceneReader: UIViewRepresentable {
    let onSceneChanged: (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> AdOverlayWindowSceneView {
        let view = AdOverlayWindowSceneView()
        view.isUserInteractionEnabled = false
        view.onSceneChanged = onSceneChanged
        return view
    }

    func updateUIView(_ view: AdOverlayWindowSceneView, context: Context) {
        view.onSceneChanged = onSceneChanged
        guard let scene = view.window?.windowScene else { return }
        DispatchQueue.main.async { [weak view] in
            guard view?.window?.windowScene === scene else { return }
            onSceneChanged(scene)
        }
    }
}
#endif

/// Pure per-screen countdown policy. Zero duration unlocks at readiness without starting a ticker or
/// dividing by zero; positive durations preserve the legacy whole-second numeric circle.
struct FallbackCountdownPolicy: Equatable {
    let delaySeconds: Int

    init(delaySeconds: Int) {
        self.delaySeconds = min(maxCloseDelaySeconds, max(0, delaySeconds))
    }

    var totalMilliseconds: Double { Double(delaySeconds) * 1_000 }
    var needsTicker: Bool { delaySeconds > 0 }
}

// MARK: - AdOverlayView

/// Full-screen overlay that displays one server-rendered HTML or native video fallback.
/// Translates Kotlin's `AdIframeOverlay` composable from `MiniGameMenu.kt`.
///
/// Features:
/// - Full-screen dark overlay (matching Kotlin's Color(0xCC000000))
/// - Per-item countdown timer with the legacy numeric ring before the action button appears
/// - Configurable close/forward button at a supported corner after countdown
/// - WKWebView loading the ad iframe URL
/// - Bottom sheet mode support (uses last game height/border color)
/// - Status bar hiding when full screen or near full screen
public struct AdOverlayView: View {
    let ad: FallbackAd
    let onClose: () -> Void
    var onCreativeFailure: (() -> Void)? = nil
    var videoPlayer: FullscreenVideoPlayer? = nil
    /// Height from the last game session (if bottom sheet mode). nil = fullscreen.
    var playableHeightDp: CGFloat?
    /// Border color for bottom sheet drag handle area.
    var playableBorderColor: String = "#262626"
    /// Impression id this overlay reports against (the ad that led here). Empty hides the info button.
    var adId: String = ""
    /// Server-owned assignment for this fallback. False means the HTML retains click counting.
    var nativeClickBeaconV1Enabled: Bool = false
    /// Per-item fallback close behavior. Defaults differ from primary ads by contract.
    var closeBehavior: CloseBehavior = .fallbackDefault
    /// Measurement context for this fallback surface. The fallback ad id remains the event identity;
    /// the parent serve is deliberately not reused for fallback click accounting.
    var telemetryAdFormat: String = "interstitial"
    var telemetryAdUnitId: String? = nil
    var telemetryServeId: String? = nil
    /// Fired once for an admitted user CTA tap. Route success is reported separately.
    var onAdClick: ((ClickInteraction) -> Void)? = nil
    /// Mirrors deferred route ownership to imperative fallback presenters for a defensive close guard.
    var onClickHandoffPendingChanged: ((Bool) -> Void)? = nil
    /// Mirrors external-sheet/background blockers so failure cannot tear down a route's presenter.
    var onPresentationBlockedChanged: ((Bool) -> Void)? = nil
    /// The primary serve's CTA routing context — with a raw store link, the end screen's CTA opens
    /// the in-app store sheet deterministically (tracker fired in the background) instead of
    /// resolving the tracker's redirect chain. Defaults preserve today's behavior (declarative menu).
    var ctaTrackingUrl: String? = nil
    var ctaDestination: AdDestination = .appstore
    var ctaStoreOpen: StoreOpen = .skstoreproduct
    var ctaStoreUrl: String? = nil
    /// Attribution tokens carried into the store sheet the end-screen CTA opens.
    var attribution: AdAttribution? = nil
    /// Presentation-owned routing state shared with configured and in-WebView automatic routes.
    var routeLifecycle: AttributionRouteLifecycle? = nil
    /// Fires once after this screen's route lifecycle and lifecycle observers are mounted. This is
    /// deliberately independent of WebView readiness: END_SCREEN_N_OPEN means screen installation.
    var onScreenMounted: (() -> Bool)? = nil

    /// The pooled WebView is transparent, so keep native black above it until the current page is
    /// actually ready. A failed navigation deliberately leaves the safe surface in place.
    @State private var adPageReady = false
    /// Terminal load failure keeps the native black shield but removes the indefinite spinner.
    @State private var adPageFailed = false
    /// A committed document can still fail while loading subresources. HTML close timing starts at
    /// mount for legacy compatibility; native video timing starts only after its first visual frame.
    @State private var pageFinished = false
    /// A watchdog timeout fails open: close remains available even if the same load finishes later.
    @State private var loadTimedOut = false
    @State private var hasAppeared = false
    @State private var loadedCreativeIdentity: String?
    @State private var loadCoordinator = AdOverlayLoadCoordinator()
    @State private var loadWatchdogTask: Task<Void, Never>?
    @State private var screenMountCoordinator = AdOverlayScreenMountCoordinator()
    @State private var firstFrameHandoff = PendingFirstFrameHandoff<AdOverlayVideoSurfaceIdentity>()
    @State private var clickHandoffPending = false
    @State private var localRouteLifecycle = AttributionRouteLifecycle()
    /// Countdown seconds remaining, initialized from the current fallback item on mount/load.
    @State private var adCountdown: Int = 0
    @State private var closeStateInitialized = false
    @State private var dismissUnlocked = false
    /// Ring progress (0.0 = empty, 1.0 = full) — fills clockwise from the top
    /// (right to left) over the countdown.
    @State private var ringProgress: CGFloat = 0.0
    /// The running countdown ticker. Held so it starts once and is cancelled on disappear, so it
    /// can't outlive the overlay (or be double-started by a re-`onAppear`).
    @State private var countdownTask: Task<Void, Never>?
    /// Foreground time accrued toward the current item's gate, in ms. The countdown advances only while running,
    /// and resumes from this on return so backgrounded / store-sheet time is never counted.
    @State private var accumulatedMs: Double = 0
    @State private var videoGate = VideoPlaybackGate(configuredDelay: 5)
    @State private var videoFailureHandled = false
    @State private var videoStartRecorded = false
    @State private var videoCompleteRecorded = false
    #if os(iOS)
    @State private var originatingScene: UIWindowScene?
    #endif
    @State private var closing = false
    /// The countdown runs only while the app is foregrounded AND no in-app store/Safari sheet covers
    /// the ad. This overlay lives in a stand-alone `UIWindow` where SwiftUI's `\.scenePhase` doesn't
    /// track the app lifecycle, so foreground state comes from `UIApplication` notifications.
    @State private var appForegrounded = true
    @State private var storeSheetPresented = false
    /// Top safe-area inset captured once on appear (full-screen only), so the content insets below
    /// the status bar / notch without re-reading the window on every body pass.
    @State private var topSafeInset: CGFloat = 0

    private var isBottomSheet: Bool {
        guard let h = playableHeightDp else { return false }
        // Match React Native: >= 95% of screen treated as full screen (no bottom sheet UI)
        return h < screenHeight * 0.95
    }

    private var screenHeight: CGFloat {
        #if os(iOS)
        simulaScreenSize().height
        #else
        768
        #endif
    }

    private var shouldHideStatusBar: Bool {
        if isBottomSheet {
            return (playableHeightDp ?? 0) >= screenHeight * 0.95
        }
        return true
    }

    private var countdownPolicy: FallbackCountdownPolicy {
        FallbackCountdownPolicy(delaySeconds: closeBehavior.delaySeconds)
    }

    private var closeAlignment: Alignment {
        switch closeBehavior.position {
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        case .bottomLeft: return .bottomLeading
        }
    }

    #if os(iOS)
    private var videoChromeVisibility: VideoPreFirstFrameChromeVisibility {
        guard ad.mediaType == .video, let videoPlayer else {
            return videoPreFirstFrameChromeVisibility(
                hasVideo: false,
                firstFrameAdmitted: false,
                terminal: false
            )
        }
        return videoPreFirstFrameChromeVisibility(
            hasVideo: true,
            firstFrameAdmitted: pageFinished || videoPlayer.hasAdmittedFirstVisualFrame,
            terminal: videoFailureHandled || videoPlayer.status.isFailure
        )
    }
    #endif

    public var body: some View {
        ZStack {
            #if os(iOS)
            AdOverlayWindowSceneReader { scene in originatingScene = scene }
                .frame(width: 0, height: 0)
            #endif
            // Backdrop: fully black full-screen (so the end screen's safe area is solid
            // black, matching Android); the in-game bottom sheet keeps 80% to show the
            // paused game behind it (matching Kotlin's Color(0xCC000000)).
            Color.black.opacity(isBottomSheet ? 0.8 : 1.0)
                .ignoresSafeArea()
                .onTapGesture {
                    requestClose()
                }

            // Content: bottom sheet or fullscreen (GeometryReader layout matches GameIframeView)
            GeometryReader { geo in
                VStack(spacing: 0) {
                    // Visual-only drag handle for bottom sheet mode (no gesture, matching Kotlin)
                    if isBottomSheet {
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 40, height: 4)
                                .padding(.vertical, 12)
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color(hex: playableBorderColor))
                        .clipShape(TopRoundedRectangle(radius: 16))
                    }

                    // Main content area
                    ZStack {
                        Color.black

                        if ad.mediaType == .playable, let html = ad.renderedHtml {
                            WebViewRepresentable(
                                htmlString: html,
                                onNavigationFinished: { markPageFinished() },
                                onNavigationFailed: { _ in markLegacyHTMLPageFailed() },
                                onWebContentProcessTerminated: { markLegacyHTMLPageFailed() },
                                onAdClick: { handleAdClick($0) },
                                onClickHandoffPendingChanged: { updateClickHandoffPending($0) },
                                attributionRouteLifecycle: activeRouteLifecycle,
                                clickSource: .fallbackCTA,
                                clickBeaconImpressionId: nativeClickBeaconImpressionId,
                                attribution: attribution,
                                ctaTrackingUrl: ctaTrackingUrl,
                                ctaDestination: ctaDestination,
                                ctaStoreOpen: ctaStoreOpen,
                                ctaStoreUrl: ctaStoreUrl
                            )
                            .allowsHitTesting(!clickHandoffPending)
                        }

                        #if os(iOS)
                        if ad.mediaType == .video, let videoPlayer {
                            FullscreenVideoSurface(
                                videoPlayer: videoPlayer,
                                presentationActive: hasAppeared && !closing
                                    && appForegrounded && !storeSheetPresented,
                                onTap: { handleVideoClick() },
                                onFirstFrame: { handleVideoFirstFrame(player: videoPlayer) },
                                controlsEnabled: pageFinished
                            )
                                .allowsHitTesting(!clickHandoffPending)
                                .onReceive(videoPlayer.$status) { handleVideoStatus($0, player: videoPlayer) }
                                .onReceive(videoPlayer.$playedSeconds) { updateVideoGate(player: videoPlayer, played: $0) }
                                .onReceive(videoPlayer.$duration) { _ in
                                    updateVideoGate(player: videoPlayer, played: videoPlayer.playedSeconds)
                                }
                        }
                        #endif

                        // The video surface owns its poster/readiness UI and interruption resume control.
                        // Keep recoverable pre-frame video interactive; terminal failures still fail black.
                        if shouldShowFallbackLoadingShield(
                            isVideo: ad.mediaType == .video,
                            adPageReady: adPageReady,
                            terminalFailure: adPageFailed
                        ) {
                            ZStack {
                                Color.black
                                if !adPageFailed {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                }
                            }
                        }

                        #if os(iOS)
                        if videoChromeVisibility.showsServerControl {
                            closeControl
                                .padding(8)
                                // The fallback info glyph uses an 18pt corner inset. Move a bottom-left
                                // close farther right so their visible circles and hit regions stay disjoint.
                                .padding(.leading, closeBehavior.position == .bottomLeft ? 30 : 0)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: closeAlignment)
                        }
                        #else
                        closeControl
                            .padding(8)
                            .padding(.leading, closeBehavior.position == .bottomLeft ? 30 : 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: closeAlignment)
                        #endif

                        #if os(iOS)
                        if videoChromeVisibility.showsEscape, let videoPlayer {
                            VideoPreFirstFrameEscapeButton(
                                action: { handleVideoPreFirstFrameEscape(player: videoPlayer) },
                                accessibilityLabel: "Skip unavailable ad"
                            )
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        }
                        #endif
                    }
                    .frame(maxWidth: .infinity)
                    // Full-screen ads inset the creative + close button below the top safe area
                    // (status bar / notch / Dynamic Island). Bottom-sheet mode keeps its own bounds.
                    .padding(.top, isBottomSheet ? 0 : topSafeInset)
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                // Height on outer VStack (handle + content) — matches GameIframeView
                .frame(height: isBottomSheet ? playableHeightDp : geo.size.height)
                // Pin to bottom of screen
                .offset(y: isBottomSheet ? geo.size.height - (playableHeightDp ?? geo.size.height) : 0)
            }
            .ignoresSafeArea()

            // Persistent ad-info "i" + report sheet (required disclosure on the fallback / post-game ad).
            // This overlay ignores the safe area, so use a larger corner inset to keep the "i" clear
            // of the screen's rounded bottom-left corner (where it would otherwise be clipped).
            #if os(iOS)
            if !adId.isEmpty {
                AdInfoReportOverlay(
                    adId: adId,
                    closeAtBottomLeft: closeBehavior.position == .bottomLeft,
                    cornerInset: 18
                )
            }
            #endif
        }
        .ignoresSafeArea()
        .hideStatusBar(shouldHideStatusBar)
        .onAppear {
            activeRouteLifecycle.activate()
            topSafeInset = isBottomSheet ? 0 : simulaTopSafeAreaInset()
            #if os(iOS)
            appForegrounded = UIApplication.shared.applicationState == .active
            storeSheetPresented = CreativeCTARouter.isExternalPresentationActive
            onPresentationBlockedChanged?(fallbackPresentationBlocked(
                appForegrounded: appForegrounded,
                storeSheetPresented: storeSheetPresented
            ))
            #endif
            hasAppeared = true
            if screenMountCoordinator.scheduleIfNeeded() {
                // Let the outer lifecycle modifier finish installing its notification subscriptions
                // before an automatic store sheet can synchronously publish will-present.
                let mounted = onScreenMounted
                DispatchQueue.main.async {
                    guard hasAppeared, activeRouteLifecycle.isActive else {
                        screenMountCoordinator.cancelScheduled()
                        return
                    }
                    let accepted = mounted?() ?? true
                    if accepted {
                        _ = screenMountCoordinator.markDelivered()
                    } else {
                        screenMountCoordinator.cancelScheduled()
                    }
                }
            }
            if !hasLoadableCreative {
                startCurrentCreativeLoadIfNeeded()
                if ad.mediaType == .video {
                    markPageFailedAndAdvance()
                } else {
                    markLegacyHTMLPageFailed()
                }
            } else {
                startCurrentCreativeLoadIfNeeded()
                #if os(iOS)
                if !replayPendingVideoFirstFrameIfNeeded() {
                    beginPresentationIfReady()
                }
                #else
                beginPresentationIfReady()
                #endif
            }
        }
        .onDisappear {
            screenMountCoordinator.cancelScheduled()
            activeRouteLifecycle.deactivate()
            hasAppeared = false
            #if os(iOS)
            originatingScene = nil
            #endif
            loadWatchdogTask?.cancel()
            loadWatchdogTask = nil
            loadCoordinator.cancel()
            firstFrameHandoff.invalidate()
            countdownTask?.cancel()
            countdownTask = nil
            updateClickHandoffPending(false)
            #if os(iOS)
            videoPlayer?.setPresentationBlocked(true)
            #endif
        }
        .onChange(of: creativeIdentity) { _ in
            startCurrentCreativeLoadIfNeeded()
        }
        // Pause the countdown while the app is backgrounded OR an in-app store/Safari sheet covers the
        // ad; resume only when both clear, so it can't elapse off-screen. (iOS-only; no-op elsewhere.)
        .modifier(AdCountdownLifecycle(
            onBackground: {
                appForegrounded = false
                onPresentationBlockedChanged?(true)
                reconcileCountdown()
            },
            onForeground: {
                appForegrounded = true
                onPresentationBlockedChanged?(storeSheetPresented)
                reconcileCountdown()
            },
            onSheetPresent: {
                storeSheetPresented = true
                onPresentationBlockedChanged?(true)
                reconcileCountdown()
            },
            onSheetDismiss: {
                storeSheetPresented = false
                onPresentationBlockedChanged?(!appForegrounded)
                reconcileCountdown()
            }
        ))
    }

    // MARK: - Countdown

    @ViewBuilder
    private var closeControl: some View {
        if dismissUnlocked {
            Button(action: requestClose) {
                Image(systemName: closeBehavior.action == .forward ? "chevron.right" : "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.black.opacity(0.5)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CloseButtonStyle())
            .disabled(clickHandoffPending)
            .accessibilityLabel(closeBehavior.action == .forward ? "Next ad" : "Close ad")
        } else if closeBehavior.treatment == .countdownCircle, countdownPolicy.needsTicker {
            // Keep the fallback countdown's exact legacy numeric-circle appearance. Unlike primary
            // countdown circles, no eventual action glyph is shown beneath this ring.
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: 16, height: 16)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(-90))

                Text("\(closeStateInitialized ? adCountdown : countdownPolicy.delaySeconds)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 44, height: 44)
        }
    }

    private var nativeClickBeaconImpressionId: String? {
        fallbackNativeClickBeaconImpressionId(
            adId: adId,
            capabilities: .current,
            nativeClickBeaconV1Enabled: nativeClickBeaconV1Enabled
        )
    }

    private var activeRouteLifecycle: AttributionRouteLifecycle {
        routeLifecycle ?? localRouteLifecycle
    }

    private var videoTelemetryAdFormat: String { "\(telemetryAdFormat)_fallback" }

    private func handleAdClick(_ interaction: ClickInteraction) {
        accountFallbackClick(
            adId: adId,
            interaction: interaction,
            capabilities: .current,
            nativeClickBeaconV1Enabled: nativeClickBeaconV1Enabled,
            adFormat: telemetryAdFormat,
            adUnitId: telemetryAdUnitId,
            serveId: telemetryServeId,
            recordTelemetry: { context, interaction in
                Telemetry.shared.recordLifecycle(
                    stage: "click",
                    adFormat: context.adFormat,
                    adUnitId: context.adUnitId,
                    adId: context.adId,
                    serveId: context.serveId,
                    interactionId: interaction.id,
                    clickSource: interaction.source
                )
            },
            enqueueBeacon: { claim, context in
                AdBeaconManager.shared.enqueue(
                    impressionId: claim.impressionId,
                    action: "click",
                    adFormat: context.adFormat,
                    adUnitId: context.adUnitId,
                    telemetryServeId: context.serveId ?? "",
                    interactionId: claim.interactionId,
                    clickSource: claim.clickSource
                )
            },
            notifyPublisher: { interaction in onAdClick?(interaction) }
        )
    }

    private func updateClickHandoffPending(_ pending: Bool) {
        clickHandoffPending = pending
        onClickHandoffPendingChanged?(pending)
    }

    private func requestClose() {
        switch fallbackCloseRequestAction(
            isVideo: ad.mediaType == .video,
            pageFinished: pageFinished,
            terminalFailure: adPageFailed,
            appForegrounded: appForegrounded,
            storeSheetPresented: storeSheetPresented,
            dismissUnlocked: dismissUnlocked,
            clickHandoffPending: clickHandoffPending
        ) {
        case .ignore:
            return
        case .requestFailureAdvance:
            firstFrameHandoff.invalidate()
            if let onCreativeFailure { onCreativeFailure() }
            else { onClose() }
        case .close:
            firstFrameHandoff.invalidate()
            closing = true
            onClose()
        }
    }

    private var hasLoadableCreative: Bool {
        guard ad.creativeContent != nil else { return false }
        #if os(iOS)
        return ad.mediaType != .video || videoPlayer != nil
        #else
        return ad.mediaType != .video
        #endif
    }

    private var creativeIdentity: String {
        if ad.mediaType == .video {
            return "video:\(ad.url?.hashValue ?? 0)"
        }
        return "html:\(ad.renderedHtml?.hashValue ?? 0)"
    }

    /// Starts one watchdog for the current creative. Ten seconds is deliberately longer than the
    /// ordinary fallback page load but short enough that a wedged Web Content process cannot trap a
    /// user indefinitely. Identity + generation checks make every cancelled/replaced timer harmless.
    private func startCurrentCreativeLoadIfNeeded() {
        let identityChanged = loadedCreativeIdentity != creativeIdentity
        #if os(iOS)
        if ad.mediaType == .video, let videoPlayer,
           let identity = videoSurfaceIdentity(for: videoPlayer) {
            firstFrameHandoff.activate(identity)
            if firstFrameHandoff.isTerminal(identity) { return }
        } else {
            firstFrameHandoff.invalidate()
        }
        #else
        firstFrameHandoff.invalidate()
        #endif
        if identityChanged {
            videoFailureHandled = false
            videoStartRecorded = false
            videoCompleteRecorded = false
        }
        guard identityChanged || loadCoordinator.isIdle
                || (!pageFinished && !adPageFailed && !loadCoordinator.isLoading
                    && !loadCoordinator.isTimedOut) else {
            return
        }

        loadWatchdogTask?.cancel()
        countdownTask?.cancel()
        countdownTask = nil
        loadedCreativeIdentity = creativeIdentity
        adPageReady = false
        adPageFailed = false
        pageFinished = false
        loadTimedOut = false
        let closeDelay = countdownPolicy.delaySeconds
        adCountdown = countdownPolicy.delaySeconds
        closeStateInitialized = true
        dismissUnlocked = false
        ringProgress = 0
        accumulatedMs = 0
        videoGate = VideoPlaybackGate(configuredDelay: TimeInterval(closeDelay))

        let generation = loadCoordinator.beginLoad()
        if ad.mediaType == .video { return }
        loadWatchdogTask = Task { await runLoadWatchdog(generation: generation) }
    }

    @MainActor
    private func runLoadWatchdog(generation: Int) async {
        let nanos = AdOverlayLoadCoordinator.watchdogTimeout * 1_000_000_000
        guard nanos.isFinite, nanos > 0, nanos < Double(UInt64.max) else { return }
        do { try await Task.sleep(nanoseconds: UInt64(nanos)) } catch { return }
        if Task.isCancelled || !loadCoordinator.timeout(generation: generation) { return }
        loadWatchdogTask = nil
        loadTimedOut = true
        adPageReady = true
        adPageFailed = false
        countdownTask?.cancel()
        countdownTask = nil
        unlockDismissal()
    }

    private func markPageFinished() {
        guard hasAppeared, !closing else { return }
        startCurrentCreativeLoadIfNeeded()
        guard !adPageFailed, loadCoordinator.finishCurrentLoad() else { return }
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        adPageReady = true
        pageFinished = true
        beginPresentationIfReady()
    }

    /// `didFinish` can race SwiftUI's `onAppear` for a newly-installed hosting controller. HTML
    /// reconciles from mount; video still waits for first-frame readiness.
    private func beginPresentationIfReady() {
        guard hasAppeared, !closing else { return }
        if ad.mediaType == .video {
            guard pageFinished, !adPageFailed else { return }
        }
        reconcileCountdown()
    }

    /// A terminal/no-content failure must not strand the user behind a spinner and a close gate for
    /// content that was never viewable. Screen-mounted behavior has already been delivered separately.
    private func markPageFailed() {
        startCurrentCreativeLoadIfNeeded()
        guard loadCoordinator.failCurrentLoad() else { return }
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        applyTerminalPageFailure()
    }

    private func markPageFailedAndAdvance() {
        guard hasAppeared, !videoFailureHandled else { return }
        videoFailureHandled = true
        markPageFailed()
        onCreativeFailure?()
    }

    private func markLegacyHTMLPageFailed() {
        guard ad.mediaType == .playable else { return }
        startCurrentCreativeLoadIfNeeded()
        guard loadCoordinator.failCurrentLoad() else { return }
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        adPageReady = false
        adPageFailed = true
        reconcileCountdown()
    }

    private func applyTerminalPageFailure() {
        firstFrameHandoff.clearPending()
        adPageReady = false
        adPageFailed = true
        countdownTask?.cancel()
        countdownTask = nil
        unlockDismissal()
    }

    /// Runs the countdown only while the app is foregrounded and no in-app store sheet covers the ad.
    private func reconcileCountdown() {
        #if os(iOS)
        if let videoPlayer, ad.mediaType == .video {
            videoPlayer.setPresentationBlocked(!appForegrounded || storeSheetPresented)
            return
        }
        #endif
        if shouldRunFallbackCountdown(
            isVideo: ad.mediaType == .video,
            pageFinished: pageFinished,
            hasAppeared: hasAppeared,
            appForegrounded: appForegrounded,
            storeSheetPresented: storeSheetPresented
        ) {
            startCountdown()
        } else {
            countdownTask?.cancel()
            countdownTask = nil
        }
    }

    private func startCountdown() {
        // Start exactly once; a re-`onAppear`, resume, or a SwiftUI double-fire must not restart it.
        guard countdownTask == nil else { return }
        let totalMs = countdownPolicy.totalMilliseconds
        guard countdownPolicy.needsTicker else {
            unlockDismissal()
            return
        }
        guard accumulatedMs < totalMs else {
            unlockDismissal()
            return
        }
        // Accrue only foreground time: a 50ms ticker driven by the monotonic clock, re-anchored each
        // (re)start so a backgrounded / store-sheet gap is never counted. The ring is snapped per tick
        // so it freezes on pause and resumes from where it left off. Cancelled on background / dismiss.
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        countdownTask = Task { await runCountdown(totalMs: totalMs) }
    }

    /// Countdown ticker task body (named method — see the task-shape note in TelemetryManager).
    @MainActor
    private func runCountdown(totalMs: Double) async {
        var lastTick = ProcessInfo.processInfo.systemUptime
        while accumulatedMs < totalMs {
            // do/catch, not `try?` — see the task-shape note in TelemetryManager.
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            if Task.isCancelled { return }
            let now = ProcessInfo.processInfo.systemUptime
            accumulatedMs += (now - lastTick) * 1000
            lastTick = now
            let progress = accumulatedMs / totalMs
            ringProgress = progress.isFinite ? min(1, max(0, CGFloat(progress))) : 1
            // Failable conversion covers non-finite and out-of-range values.
            let remainingSecs = ceil(max(0, totalMs - accumulatedMs) / 1000)
            adCountdown = Int(exactly: remainingSecs) ?? 0
        }
        unlockDismissal()
    }

    private func unlockDismissal() {
        adCountdown = 0
        ringProgress = 1
        dismissUnlocked = true
    }

    #if os(iOS)
    private func handleVideoStatus(_ status: FullscreenVideoStatus, player: FullscreenVideoPlayer) {
        switch status {
        case .ready, .paused:
            updateVideoGate(player: player, played: player.playedSeconds)
        case .playing:
            updateVideoGate(player: player, played: player.playedSeconds)
        case .ended:
            guard let identity = videoSurfaceIdentity(for: player) else { return }
            if firstFrameHandoff.pending == identity { return }
            guard pageFinished, firstFrameHandoff.admitted == identity else {
                handleVideoStatus(.failed(.playbackFailed), player: player)
                return
            }
            updateVideoGate(player: player, played: player.playedSeconds, ended: true)
            recordVideoCompleteIfNeeded()
        case .failed(let reason):
            guard !videoFailureHandled else { return }
            guard let identity = videoSurfaceIdentity(for: player),
                  firstFrameHandoff.fail(identity) else { return }
            videoFailureHandled = true
            _ = loadCoordinator.failCurrentLoad()
            applyTerminalPageFailure()
            Telemetry.shared.recordLifecycle(
                stage: FullscreenVideoTelemetryStage.fail, adFormat: videoTelemetryAdFormat,
                adUnitId: telemetryAdUnitId, adId: adId.isEmpty ? nil : adId,
                serveId: telemetryServeId, errorCode: reason.rawValue
            )
            Telemetry.shared.recordError(
                signature: "video:playback_failed",
                errorCode: reason.rawValue,
                breadcrumb: "surface=\(videoTelemetryAdFormat)"
            )
            onCreativeFailure?()
        case .preparing:
            break
        }
    }

    private func handleVideoFirstFrame(player: FullscreenVideoPlayer) -> Bool {
        guard !closing, !videoFailureHandled,
              let identity = videoSurfaceIdentity(for: player) else { return false }
        if pageFinished { return firstFrameHandoff.admitted == identity }
        guard firstFrameHandoff.receive(identity, parentAppeared: hasAppeared) else { return false }
        return admitVideoFirstFrame(player: player, identity: identity)
    }

    private func handleVideoPreFirstFrameEscape(player: FullscreenVideoPlayer) {
        guard let identity = videoSurfaceIdentity(for: player),
              videoPreFirstFrameEscapeAction(
            surface: .fallback,
            presentationMounted: hasAppeared && !closing,
            firstFrameAdmitted: pageFinished || player.hasAdmittedFirstVisualFrame,
            terminal: videoFailureHandled || player.status.isTerminal
        ) == .requestFallbackFailureAdvance,
              firstFrameHandoff.claimPreFirstFrameFailure(identity) else { return }
        markPageFailedAndAdvance()
    }

    private func replayPendingVideoFirstFrameIfNeeded() -> Bool {
        guard hasAppeared, !closing, !videoFailureHandled, !pageFinished,
              let player = videoPlayer,
              let identity = videoSurfaceIdentity(for: player),
              firstFrameHandoff.replay(identity) else { return false }
        return admitVideoFirstFrame(player: player, identity: identity)
    }

    private func admitVideoFirstFrame(
        player: FullscreenVideoPlayer,
        identity: AdOverlayVideoSurfaceIdentity
    ) -> Bool {
        guard hasAppeared, !closing, !videoFailureHandled, !pageFinished,
              videoSurfaceIdentity(for: player) == identity,
              loadCoordinator.finishCurrentLoad() else {
            firstFrameHandoff.invalidate()
            return false
        }
        adPageReady = true
        pageFinished = true
        if !videoStartRecorded {
            videoStartRecorded = true
            Telemetry.shared.recordLifecycle(
                stage: FullscreenVideoTelemetryStage.start, adFormat: videoTelemetryAdFormat,
                adUnitId: telemetryAdUnitId, adId: adId.isEmpty ? nil : adId,
                serveId: telemetryServeId
            )
        }
        let ended = player.status == .ended
        updateVideoGate(player: player, played: player.playedSeconds, ended: ended)
        if ended { recordVideoCompleteIfNeeded() }
        beginPresentationIfReady()
        return true
    }

    private func videoSurfaceIdentity(
        for player: FullscreenVideoPlayer
    ) -> AdOverlayVideoSurfaceIdentity? {
        guard ad.mediaType == .video, videoPlayer === player else { return nil }
        return AdOverlayVideoSurfaceIdentity(
            creative: creativeIdentity,
            player: ObjectIdentifier(player)
        )
    }

    private func updateVideoGate(
        player: FullscreenVideoPlayer,
        played: TimeInterval,
        ended: Bool = false
    ) {
        guard pageFinished, let identity = videoSurfaceIdentity(for: player),
              firstFrameHandoff.admitted == identity else { return }
        videoGate.update(duration: player.duration, played: played, ended: ended)
        ringProgress = CGFloat(videoGate.progress)
        adCountdown = videoGate.secondsRemaining
        dismissUnlocked = videoGate.isUnlocked
    }

    private func recordVideoCompleteIfNeeded() {
        guard !videoCompleteRecorded else { return }
        videoCompleteRecorded = true
        Telemetry.shared.recordLifecycle(
            stage: FullscreenVideoTelemetryStage.complete, adFormat: videoTelemetryAdFormat,
            adUnitId: telemetryAdUnitId, adId: adId.isEmpty ? nil : adId,
            serveId: telemetryServeId
        )
    }

    private func handleVideoClick() {
        let capturedScene = fallbackVideoRouteOriginatingScene(
            originatingScene,
            isForegroundActive: { $0.activationState == .foregroundActive }
        )
        guard fallbackVideoRouteExecutionIsActive(
            routeActive: activeRouteLifecycle.isActive,
            hasAppeared: hasAppeared,
            appForegrounded: appForegrounded,
            applicationActive: UIApplication.shared.applicationState == .active,
            sceneForegroundActive: capturedScene != nil
        ), let originatingScene = capturedScene else { return }
        guard canBeginFallbackVideoClick(
            pageFinished: pageFinished,
            clickHandoffPending: clickHandoffPending,
            routeActive: activeRouteLifecycle.isActive,
            trackingUrl: ctaTrackingUrl,
            destination: ctaDestination,
            storeUrl: ctaStoreUrl
        ) else { return }
        guard let automaticUserHandoff = activeRouteLifecycle.automaticRoutes.beginUserHandoff(
            scope: activeRouteLifecycle.automaticRouteScope
        ) else { return }
        let interaction = ClickInteraction(source: .fallbackCTA)
        updateClickHandoffPending(true)
        handleAdClick(interaction)
        ClickHandoffPersistence.wait(
            interaction: interaction,
            beaconImpressionId: nativeClickBeaconImpressionId
        ) {
            DispatchQueue.main.async {
                let execution = AttributionRouteExecution(
                    originatingScene: originatingScene,
                    isActive: {
                        fallbackVideoRouteExecutionIsActive(
                            routeActive: activeRouteLifecycle.isActive,
                            hasAppeared: hasAppeared,
                            appForegrounded: appForegrounded,
                            applicationActive: UIApplication.shared.applicationState == .active,
                            sceneForegroundActive:
                                originatingScene.activationState == .foregroundActive
                        )
                    },
                    allowsDetachedDeterministicAttribution: true,
                    survivesPresentationTeardownAfterBegin: true,
                    canCompleteAfterPresentationTeardown:
                        committedRouteTerminalAvailability(originatingScene: originatingScene),
                    onUIHandoffReleased: { updateClickHandoffPending(false) },
                    onOutcome: { _ in }
                )
                routeCommittedUserHandoff(
                    coordinator: activeRouteLifecycle.automaticRoutes,
                    handoff: automaticUserHandoff,
                    scope: activeRouteLifecycle.automaticRouteScope,
                    execution: execution
                ) { execution in
                    CreativeCTARouter.open(
                        trackingUrl: ctaTrackingUrl,
                        destination: ctaDestination,
                        storeOpen: ctaStoreOpen,
                        storeUrl: ctaStoreUrl,
                        attribution: attribution,
                        storeProductOwnership: activeRouteLifecycle.storeProductOwnership,
                        execution: execution
                    )
                }
            }
        }
    }
    #endif
}

func fallbackVideoRouteOriginatingScene<Scene: AnyObject>(
    _ capturedScene: Scene?,
    isForegroundActive: (Scene) -> Bool
) -> Scene? {
    guard let capturedScene, isForegroundActive(capturedScene) else { return nil }
    return capturedScene
}

func fallbackVideoRouteExecutionIsActive(
    routeActive: Bool,
    hasAppeared: Bool,
    appForegrounded: Bool,
    applicationActive: Bool,
    sceneForegroundActive: Bool
) -> Bool {
    routeActive && hasAppeared && appForegrounded && applicationActive && sceneForegroundActive
}

func fallbackPresentationBlocked(
    appForegrounded: Bool,
    storeSheetPresented: Bool
) -> Bool {
    fullscreenPresentationBlocked(
        appForegrounded: appForegrounded,
        storeSheetPresented: storeSheetPresented
    )
}

func shouldShowFallbackLoadingShield(
    isVideo: Bool,
    adPageReady: Bool,
    terminalFailure: Bool
) -> Bool {
    isVideo ? terminalFailure : !adPageReady
}

enum FallbackCloseRequestAction: Equatable, Sendable {
    case ignore
    case requestFailureAdvance
    case close
}

func fallbackCloseRequestAction(
    isVideo: Bool,
    pageFinished: Bool,
    terminalFailure: Bool,
    appForegrounded: Bool,
    storeSheetPresented: Bool,
    dismissUnlocked: Bool,
    clickHandoffPending: Bool
) -> FallbackCloseRequestAction {
    if isVideo && terminalFailure { return .requestFailureAdvance }
    guard !isVideo || pageFinished,
          appForegrounded, !storeSheetPresented,
          canDismissFullscreen(
              dismissUnlocked: dismissUnlocked,
              clickHandoffPending: clickHandoffPending
          ) else { return .ignore }
    return .close
}

func shouldRunFallbackCountdown(
    isVideo: Bool,
    pageFinished: Bool,
    hasAppeared: Bool,
    appForegrounded: Bool,
    storeSheetPresented: Bool
) -> Bool {
    hasAppeared && (!isVideo || pageFinished) && appForegrounded && !storeSheetPresented
}

func canBeginFallbackVideoClick(
    pageFinished: Bool,
    clickHandoffPending: Bool,
    routeActive: Bool,
    trackingUrl: String?,
    destination: AdDestination,
    storeUrl: String?
) -> Bool {
    pageFinished && !clickHandoffPending && routeActive && hasRoutableVideoDestination(
        trackingUrl: trackingUrl,
        destination: destination,
        storeUrl: storeUrl
    )
}

func fallbackNativeClickBeaconImpressionId(
    adId: String,
    capabilities: DeviceCapabilities,
    nativeClickBeaconV1Enabled: Bool
) -> String? {
    guard capabilities.nativeClickBeaconV1, nativeClickBeaconV1Enabled, !adId.isEmpty else {
        return nil
    }
    return adId
}

struct FallbackNativeClickBeaconClaim: Equatable {
    let impressionId: String
    let interactionId: String
    let clickSource: String
}

struct FallbackClickTelemetryContext: Equatable {
    let adFormat: String
    let adUnitId: String?
    let adId: String?
    let serveId: String?
}

func accountFallbackClick(
    adId: String,
    interaction: ClickInteraction,
    capabilities: DeviceCapabilities,
    nativeClickBeaconV1Enabled: Bool,
    adFormat: String,
    adUnitId: String?,
    serveId: String?,
    recordTelemetry: (FallbackClickTelemetryContext, ClickInteraction) -> Void,
    enqueueBeacon: (FallbackNativeClickBeaconClaim, FallbackClickTelemetryContext) -> Void,
    notifyPublisher: (ClickInteraction) -> Void
) {
    let context = FallbackClickTelemetryContext(
        adFormat: adFormat,
        adUnitId: adUnitId,
        adId: adId.isEmpty ? nil : adId,
        serveId: serveId?.isEmpty == false ? serveId : nil
    )
    recordTelemetry(context, interaction)
    if let claim = fallbackNativeClickBeaconClaim(
        adId: adId,
        interaction: interaction,
        capabilities: capabilities,
        nativeClickBeaconV1Enabled: nativeClickBeaconV1Enabled
    ) {
        enqueueBeacon(claim, context)
    }
    notifyPublisher(interaction)
}

func fallbackNativeClickBeaconClaim(
    adId: String,
    interaction: ClickInteraction,
    capabilities: DeviceCapabilities,
    nativeClickBeaconV1Enabled: Bool
) -> FallbackNativeClickBeaconClaim? {
    guard let impressionId = fallbackNativeClickBeaconImpressionId(
        adId: adId,
        capabilities: capabilities,
        nativeClickBeaconV1Enabled: nativeClickBeaconV1Enabled
    ) else { return nil }
    return FallbackNativeClickBeaconClaim(
        impressionId: impressionId,
        interactionId: interaction.id,
        clickSource: interaction.source.rawValue
    )
}

// MARK: - AdCountdownLifecycle

/// Pauses an ad overlay's countdown while the app is backgrounded or an in-app store/Safari sheet
/// covers it, resuming when both clear. iOS-only — a no-op on other platforms. The overlay lives in a
/// stand-alone `UIWindow`, where SwiftUI's `\.scenePhase` doesn't track the app lifecycle, so this
/// observes `UIApplication` background/foreground + the store-sheet notifications directly.
private struct AdCountdownLifecycle: ViewModifier {
    let onBackground: () -> Void
    let onForeground: () -> Void
    let onSheetPresent: () -> Void
    let onSheetDismiss: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in onBackground() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in onForeground() }
            .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetWillPresent)) { _ in onSheetPresent() }
            .onReceive(NotificationCenter.default.publisher(for: .simulaAdExternalSheetDidDismiss)) { _ in onSheetDismiss() }
        #else
        content
        #endif
    }
}
