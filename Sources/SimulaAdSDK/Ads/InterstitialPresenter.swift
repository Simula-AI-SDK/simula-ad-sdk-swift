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
    /// inside the creative is tapped (CLICKED); `onEarnReward` fires on dismiss of a
    /// rewarded ad once the minimum view threshold was reached (EARNED_REWARD);
    /// `onClose` fires once the window has been torn down (CLOSED).
    ///
    /// - Returns: `true` if the overlay was presented; `false` if no window scene
    ///   was available (in which case the callbacks are never called).
    @discardableResult
    func present(
        apiKey: String,
        response: AdLoadResponse,
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

/// Full-screen native creative: the server-rendered `rendered_html` displayed in a
/// web view on black, with a top-right close button. The HTML owns its own CTA — a
/// user-initiated link tap inside it is intercepted by the web view's coordinator
/// (which routes to the store/Safari sheet) and reported here as CLICKED.
///
/// Rewarded creatives gate the close button behind a minimum view duration: the
/// close button stays hidden until `minPlayThreshold` seconds elapse, then it
/// appears and `rewardEarned` is set. On dismiss, `onEarnReward()` fires iff the
/// reward was earned.
private struct CreativeInterstitialView: View {
    let response: AdLoadResponse
    let minPlayThreshold: TimeInterval
    let onClick: () -> Void
    let onEarnReward: () -> Void
    let onRequestDismiss: () -> Void

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
        minPlayThreshold: TimeInterval,
        onClick: @escaping () -> Void,
        onEarnReward: @escaping () -> Void,
        onRequestDismiss: @escaping () -> Void
    ) {
        self.response = response
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The server-rendered HTML creative, full-screen. It owns its own CTA.
            if let html = response.htmlCreative {
                htmlCreativeView(html)
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
        }
        .opacity(visible ? 1 : 0)
        // Once a dismiss starts (`visible == false`) the surface is still on screen
        // during the 0.25s fade — opacity 0 does NOT stop hit-testing. Disable touches
        // so a second close tap in that window can't double-fire.
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: dismissAnimationDuration), value: visible)
        // The black background + HTML web view each ignore the safe area (full-screen
        // creative), but the close (top-right) overlay stays inside the safe-area
        // insets so it clears the notch / Dynamic Island.
        .hideStatusBar(true)
        .onAppear { startRewardGateIfNeeded() }
        .onDisappear {
            gateTask?.cancel()
            gateTask = nil
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

    // MARK: Actions

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
#endif
