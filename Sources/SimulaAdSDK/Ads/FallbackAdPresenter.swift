#if os(iOS)
import SwiftUI
import UIKit

// MARK: - FallbackAdPresenter

/// Presents the post-close fallback ad screens (`AdOverlayView`) full-screen in a dedicated
/// `UIWindow`, mirroring the declarative minigame's post-game ad flow. Used by
/// `SimulaInterstitialAd` and `SimulaRewardedAd` after the primary creative is dismissed: the host
/// fetches the serve's fallback screens (`GET /load/fallbacks/{impressionId}`) and shows them here,
/// one per close tap, in reveal order.
///
/// The window is hosted above `.normal` (independent of the host's view-controller stack), the
/// same pattern as `InterstitialPresenter`. `onClose` fires once the last screen closes and the
/// window is torn down.
@MainActor
final class FallbackAdPresenter {
    private var window: UIWindow?
    private var onClose: (() -> Void)?
    private var ads: [FallbackAd] = []
    private var index = 0
    /// The host's key window, captured before we take key. Restored on dismiss so the host
    /// regains touch/keyboard focus.
    private weak var originalKeyWindow: UIWindow?

    /// auto_store_redirect END_SCREEN_N: the primary ad's config + a closure that opens its store,
    /// fired once when the fallback screen whose index matches the trigger is presented.
    private var autoStoreRedirect: AutoStoreRedirect?
    private var onAutoStoreRedirect: (@MainActor () -> Void)?
    private var autoRedirectFired = false

    /// Presents the fallback ad screens in order. Returns `true` if they were presented; `false`
    /// when `ads` is empty or no window scene was available (`onClose` is then never called).
    @discardableResult
    func present(
        ads: [FallbackAd],
        autoStoreRedirect: AutoStoreRedirect? = nil,
        onAutoStoreRedirect: (@MainActor () -> Void)? = nil,
        onClose: @escaping () -> Void
    ) -> Bool {
        guard !ads.isEmpty, let scene = Self.activeWindowScene() else { return false }
        self.ads = ads
        self.index = 0
        self.onClose = onClose
        self.autoStoreRedirect = autoStoreRedirect
        self.onAutoStoreRedirect = onAutoStoreRedirect

        originalKeyWindow = scene.keyWindow

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        // Opaque black (not clear) so the host app never shows through — both behind the
        // end screen's safe area and during the rootViewController swap between screens.
        window.backgroundColor = .black
        window.rootViewController = hostingController(for: ads[0])
        window.makeKeyAndVisible()
        self.window = window
        // Hide the status bar in hosts that opted out of VC-based appearance (e.g. React Native),
        // where `.hideStatusBar` in the end-screen view is a no-op. No-op in native hosts.
        SimulaAppStatusBar.hide()
        fireAutoStoreRedirectIfMatching(index: 0)
        return true
    }

    /// END_SCREEN_N: open the primary ad's store once, when the fallback screen whose index matches
    /// the configured trigger is presented (index 0 = END SCREEN 1, index 1 = END SCREEN 2).
    private func fireAutoStoreRedirectIfMatching(index: Int) {
        guard !autoRedirectFired, let redirect = autoStoreRedirect, redirect.enabled,
              let trigger = AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: index),
              redirect.trigger == trigger else { return }
        autoRedirectFired = true
        onAutoStoreRedirect?()
    }

    /// A fresh hosting controller per screen so each gets its own overlay state (countdown ring).
    private func hostingController(for ad: FallbackAd) -> UIHostingController<AdOverlayView> {
        let root = AdOverlayView(
            iframeUrl: ad.iframeUrl,
            onClose: { [weak self] in self?.advance() },
            adId: ad.adId
        )
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .black
        return hosting
    }

    /// Reveal the next screen on each close tap; tear down after the last one.
    private func advance() {
        index += 1
        if index < ads.count, let window {
            window.rootViewController = hostingController(for: ads[index])
            fireAutoStoreRedirectIfMatching(index: index)
        } else {
            dismiss()
        }
    }

    /// Tears down the presentation window and fires the close callback once.
    private func dismiss() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        originalKeyWindow?.makeKey()
        originalKeyWindow = nil
        let callback = onClose
        onClose = nil
        callback?()
        // Balanced with the present-time hide(); ref count keeps the bar hidden if the close
        // callback opens another presenter, restoring the host only when the last one ends.
        SimulaAppStatusBar.restore()
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return active
        }
        return scenes.compactMap { $0 as? UIWindowScene }.first
    }
}
#endif
