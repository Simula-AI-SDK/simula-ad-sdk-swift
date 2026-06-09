#if os(iOS)
import SwiftUI
import UIKit

// MARK: - FallbackAdPresenter

/// Presents a post-close fallback ad (`AdOverlayView`) full-screen in a dedicated `UIWindow`,
/// mirroring the declarative minigame's post-game ad flow. Used by `SimulaInterstitialAd` and
/// `SimulaRewardedAd` after the primary creative is dismissed: the host fetches a fallback ad
/// (`/minigames/fallback_ad/{adId}`) and, when one is returned, shows it here.
///
/// The window is hosted above `.normal` (independent of the host's view-controller stack), the
/// same pattern as `InterstitialPresenter`. `onClose` fires once the window is torn down.
@MainActor
final class FallbackAdPresenter {
    private var window: UIWindow?
    private var onClose: (() -> Void)?
    /// The host's key window, captured before we take key. Restored on dismiss so the host
    /// regains touch/keyboard focus.
    private weak var originalKeyWindow: UIWindow?

    /// Presents the fallback ad iframe. Returns `true` if it was presented; `false` if no window
    /// scene was available (in which case `onClose` is never called).
    @discardableResult
    func present(adId: String, iframeUrl: String, onClose: @escaping () -> Void) -> Bool {
        guard let scene = Self.activeWindowScene() else { return false }
        self.onClose = onClose

        let root = AdOverlayView(iframeUrl: iframeUrl, onClose: { [weak self] in self?.dismiss() }, adId: adId)
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear

        originalKeyWindow = scene.keyWindow

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
        return true
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
