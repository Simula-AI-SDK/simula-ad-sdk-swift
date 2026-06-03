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
    /// Remaining whole seconds for the non-rewarded close-delay countdown (numeric UI).
    @State private var closeRemaining: Int
    /// 0→1 fill for the non-rewarded close-delay countdown (ring / bar UI).
    @State private var closeProgress: Double = 0
    /// Monotonic anchor (`systemUptime`) for whichever gate is active, so a re-`onAppear`
    /// resumes the countdown from where it was instead of restarting it. `nil` until first set.
    @State private var gateStartedAt: TimeInterval?

    /// Matches the dismiss fade before the window is removed.
    private let dismissAnimationDuration: TimeInterval = 0.25

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
        _closeEnabled = State(initialValue: rewarded ? (minPlayThreshold <= 0) : (closeDelay <= 0))
        _closeRemaining = State(initialValue: max(0, closeDelay))
    }

    private var isRewarded: Bool {
        response.rewarded || response.renderedFormat == "rewarded_video"
    }

    private var assets: [String] { response.renderedAssets }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            carousel

            // Close button — driven by `ad_behavior` when present; otherwise today's literal
            // top-right button (an absent ad_behavior renders exactly as before).
            if let close = response.adBehavior?.close {
                CloseButtonView(
                    behavior: close,
                    isRewarded: isRewarded,
                    enabled: closeEnabled,
                    remaining: closeRemaining,
                    progress: closeProgress,
                    onClose: { handleClose() }
                )
            } else if closeEnabled {
                legacyCloseButton
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
            startRewardGateIfNeeded()
            startCloseDelayGate()
        }
        .onDisappear {
            gateTask?.cancel()
            gateTask = nil
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

    private func startRewardGateIfNeeded() {
        guard isRewarded, minPlayThreshold > 0, !closeEnabled else {
            // Non-gated rewarded (threshold 0) still earns its reward.
            if isRewarded { rewardEarned = true }
            return
        }
        // Resume from the monotonic anchor so a re-`onAppear` doesn't restart the dwell.
        let remaining = remainingGateTime(total: minPlayThreshold)
        if remaining <= 0 {
            rewardEarned = true
            closeEnabled = true
            return
        }
        // Cancellable min-view gate: a fire-and-forget asyncAfter would still fire
        // after dismiss and mutate dead @State. The Task is cancelled in
        // `.onDisappear`.
        gateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if Task.isCancelled { return }
            rewardEarned = true
            withAnimation(.easeInOut(duration: 0.2)) {
                closeEnabled = true
            }
        }
    }

    /// Non-rewarded close-delay gate driven by `ad_behavior.close.delay_seconds`. Drives the
    /// countdown affordance (numeric tick / ring + bar fill) and unlocks the close button once
    /// the delay elapses. Rewarded creatives ignore this (they gate on `minPlayThreshold`).
    private func startCloseDelayGate() {
        guard !isRewarded, let close = response.adBehavior?.close,
              close.delaySeconds > 0, !closeEnabled else { return }
        let total = TimeInterval(close.delaySeconds)
        let remaining = remainingGateTime(total: total)
        if remaining <= 0 {
            closeEnabled = true
            return
        }

        // Ring / bar treatments fill linearly over the remaining delay (resuming from the
        // fraction already elapsed, so a re-`onAppear` doesn't snap the fill back to 0).
        if close.countdownUI == .circularProgress || close.countdownUI == .bar {
            closeProgress = (total - remaining) / total
            withAnimation(.linear(duration: remaining)) { closeProgress = 1 }
        }

        gateTask = Task { @MainActor in
            if close.countdownUI == .numericAlways {
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

/// The `ad_behavior`-driven close button: applies size (glyph/circle), corner position, and the
/// countdown_ui treatment. Rewarded creatives ignore the countdown (they gate on `minPlayThreshold`
/// and use "appears" semantics), but still honor position/size.
private struct CloseButtonView: View {
    let behavior: CloseBehavior
    let isRewarded: Bool
    let enabled: Bool
    let remaining: Int
    let progress: Double
    let onClose: () -> Void

    /// Effective countdown affordance: rewarded creatives always use "appears" (hidden→shown).
    private var countdown: CloseCountdownUI { isRewarded ? .appearsAtNs : behavior.countdownUI }

    private var isBottom: Bool {
        behavior.position == .bottomLeft || behavior.position == .bottomRight
    }

    private var isTrailing: Bool {
        behavior.position == .topRight || behavior.position == .bottomRight
    }

    var body: some View {
        ZStack {
            // `bar` treatment: a slim top-edge progress bar shown during the delay.
            if !enabled && countdown == .bar {
                VStack {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white)
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
        // Bottom-corner buttons sit above the full-width CTA so they can't overlap it.
        .padding(.bottom, isBottom ? 96 : 0)
    }

    /// Apple HIG minimum tappable size. The visual circle may be smaller (the `small` arm), but
    /// the hit area is never below this so a tiny close button can't inflate accidental CTA taps.
    private let minTouchTarget: CGFloat = 44

    @ViewBuilder
    private var buttonOrIndicator: some View {
        if enabled {
            Button(action: onClose) {
                closeGlyph
                    .frame(
                        width: max(minTouchTarget, behavior.size.circleSize),
                        height: max(minTouchTarget, behavior.size.circleSize)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        } else {
            switch countdown {
            case .appearsAtNs, .bar:
                EmptyView() // hidden during the delay (the bar shows progress separately)
            case .none:
                closeGlyph.opacity(0.4)
            case .numericAlways:
                numericGlyph
            case .circularProgress:
                ZStack {
                    closeGlyph.opacity(0.5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: behavior.size.circleSize, height: behavior.size.circleSize)
                }
            }
        }
    }

    /// The circular "X" glyph at the configured size.
    private var closeGlyph: some View {
        Image(systemName: "xmark")
            .font(.system(size: behavior.size.glyphSize, weight: .bold))
            .foregroundColor(Color(hex: "#1F2937"))
            .frame(width: behavior.size.circleSize, height: behavior.size.circleSize)
            .background(Circle().fill(Color.white.opacity(0.9)))
    }

    /// The remaining-seconds glyph used by the `numeric_always` treatment.
    private var numericGlyph: some View {
        Text("\(remaining)")
            .font(.system(size: behavior.size.glyphSize, weight: .bold))
            .foregroundColor(Color(hex: "#1F2937"))
            .frame(width: behavior.size.circleSize, height: behavior.size.circleSize)
            .background(Circle().fill(Color.white.opacity(0.9)))
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
