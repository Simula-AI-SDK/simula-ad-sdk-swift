#if os(iOS)
import SwiftUI
import UIKit

// MARK: - InterstitialPresenter

/// Presents the imperative interstitial full-screen in a dedicated `UIWindow`,
/// independent of the host app's view-controller stack.
///
/// The presentation is a native full-screen creative: a swipeable carousel of the
/// prefetched `rendered_assets` with an always-visible CTA that opens the
/// advertiser's store/web destination. Hosting in its own window (above `.normal`)
/// lets the imperative API present from anywhere — SwiftUI or UIKit hosts alike.
@MainActor
final class InterstitialPresenter {
    private var window: UIWindow?
    private var onClose: (() -> Void)?
    /// The host's key window, captured before we take key. Restored on dismiss so
    /// the host regains touch/keyboard focus (a new key window doesn't auto-revert).
    private weak var originalKeyWindow: UIWindow?

    /// Presents the native creative carousel. `onClick` fires when the CTA is
    /// tapped (CLICKED); `onEarnReward` fires on dismiss of a rewarded ad once the
    /// minimum view threshold was reached (EARNED_REWARD); `onClose` fires once the
    /// window has been torn down (CLOSED).
    ///
    /// - Returns: `true` if the overlay was presented; `false` if no window scene
    ///   was available (in which case the callbacks are never called).
    @discardableResult
    func present(
        apiKey: String,
        response: AdLoadResponse,
        ctaText: String,
        minPlayThreshold: TimeInterval,
        onClick: @escaping () -> Void,
        onEarnReward: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> Bool {
        guard let scene = Self.activeWindowScene() else {
            // No scene to present in — caller decides how to surface this.
            return false
        }
        self.onClose = onClose

        let root = CreativeInterstitialView(
            response: response,
            ctaText: ctaText,
            minPlayThreshold: minPlayThreshold,
            onClick: onClick,
            onEarnReward: onEarnReward,
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

/// Full-screen native creative: a paged carousel of the prefetched portrait
/// assets on black, with a top-right close button and an always-visible bottom
/// CTA. A single asset renders without paging dots.
///
/// Rewarded creatives gate the close button behind a minimum view duration:
/// the close button stays hidden until `minPlayThreshold` seconds elapse, then it
/// appears and `rewardEarned` is set. On dismiss, `onEarnReward()` fires iff the
/// reward was earned. A non-rewarded creative auto-dismisses after a CTA tap; a
/// rewarded one does not (the gate + close button drive close/reward).
private struct CreativeInterstitialView: View {
    let response: AdLoadResponse
    let ctaText: String
    let minPlayThreshold: TimeInterval
    let onClick: () -> Void
    let onEarnReward: () -> Void
    let onRequestDismiss: () -> Void

    @State private var selection = 0
    @State private var visible = true
    @State private var rewardEarned = false
    /// Whether the close button may be shown/tapped. For rewarded creatives it
    /// starts `false` and unlocks once the min-view threshold elapses.
    @State private var closeEnabled: Bool
    /// Cancellable min-view gate timer (rewarded) / close-delay gate (non-rewarded).
    /// Cancelled in `.onDisappear` so it can't fire after the surface is gone.
    @State private var gateTask: Task<Void, Never>?
    /// Remaining whole seconds for the close-delay countdown (drives the `reward_or_close_label` copy).
    @State private var closeRemaining: Int
    /// 0→1 fill for the close-delay countdown (`countdown_circle` ring / `progress_bar`).
    @State private var closeProgress: Double = 0
    /// Monotonic anchor (`systemUptime`) for whichever gate is active, so a re-`onAppear`
    /// resumes the countdown from where it was instead of restarting it. `nil` until first set.
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
    /// `midpoint` JS-bridge event is available (the image-carousel creative emits none).
    private let nominalPlayableDuration: TimeInterval = 30

    init(
        response: AdLoadResponse,
        ctaText: String,
        minPlayThreshold: TimeInterval,
        onClick: @escaping () -> Void,
        onEarnReward: @escaping () -> Void,
        onRequestDismiss: @escaping () -> Void
    ) {
        self.response = response
        self.ctaText = ctaText
        self.minPlayThreshold = minPlayThreshold
        self.onClick = onClick
        self.onEarnReward = onEarnReward
        self.onRequestDismiss = onRequestDismiss
        // Close starts enabled unless a gate applies: rewarded gates on `minPlayThreshold`
        // (unchanged); non-rewarded gates on the server-driven `close.delay_seconds`.
        let rewarded = response.rewarded || response.renderedFormat == "rewarded_video"
        let closeDelay = response.adBehavior?.close.delaySeconds ?? 0
        let gateTotal = rewarded ? minPlayThreshold : TimeInterval(closeDelay)
        _closeEnabled = State(initialValue: gateTotal <= 0)
        // Initial label count (`reward_or_close_label`): whole seconds of the active gate.
        _closeRemaining = State(initialValue: max(0, Int(ceil(gateTotal))))
    }

    private var isRewarded: Bool {
        response.rewarded || response.renderedFormat == "rewarded_video"
    }

    /// Whether the `reward_or_close_label` should read "Reward in X" (vs "Close in X"), inferred
    /// from the creative's declared ad-unit type.
    private var isRewardCopy: Bool { response.adUnitType == .rewarded }

    private var assets: [String] { response.renderedAssets }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            carousel

            // Close button — driven by `ad_behavior` when present; otherwise today's literal
            // top-right button (an absent ad_behavior renders exactly as before).
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
            } else if closeEnabled {
                legacyCloseButton
            }

            // Mid-ad store prompt — independent of the close button and SKOverlay. Rendered at the
            // server-resolved position (never recomputed) once the 50% playable mark is reached.
            if let prompt = response.adBehavior?.storePrompt, prompt.enabled, storePromptVisible {
                StorePromptBadge(prompt: prompt, onTap: { handleStorePromptTap() })
            }

            // CTA button — always visible, bottom.
            VStack {
                Spacer()
                Button(action: { handleCtaClick() }) {
                    Text(ctaText)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(hex: "#3B82F6"))
                        )
                }
                .buttonStyle(CreativeCtaButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .opacity(visible ? 1 : 0)
        // Once a dismiss starts (`visible == false`) the surface is still on screen
        // during the 0.25s fade — opacity 0 does NOT stop hit-testing. Disable touches
        // so a second CTA/close tap in that window can't double-fire CLICKED or stack
        // store/Safari sheets.
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: dismissAnimationDuration), value: visible)
        // No outer `.ignoresSafeArea()`: the black background + carousel image layer
        // each ignore it individually (full-screen creative), but the CTA (bottom)
        // and close (top-right) overlays stay inside the safe-area insets so they
        // clear the home indicator / notch / Dynamic Island.
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
    /// `ad_behavior`. Kept byte-for-byte so non-experiment traffic is unchanged.
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

    // MARK: Carousel

    @ViewBuilder
    private var carousel: some View {
        if assets.count > 1 {
            TabView(selection: $selection) {
                ForEach(Array(assets.enumerated()), id: \.offset) { index, asset in
                    assetPage(asset).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .ignoresSafeArea()
        } else if let asset = assets.first {
            assetPage(asset)
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func assetPage(_ asset: String) -> some View {
        CachedAsyncImage(url: URL(string: asset)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            default:
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
    }

    // MARK: Actions

    private func handleCtaClick() {
        onClick() // CLICKED

        // SKOverlay timed to the click (independent of the store sheet the CTA opens).
        presentSKOverlayOnClickIfNeeded()

        // Capture the destination before any teardown so the async resolve path
        // can't read freed state. `storeOpen` defaults to today's in-app store sheet
        // when the payload omits `ad_behavior`.
        let trackingUrl = response.trackingUrl
        let destination = response.destinationKind
        let storeOpen = response.adBehavior?.storeOpen ?? .skstoreproduct

        if isRewarded {
            // Rewarded creatives stay up (the min-view gate governs close/reward),
            // so the store/Safari sheet presents over the still-live interstitial
            // window — fine.
            CreativeCTARouter.open(trackingUrl: trackingUrl, destination: destination, storeOpen: storeOpen)
            return
        }

        // Non-rewarded: dismiss FIRST, then open. The interstitial lives in its own
        // key UIWindow; if we opened the sheet before tearing that window down, the
        // dismiss would destroy the just-presented sheet (and the async redirect
        // resolve would land on a dead window). So fade out, then in the post-fade
        // block run the teardown (restores the host key window + fires CLOSED /
        // auto-preload) and only then open the destination, so the sheet presents on
        // the stable host window.
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            onRequestDismiss()
            CreativeCTARouter.open(trackingUrl: trackingUrl, destination: destination, storeOpen: storeOpen)
        }
    }

    private func handleClose() {
        // Fade the whole surface out, then remove the hosting window.
        visible = false
        if isRewarded && rewardEarned {
            onEarnReward()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            onRequestDismiss()
        }
    }

    /// Unified close gate. Rewarded creatives gate on `minPlayThreshold` (and earn the reward when
    /// it elapses); non-rewarded gate on the server-driven `close.delay_seconds`. The active
    /// `treatment` drives the affordance: `countdown_circle`/`progress_bar` fill `closeProgress`,
    /// `reward_or_close_label` ticks `closeRemaining`, `hidden` shows nothing until it unlocks.
    private func startGate() {
        let treatment = response.adBehavior?.close.treatment ?? .hidden
        let total: TimeInterval = isRewarded
            ? minPlayThreshold
            : TimeInterval(response.adBehavior?.close.delaySeconds ?? 0)

        guard total > 0, !closeEnabled else {
            // No gate applies. A non-gated rewarded creative still earns its reward.
            if isRewarded { rewardEarned = true }
            return
        }

        // Resume from the monotonic anchor so a re-`onAppear` doesn't restart the countdown.
        let remaining = remainingGateTime(total: total)
        if remaining <= 0 {
            if isRewarded { rewardEarned = true }
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
            if isRewarded { rewardEarned = true }
            withAnimation(.easeInOut(duration: 0.2)) { closeEnabled = true }
        }
    }

    // MARK: Store prompt (mid-ad)

    /// Schedules the mid-ad store prompt's 50% trigger. A true playable would post a `midpoint`
    /// JS-bridge event and call `showStorePrompt()` directly; the image-carousel creative emits no
    /// such signal, so we fall back to a wall-clock timer at 50% of the nominal playable duration.
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

    // v2 dropped the per-size config; the close glyph renders at the former `.standard` size, with
    // the circle pinned to the HIG-minimum tappable target.
    private let glyphSize: CGFloat = 24
    private let circleSize: CGFloat = 44
    private let minTouchTarget: CGFloat = 44

    private var isBottom: Bool { position == .bottomLeft }
    private var isTrailing: Bool { position == .topRight }

    /// Fill tint for the ring / bar. Validated upstream, so `Color(hex:)` always gets clean input.
    private var tint: Color { Color(hex: progressBarColor) }

    var body: some View {
        ZStack {
            // `progress_bar` treatment: a slim top-edge bar shown during the delay, tinted by color.
            if !enabled && treatment == .progressBar {
                VStack {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(tint)
                                .frame(width: max(0, geo.size.width * progress))
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer()
                }
            }

            // The button (or its in-delay indicator), pinned to the configured corner.
            VStack {
                if !isBottom { cornerRow; Spacer() } else { Spacer(); cornerRow }
            }
        }
    }

    private var cornerRow: some View {
        HStack {
            if isTrailing { Spacer(); buttonOrIndicator } else { buttonOrIndicator; Spacer() }
        }
        .padding(.horizontal, 16)
        .padding(.top, isBottom ? 0 : 16)
        // Bottom-corner targets sit above the full-width CTA so they can't overlap it.
        .padding(.bottom, isBottom ? 96 : 0)
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
                        .frame(width: max(minTouchTarget, circleSize), height: max(minTouchTarget, circleSize))
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
            case .rewardOrCloseLabel:
                labelPill(text: "\(isRewardCopy ? "Reward" : "Close") in \(remaining)")
            }
        }
    }

    /// The circular "X" glyph.
    private var closeGlyph: some View {
        Image(systemName: "xmark")
            .font(.system(size: glyphSize, weight: .bold))
            .foregroundColor(Color(hex: "#1F2937"))
            .frame(width: circleSize, height: circleSize)
            .background(Circle().fill(Color.white.opacity(0.9)))
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
    private var isBottom: Bool { prompt.position == .bottomLeft }
    private var isTrailing: Bool { prompt.position == .topRight }

    var body: some View {
        VStack {
            if !isBottom { row; Spacer() } else { Spacer(); row }
        }
    }

    private var row: some View {
        HStack {
            if isTrailing { Spacer(); badge } else { badge; Spacer() }
        }
        .padding(.horizontal, 16)
        .padding(.top, isBottom ? 0 : 16)
        .padding(.bottom, isBottom ? 96 : 0)
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

// MARK: - CreativeCtaButtonStyle

private struct CreativeCtaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
#endif
