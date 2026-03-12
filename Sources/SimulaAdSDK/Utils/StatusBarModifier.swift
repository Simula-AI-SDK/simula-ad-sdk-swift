import SwiftUI

#if os(iOS)
import UIKit

// MARK: - StatusBarOverlayWindow

/// Manages a transparent overlay window that controls status bar visibility.
/// The child-VC `.background()` approach doesn't work because SwiftUI's hosting VC
/// doesn't forward `childForStatusBarHidden`. Instead, we use a separate UIWindow
/// whose root VC has `prefersStatusBarHidden = true`. When visible, this window's
/// root VC controls the status bar.
private class StatusBarOverlayWindow {
    static let shared = StatusBarOverlayWindow()

    private var overlayWindow: UIWindow?

    func setHidden(_ hidden: Bool, in scene: UIWindowScene) {
        if hidden {
            if overlayWindow == nil {
                let win = UIWindow(windowScene: scene)
                win.windowLevel = .statusBar + 1
                win.rootViewController = StatusBarRootVC()
                win.isUserInteractionEnabled = false
                win.backgroundColor = .clear
                overlayWindow = win
            }
            overlayWindow?.isHidden = false
        } else {
            overlayWindow?.isHidden = true
        }
    }

    private class StatusBarRootVC: UIViewController {
        override var prefersStatusBarHidden: Bool { true }
        override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    }
}

// MARK: - StatusBarHiddenModifier

/// A UIViewControllerRepresentable that triggers the overlay window approach.
private struct StatusBarHiddenViewController: UIViewControllerRepresentable {
    let hidden: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.isUserInteractionEnabled = false
        vc.view.backgroundColor = .clear
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        // Dispatch to avoid modifying state during SwiftUI view update
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first {
                StatusBarOverlayWindow.shared.setHidden(self.hidden, in: windowScene)
            }
        }
    }
}

extension View {
    /// Hides the status bar using an overlay window approach that works reliably
    /// even when views are nested inside overlays or ZStacks.
    func hideStatusBar(_ hidden: Bool) -> some View {
        self.background(StatusBarHiddenViewController(hidden: hidden))
    }
}

#else

extension View {
    func hideStatusBar(_ hidden: Bool) -> some View {
        self
    }
}

#endif
