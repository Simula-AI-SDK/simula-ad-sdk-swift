#if os(iOS)
import SwiftUI
import UIKit

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
        durationSeconds: Int,
        storePrompt: StorePrompt? = nil,
        trackingUrl: String? = nil,
        destination: AdDestination = .appstore,
        storeOpen: StoreOpen = .skstoreproduct,
        attribution: AdAttribution? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        previewHTML: String? = nil,
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
            durationSeconds: durationSeconds,
            storePrompt: storePrompt,
            trackingUrl: trackingUrl,
            destination: destination,
            storeOpen: storeOpen,
            attribution: attribution,
            autoStoreRedirect: autoStoreRedirect,
            previewHTML: previewHTML,
            bridge: bridge,
            onFinish: { [weak self] earned, elapsed in
                self?.dismiss(earned: earned, elapsedPlayTime: elapsed)
            }
        )

        let hosting = OrientationLockingHostingController(rootView: root)
        hosting.view.backgroundColor = .clear

        originalKeyWindow = scene.keyWindow

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
        // Give the bridge the orientation host + window now that they exist.
        bridge.orientationHost = hosting
        bridge.window = window
        return true
    }

    /// Tears down the presentation window and fires the close callback once.
    private func dismiss(earned: Bool, elapsedPlayTime: Double) {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        originalKeyWindow?.makeKey()
        originalKeyWindow = nil
        let callback = onClose
        onClose = nil
        callback?(earned, elapsedPlayTime)
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
/// counting down the remaining play time. The reward is earned once `durationSeconds` of play
/// elapse; closing earlier prompts an exit confirmation so the user doesn't lose the
/// reward by accident. On a qualifying close, `onFinish(earned, elapsedPlayTime)`
/// fires after the dismiss fade.
private struct RewardedGameView: View {
    /// The impression id from /load/rewarded — drives the ad-info report overlay.
    let impressionId: String
    let apiKey: String
    let iframeUrl: String
    let durationSeconds: Int
    // Mid-ad store prompt config + tap routing. `storePrompt == nil` → no badge.
    let storePrompt: StorePrompt?
    let trackingUrl: String?
    let destination: AdDestination
    let storeOpen: StoreOpen
    /// Ad-network attribution tokens carried into the store sheet when the mid-ad store prompt is tapped.
    let attribution: AdAttribution?
    /// auto_store_redirect config — fires the store open once at the configured creative moment.
    let autoStoreRedirect: AutoStoreRedirect?
    /// When set, render this HTML instead of `iframeUrl` (preview / QA placeholder playable).
    let previewHTML: String?
    /// WebView ↔ SDK bridge (PRD §3). `AD_EARLY_COMPLETE` flips `earlyComplete` (observed below).
    let bridge: CreativeBridge
    let onFinish: (Bool, Double) -> Void

    @State private var elapsedPlayTime: Double = 0
    @State private var rewardEarned = false
    @State private var storePromptVisible = false
    @State private var visible = true
    @State private var timerTask: Task<Void, Never>?
    /// auto_store_redirect one-shot guard.
    @State private var autoRedirectFired = false

    /// Matches the dismiss fade before the window is removed.
    private let dismissAnimationDuration: TimeInterval = 0.25

    private var secondsLeft: Int {
        max(0, durationSeconds - Int(elapsedPlayTime))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Sits below the safe area (the black backdrop fills the notch / home-indicator region).
            if let previewHTML {
                WebViewRepresentable(htmlString: previewHTML, bridge: bridge)
            } else if let url = URL(string: iframeUrl) {
                WebViewRepresentable(url: url, bridge: bridge)
            }

            // Top-right reward/close pill: a "Play to earn" countdown while the reward is being
            // earned (display-only — there is no early exit), which becomes the close button
            // ("✕ Reward unlocked") the moment the reward is earned. The whole pill then dismisses.
            rewardClosePill
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .animation(.default, value: rewardEarned)

            // Mid-ad store prompt — appears at half the play-to-earn duration and is removed the
            // instant the reward unlocks (the reward/close pill takes over). Rendered at the
            // server-resolved corner (verbatim); a tap routes to the advertised store.
            if let prompt = storePrompt, prompt.enabled, storePromptVisible, !rewardEarned {
                // Match the reward/close pill's 8pt inset so both share the same top baseline.
                StorePromptBadge(prompt: prompt, edgePadding: 8, onTap: { handleStorePromptTap() })
            }

            // Persistent ad-info "i" + report sheet (required disclosure). Last so its sheet overlays.
            AdInfoReportOverlay(adId: impressionId, apiKey: apiKey)
        }
        .opacity(visible ? 1 : 0)
        // Opacity 0 does not stop hit-testing during the fade; disable touches so a
        // second close tap can't double-fire.
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: dismissAnimationDuration), value: visible)
        .hideStatusBar(true)
        .onAppear {
            startTimer()
            // PLAYABLE_END: if the reward was already earned (duration 0), fire immediately.
            fireAutoStoreRedirectIfCloseShown()
        }
        .onDisappear {
            timerTask?.cancel()
            timerTask = nil
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

    @ViewBuilder
    private var rewardClosePill: some View {
        if rewardEarned {
            // Earned: a compact circular X close button (AppLovin-style); tapping it dismisses.
            Button(action: { finish(earned: true) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.black.opacity(0.5)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        } else {
            // Still earning: a small display-only status — no close affordance yet.
            Text("Play to earn: \(secondsLeft)s")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color.black.opacity(0.6)))
        }
    }

    // MARK: Timer

    private func startTimer() {
        guard timerTask == nil else { return }
        // A zero/negative duration is earned immediately (no gate).
        guard durationSeconds > 0 else {
            rewardEarned = true
            return
        }
        timerTask = Task { @MainActor in
            while elapsedPlayTime < Double(durationSeconds) && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                elapsedPlayTime += 1
                // Reveal the store prompt at the halfway point to the reward (mid play-to-earn).
                if elapsedPlayTime >= Double(durationSeconds) / 2 {
                    withAnimation(.easeInOut(duration: 0.25)) { storePromptVisible = true }
                }
                if elapsedPlayTime >= Double(durationSeconds) {
                    rewardEarned = true
                }
            }
        }
    }

    /// Routes a store-prompt tap to the advertised destination (shared CTA router).
    private func handleStorePromptTap() {
        CreativeCTARouter.open(trackingUrl: trackingUrl, destination: destination, storeOpen: storeOpen, attribution: attribution)
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
