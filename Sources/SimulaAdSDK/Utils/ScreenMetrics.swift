#if os(iOS)
import UIKit

// MARK: - Screen Metrics

/// The active window scene's size in points.
///
/// Replaces the deprecated `UIScreen.main`, which doesn't reflect the real
/// window under Stage Manager / iPad multitasking and doesn't track rotation.
/// Prefers the key window's bounds (the space the SDK actually draws into),
/// falling back to the scene's screen, then a reasonable default.
func simulaScreenSize() -> CGSize {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    if let scene {
        if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            return window.bounds.size
        }
        return scene.screen.bounds.size
    }
    return CGSize(width: 390, height: 844)
}
#endif
