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

// MARK: - App-level status bar (host-independent fallback)

/// Hides the status bar via the app-level API, ref-counted across overlapping presenters.
///
/// The view-controller-based `hideStatusBar(_:)` overlay above only takes effect when the host
/// keeps `UIViewControllerBasedStatusBarAppearance` enabled (the iOS default). React Native's
/// template sets it to `NO`, which makes ALL view-controller-based status-bar control a no-op —
/// so a full-screen ad presented in its own window can't hide the bar that way and shows it.
///
/// This bridges that gap: when (and only when) the host has opted out of VC-based appearance, the
/// full-screen ad presenters drive the app-level status bar instead. It is gated on that Info.plist
/// flag so native hosts (VC-based = YES) are left entirely to the overlay mechanism — calling this
/// there is a pure no-op, so it can't regress them. Ref-counting keeps the bar hidden across the
/// interstitial→fallback handoff (two presenter windows briefly overlap) and restores the host's
/// original state only once the last presenter ends. Mirrors React Native's own StatusBar module.
@MainActor
enum SimulaAppStatusBar {
    /// True only when the host disabled view-controller-based status-bar appearance, so the
    /// VC-based overlay can't work and we must fall back to the app-level API.
    private static let usesAppLevelStatusBar: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "UIViewControllerBasedStatusBarAppearance") as? Bool) == false

    private static var depth = 0
    private static var baselineHidden = false

    /// Hide the status bar for the duration of a full-screen presentation (balanced by `restore()`).
    static func hide() {
        guard usesAppLevelStatusBar else { return }
        if depth == 0 {
            baselineHidden = UIApplication.shared.isStatusBarHidden
            UIApplication.shared.setStatusBarHidden(true, with: .fade)
        }
        depth += 1
    }

    /// Release one `hide()`; restores the host's original status-bar state when the last one ends.
    static func restore() {
        guard usesAppLevelStatusBar, depth > 0 else { return }
        depth -= 1
        if depth == 0 {
            UIApplication.shared.setStatusBarHidden(baselineHidden, with: .fade)
        }
    }
}

#else

extension View {
    func hideStatusBar(_ hidden: Bool) -> some View {
        self
    }
}

#endif
