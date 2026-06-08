#if os(iOS)
import SwiftUI
import UIKit

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

        let root = CreativeInterstitialView(
            response: response,
            onClick: onClick,
            onRequestDismiss: { [weak self] in self?.dismiss() }
        )

        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear

        // Remember who held key so we can hand it back on dismiss.
        originalKeyWindow = scene.keyWindow

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    /// Tears down the presentation window and fires the CLOSED callback once.
    private func dismiss() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        // Restore the host's key window so it regains touch/keyboard focus.
        originalKeyWindow?.makeKey()
        originalKeyWindow = nil
        let callback = onClose
        onClose = nil
        callback?()
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
    let response: AdLoadResponse
    let onClick: () -> Void
    let onRequestDismiss: () -> Void

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

    // Mid-ad store prompt (`store_prompt`) — a tappable badge revealed at the 50% playable mark.
    @State private var storePromptVisible = false
    @State private var storePromptScheduled = false
    @State private var storePromptTask: Task<Void, Never>?

    // SKOverlay install banner (`skoverlay`) — resolved app id + one-shot presentation.
    @State private var resolvedAppID: String?
    @State private var skOverlayPresented = false
    @State private var skOverlayTask: Task<Void, Never>?

    /// Matches the dismiss fade before the window is removed.
    private let dismissAnimationDuration: TimeInterval = 0.25
    /// Fallback playable length used to time the store prompt's 50% trigger when no playable
    /// `midpoint` JS-bridge event arrives.
    private let nominalPlayableDuration: TimeInterval = 30

    init(
        response: AdLoadResponse,
        onClick: @escaping () -> Void,
        onRequestDismiss: @escaping () -> Void
    ) {
        self.response = response
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The server-rendered HTML creative, full-screen. It owns its own CTA.
            if let html = response.htmlCreative {
                htmlCreativeView(html)
            }

            // Close button — driven by `ad_behavior` when present; otherwise today's literal
            // always-available top-right button (an absent ad_behavior renders exactly as before).
            if let close = response.adBehavior?.close {
                CloseButtonView(
                    treatment: close.treatment,
                    position: close.position,
                    progressBarColor: close.progressBarColor,
                    isRewardCopy: isRewardCopy,
                    enabled: closeEnabled,
                    remaining: closeRemaining,
                    progress: closeProgress,
                    onClose: { handleClose() }
                )
            } else {
                legacyCloseButton
            }

            // Mid-ad store prompt — independent of the close button and SKOverlay. Rendered at the
            // server-resolved position (never recomputed) once the 50% playable mark is reached.
            if let prompt = response.adBehavior?.storePrompt, prompt.enabled, storePromptVisible {
                StorePromptBadge(prompt: prompt, onTap: { handleStorePromptTap() })
            }
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
    }

    // MARK: Close button (legacy / no ad_behavior)

    /// Today's literal top-right close button, rendered only when the payload omits
    /// `ad_behavior`. Always available — kept byte-for-byte so non-experiment traffic is unchanged.
    private var legacyCloseButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: { handleClose() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "#1F2937"))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .padding(.trailing, 16)
                .accessibilityLabel("Close")
            }
            Spacer()
        }
    }

    // MARK: HTML creative

    @ViewBuilder
    private func htmlCreativeView(_ html: String) -> some View {
        WebViewRepresentable(
            htmlString: html,
            onMessageReceived: { handleBridgeMessage($0) },
            onAdClick: { handleHtmlClick() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
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

    /// Handles `postMessage` traffic from the creative's JS bridge. A true playable posts a
    /// `midpoint` signal at the 50% mark; we use it to reveal the store prompt directly (the
    /// wall-clock timer in `startStorePromptTrigger` is the fallback when no such event arrives).
    private func handleBridgeMessage(_ message: String) {
        guard response.adBehavior?.storePrompt?.enabled == true else { return }
        if message.localizedCaseInsensitiveContains("midpoint") {
            showStorePrompt()
        }
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
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.2)) { closeEnabled = true }
        }
    }

    // MARK: Store prompt (mid-ad)

    /// Schedules the mid-ad store prompt's 50% trigger. A true playable posts a `midpoint`
    /// JS-bridge event and reveals the prompt via `handleBridgeMessage`; this wall-clock timer at
    /// 50% of the nominal playable duration is the fallback when no such signal arrives.
    private func startStorePromptTrigger() {
        guard let prompt = response.adBehavior?.storePrompt, prompt.enabled,
              !storePromptScheduled, !storePromptVisible else { return }
        storePromptScheduled = true
        storePromptTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(nominalPlayableDuration / 2 * 1_000_000_000))
            if Task.isCancelled { return }
            showStorePrompt()
        }
    }

    /// Reveals the store prompt. Idempotent — safe to call from a JS-bridge `midpoint` event
    /// (true playables) or from the timer fallback.
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
            storeOpen: storeOpen
        )
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
        SKOverlayPresenter.present(appID: appID, config: config)
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
        return total - (now - startedAt)
    }
}

