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

    /// Presents the fallback ad screens in order. Returns `true` if they were presented; `false`
    /// when `ads` is empty or no window scene was available (`onClose` is then never called).
    @discardableResult
    func present(ads: [FallbackAd], onClose: @escaping () -> Void) -> Bool {
        guard !ads.isEmpty, let scene = Self.activeWindowScene() else { return false }
        self.ads = ads
        self.index = 0
        self.onClose = onClose

        originalKeyWindow = scene.keyWindow

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = hostingController(for: ads[0])
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    /// A fresh hosting controller per screen so each gets its own overlay state (countdown ring).
    private func hostingController(for ad: FallbackAd) -> UIHostingController<AdOverlayView> {
        let root = AdOverlayView(
            iframeUrl: ad.iframeUrl,
            onClose: { [weak self] in self?.advance() },
            adId: ad.adId
        )
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear
        return hosting
    }

    /// Reveal the next screen on each close tap; tear down after the last one.
    private func advance() {
        index += 1
        if index < ads.count, let window {
            window.rootViewController = hostingController(for: ads[index])
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
