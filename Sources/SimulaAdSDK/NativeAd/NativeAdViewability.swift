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
    /// Forwards the slot's live visible fraction (0..1) on every layout/scroll frame so the creative
    /// can react via `window.onVisibility` (driven through `VisibilityRelay`). `nil` to skip.
    var onVisibilityRatio: ((CGFloat) -> Void)?
    /// Fires once when the dwell threshold is met, carrying the exposure aggregate accrued up to it.
    let onImpression: (ViewabilityStats) -> Void

    @State private var fired = false
    @State private var dwellTask: Task<Void, Never>?
    // Time-integrated exposure for the once-per-impression `viewability` telemetry. A reference type in
    // @State so it persists across re-renders and mutates in place; accessed only on the main actor.
    @State private var accumulator = ViewabilityAccumulator()

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { handle(visibleFraction(geo)) }
                        .onChange(of: visibleFraction(geo)) { frac in handle(frac) }
                }
            )
            .onDisappear {
                dwellTask?.cancel()
                dwellTask = nil
                // Slot left the screen → tell the creative it's no longer visible (pause video, etc.).
                onVisibilityRatio?(0)
            }
    }

    /// Per-frame entry: forward the live fraction to the creative (always), then feed the dwell +
    /// exposure accumulator while still measuring.
    private func handle(_ fraction: CGFloat) {
        onVisibilityRatio?(fraction)
        guard enabled, !fired else { return }
        accumulator.sample(fraction, now: ProcessInfo.processInfo.systemUptime)
        evaluate(fraction)
    }

    private func evaluate(_ fraction: CGFloat) {
        if fraction >= thresholdFraction {
            // Already counting down? Don't restart — a sustained view must keep its timer running.
            guard dwellTask == nil else { return }
            dwellTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(minVisibleSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                fired = true
                dwellTask = nil
                onImpression(accumulator.finish(now: ProcessInfo.processInfo.systemUptime))
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

/// Once-per-impression viewability exposure aggregate, measured over the run that led to the
/// impression. `timeToViewableMs` is from when measurement began (first sample) to the impression
/// fire; `peakExposure` / `avgExposure` are 0..1; `totalVisibleMs` is the cumulative time any part of
/// the slot was on screen. The per-frame stream is far too high-volume for the batch telemetry
/// pipeline, so this MRC-shaped summary is what's recorded instead. Mirrors the Kotlin `ViewabilityStats`.
struct ViewabilityStats {
    let timeToViewableMs: Int
    let peakExposure: CGFloat
    let avgExposure: CGFloat
    let totalVisibleMs: Int
}

/// Integrates visible-fraction samples over wall-clock time (piecewise-constant between samples) so
/// `avgExposure` / `totalVisibleMs` are time-weighted rather than biased by how often SwiftUI happens
/// to re-evaluate during a scroll. Accessed only on the main actor (the SwiftUI modifier's callbacks).
final class ViewabilityAccumulator {
    private var startUptime: TimeInterval?
    private var lastUptime: TimeInterval = 0
    private var lastFraction: CGFloat = 0
    private var peak: CGFloat = 0
    private var weighted: Double = 0   // ∫ fraction dt (seconds)
    private var elapsed: Double = 0    // ∫ dt (seconds)
    private var visible: Double = 0    // ∫ [fraction > 0] dt (seconds)

    /// Fold the segment since the previous sample, then record the new fraction.
    func sample(_ fraction: CGFloat, now: TimeInterval) {
        if startUptime == nil {
            startUptime = now
        } else {
            let dt = max(0, now - lastUptime)
            weighted += Double(lastFraction) * dt
            elapsed += dt
            if lastFraction > 0 { visible += dt }
        }
        lastUptime = now
        lastFraction = fraction
        if fraction > peak { peak = fraction }
    }

    /// Close the final open segment up to `now` (the fire instant) and emit the aggregate.
    func finish(now: TimeInterval) -> ViewabilityStats {
        guard let start = startUptime else {
            return ViewabilityStats(timeToViewableMs: 0, peakExposure: peak, avgExposure: 0, totalVisibleMs: 0)
        }
        let dt = max(0, now - lastUptime)
        weighted += Double(lastFraction) * dt
        elapsed += dt
        if lastFraction > 0 { visible += dt }
        let avg = elapsed > 0 ? weighted / elapsed : Double(lastFraction)
        return ViewabilityStats(
            timeToViewableMs: Int((now - start) * 1000),
            peakExposure: peak,
            avgExposure: CGFloat(avg),
            totalVisibleMs: Int(visible * 1000)
        )
    }
}

extension View {
    /// Fire `onImpression` once when this view is ≥50% visible for ≥1 continuous second (OMID-shaped),
    /// and forward the live visible fraction to `onVisibilityRatio` on every frame.
    func trackNativeAdViewability(
        enabled: Bool,
        onVisibilityRatio: ((CGFloat) -> Void)? = nil,
        onImpression: @escaping (ViewabilityStats) -> Void
    ) -> some View {
        modifier(NativeAdViewabilityModifier(
            enabled: enabled,
            onVisibilityRatio: onVisibilityRatio,
            onImpression: onImpression
        ))
    }
}
#endif