// MARK: - CloseButtonView

/// The `ad_behavior`-driven close button. Renders the assigned `treatment` at the configured
/// corner: `hidden` shows nothing until the gate unlocks, `countdownCircle` draws a ring,
/// `progressBar` a top-edge bar, `rewardOrCloseLabel` a counting-down text pill. `progressBarColor`
/// tints the ring/bar fill. The `rewardOrCloseLabel` copy is reward- vs interstitial-aware.
private struct CloseButtonView: View {
    let treatment: CloseTreatment
    let position: ClosePosition
    let progressBarColor: String
    /// `true` → "Reward in X"; `false` → "Close in X" (only used by `rewardOrCloseLabel`).
    let isRewardCopy: Bool
    let enabled: Bool
    let remaining: Int
    let progress: Double
    let onClose: () -> Void

    // Visible close affordance sized to match AdMob / AppLovin (a compact ~28–30pt circle), while
    // the tappable frame stays at the 44pt HIG minimum (see `minTouchTarget`). The 44pt circle used
    // before was the touch-target minimum mistakenly used as the visual size.
    private let glyphSize: CGFloat = 16
    private let circleSize: CGFloat = 30
    private let minTouchTarget: CGFloat = 44

    /// Tappable footprint, used identically by the in-delay indicator and the unlocked button so the
    /// glyph keeps the same size/position and doesn't jump when the close button activates.
    private var touchSize: CGFloat { max(minTouchTarget, circleSize) }

    /// Fill tint for the ring / bar. Validated upstream, so `Color(hex:)` always gets clean input.
    private var tint: Color { Color(hex: progressBarColor) }

    /// SwiftUI alignment for the configured corner.
    private var cornerAlignment: Alignment {
        switch position {
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        case .bottomLeft: return .bottomLeading
        }
    }

    var body: some View {
        ZStack {
            // `progress_bar` treatment: a full-width bar pinned to the very top edge of the screen
            // (inside the status-bar region), shown during the delay and tinted by color.
            if !enabled && treatment == .progressBar {
                progressBar
            }

            // The button (or its in-delay indicator), pinned to the configured corner. An explicit
            // fill-and-align frame is used (NOT VStack/HStack + Spacer): the Spacer approach can
            // collapse to center when this view sits beside the `.ignoresSafeArea()` web view and
            // isn't proposed a full-size container, which made every position render at the same spot.
            // A tight 8pt inset keeps the button close to the corner (AdMob / AppLovin-style).
            buttonOrIndicator
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cornerAlignment)
        }
    }

    /// The full-width progress bar pinned to the very top edge of the screen for the `progress_bar`
    /// treatment — spans edge-to-edge inside the top nav / status-bar region.
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.25))
                Rectangle().fill(tint)
                    .frame(width: max(0, geo.size.width * progress))
            }
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var buttonOrIndicator: some View {
        if enabled {
            // The resolved tap target: a labelled pill for `rewardOrCloseLabel`, the circular X
            // for every other treatment.
            Button(action: onClose) {
                if treatment == .rewardOrCloseLabel {
                    labelPill(text: "Close")
                } else {
                    closeGlyph
                        .frame(width: touchSize, height: touchSize)
                        .contentShape(Rectangle())
                }
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
    private func labelPill(text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Color(hex: "#1F2937"))
            .padding(.horizontal, 14)
            .frame(height: minTouchTarget)
            .background(Capsule().fill(Color.white.opacity(0.9)))
    }
}

// MARK: - StorePromptBadge

/// The mid-ad store prompt (`store_prompt`): a tappable "▶| App Store" / "▶| Google Play" badge
/// rendered at the server-resolved corner. The SDK never recomputes the position — it trusts the
/// backend's collision resolution (opposite the close button).
private struct StorePromptBadge: View {
    let prompt: StorePrompt
    let onTap: () -> Void

    private var label: String {
        prompt.platform == .android ? "▶| Google Play" : "▶| App Store"
    }
    private var cornerAlignment: Alignment {
        switch prompt.position {
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        case .bottomLeft: return .bottomLeading
        }
    }

    var body: some View {
        badge
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cornerAlignment)
    }

    private var badge: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Install")
    }
}
#endif
