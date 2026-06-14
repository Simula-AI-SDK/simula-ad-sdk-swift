#if os(iOS)
import SwiftUI
import UIKit

/// OMID-shaped viewability seam for native ads.
///
/// The PRD mandates IAB OMID for impression counting (≥50% of the creative visible for ≥1 continuous
/// second; the timer resets if it scrolls out before 1s). The certified OMID binary is distributed
/// through IAB Tech Lab membership and isn't wired yet, so this is the stopgap that reproduces those
/// fire semantics with zero added dependencies.
///
/// ## OMID swap point
/// When the certified SDK lands, replace the visibility math + the single `onImpression` fire here
/// with an `OMIDAdSession` scoped to the native WebView container (`nativeOwner` access mode,
/// `display` impression type, partner = Simula). The contract is unchanged — exactly one fire when
/// the threshold is met — and the slot co-fires `onImpression` with `trackImpression`, satisfying the
/// PRD's "co-fire, do not decouple" rule.
///
/// Implementation: a clear `GeometryReader` background reports the slot's global frame; the visible
/// fraction (frame ∩ screen, area-based) drives a dwell timer. The timer runs uninterrupted while
/// the slot stays ≥ threshold and is cancelled (reset) the instant it drops below. Fires at most once.
struct NativeAdViewabilityModifier: ViewModifier {
    let enabled: Bool
    var thresholdFraction: CGFloat = 0.5
    var minVisibleSeconds: Double = 1.0
    let onImpression: () -> Void

    @State private var fired = false
    @State private var dwellTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { evaluate(visibleFraction(geo)) }
                        .onChange(of: visibleFraction(geo)) { frac in evaluate(frac) }
                }
            )
            .onDisappear {
                dwellTask?.cancel()
                dwellTask = nil
            }
    }

    private func evaluate(_ fraction: CGFloat) {
        guard enabled, !fired else { return }
        if fraction >= thresholdFraction {
            // Already counting down? Don't restart — a sustained view must keep its timer running.
            guard dwellTask == nil else { return }
            dwellTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(minVisibleSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                fired = true
                dwellTask = nil
                onImpression()
            }
        } else {
            // Dropped below threshold before the dwell elapsed → reset the timer (PRD).
            dwellTask?.cancel()
            dwellTask = nil
        }
    }

    /// Fraction (0..1) of the slot's area currently within the screen bounds.
    private func visibleFraction(_ geo: GeometryProxy) -> CGFloat {
        let frame = geo.frame(in: .global)
        let area = frame.width * frame.height
        guard area > 0 else { return 0 }
        let intersection = frame.intersection(UIScreen.main.bounds)
        guard !intersection.isNull else { return 0 }
        let visible = max(0, intersection.width) * max(0, intersection.height)
        return min(1, visible / area)
    }
}

extension View {
    /// Fire `onImpression` once when this view is ≥50% visible for ≥1 continuous second (OMID-shaped).
    func trackNativeAdViewability(enabled: Bool, onImpression: @escaping () -> Void) -> some View {
        modifier(NativeAdViewabilityModifier(enabled: enabled, onImpression: onImpression))
    }
}
#endif
