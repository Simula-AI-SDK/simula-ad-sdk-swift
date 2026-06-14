import Foundation
#if os(iOS)
import UIKit
#endif

/// Resolves a caller-supplied `theme` to the value sent on `POST /load/native`.
///
/// `"dark"` / `"light"` pass through; `"system"` is resolved to one of those using the current
/// appearance; `nil` stays `nil` (the key is omitted and the backend defaults to light). The
/// appearance source differs by context — SwiftUI reads `@Environment(\.colorScheme)`, the imperative
/// preload path reads ``systemIsDark`` — so resolution always happens at the call site and the network
/// layer only ever sees a concrete `"dark"` / `"light"` / `nil`.
enum NativeAdTheme {
    /// `"system"` → `"dark"`/`"light"` per `isDark`; every other non-nil value passes through; `nil`
    /// stays `nil`.
    static func resolve(_ theme: String?, isDark: Bool) -> String? {
        guard let theme else { return nil }
        if theme == "system" { return isDark ? "dark" : "light" }
        return theme
    }

    #if os(iOS)
    /// Imperative-context dark-mode check (no SwiftUI environment available), for the preload path.
    @MainActor
    static var systemIsDark: Bool {
        UITraitCollection.current.userInterfaceStyle == .dark
    }
    #endif
}
