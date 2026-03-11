import SwiftUI

#if os(iOS)

/// A UIViewControllerRepresentable that forces `prefersStatusBarHidden` at the UIKit level.
/// SwiftUI's `.statusBarHidden()` is unreliable when views are nested inside overlays/ZStacks
/// rather than presented modally. This approach injects a child view controller that directly
/// controls the status bar.
private struct StatusBarHiddenViewController: UIViewControllerRepresentable {
    let hidden: Bool

    func makeUIViewController(context: Context) -> StatusBarController {
        StatusBarController()
    }

    func updateUIViewController(_ controller: StatusBarController, context: Context) {
        controller.statusBarHidden = hidden
    }

    class StatusBarController: UIViewController {
        var statusBarHidden = false {
            didSet { setNeedsStatusBarAppearanceUpdate() }
        }

        override var prefersStatusBarHidden: Bool { statusBarHidden }
        override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
    }
}

extension View {
    /// Hides the status bar using a UIKit-level approach that works reliably
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
