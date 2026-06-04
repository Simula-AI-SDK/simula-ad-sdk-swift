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
    /// Cancellable min-view gate timer (rewarded). Cancelled in `.onDisappear` so
    /// it can't fire after the surface is gone.
    @State private var gateTask: Task<Void, Never>?

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
        // Non-rewarded: close always available. Rewarded with no threshold: also
        // immediately available; otherwise gated by the timer below.
        _closeEnabled = State(initialValue: !(response.rewarded || response.renderedFormat == "rewarded_video") || minPlayThreshold <= 0)
    }

    private var isRewarded: Bool {
        response.rewarded || response.renderedFormat == "rewarded_video"
    }

    private var assets: [String] { response.renderedAssets }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // A non-blank `rendered_html` renders full-screen and takes precedence
            // over the image carousel.
            if let html = response.htmlCreative {
                htmlCreativeView(html)
            } else {
                carousel
            }

            // Close button — top right (hidden until enabled for rewarded ads).
            if closeEnabled {
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

            // CTA button — always visible, bottom. Shown only for the carousel
            // (asset) path: an HTML creative owns its own CTA, so the SDK button is
            // suppressed and the in-creative link drives CLICKED instead.
            if response.htmlCreative == nil {
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
        .onAppear { startRewardGateIfNeeded() }
        .onDisappear {
            gateTask?.cancel()
            gateTask = nil
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

    // MARK: HTML creative

    @ViewBuilder
    private func htmlCreativeView(_ html: String) -> some View {
        WebViewRepresentable(htmlString: html, onAdClick: { handleHtmlClick() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .ignoresSafeArea()
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
        // can't read freed state.
        let trackingUrl = response.trackingUrl
        let destination = response.destinationKind

        if isRewarded {
            // Rewarded creatives stay up (the min-view gate governs close/reward),
            // so the store/Safari sheet presents over the still-live interstitial
            // window — fine.
            CreativeCTARouter.open(trackingUrl: trackingUrl, destination: destination)
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
            CreativeCTARouter.open(trackingUrl: trackingUrl, destination: destination)
        }
    }

    /// Fired when a user-initiated link inside the HTML creative is intercepted by
    /// the web view. The web view's coordinator routes the tapped link to the
    /// store/Safari sheet (which presents over this still-live interstitial window),
    /// so here we only emit CLICKED. We intentionally do NOT auto-dismiss: tearing
    /// the window down would destroy the just-presented sheet. Dismissal is driven by
    /// the close button (gated for rewarded creatives).
    private func handleHtmlClick() {
        onClick() // CLICKED
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
        // Cancellable min-view gate: a fire-and-forget asyncAfter would still fire
        // after dismiss and mutate dead @State. The Task is cancelled in
        // `.onDisappear`.
        gateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(minPlayThreshold * 1_000_000_000))
            if Task.isCancelled { return }
            rewardEarned = true
            withAnimation(.easeInOut(duration: 0.2)) {
                closeEnabled = true
            }
        }
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
