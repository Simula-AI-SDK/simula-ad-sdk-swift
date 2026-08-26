#if os(iOS)
import Foundation

/// Tracks the store-exit funnel for a single full-screen ad presentation: which click type sent the
/// user to the store, how long they were away, and whether they came back. Emits `store_opened`,
/// `store_returned`, and `store_abandoned` `ad_lifecycle` telemetry (PRD "Better Telemetry Tracking").
///
/// `@MainActor` — driven entirely by the presenter's lifecycle/sheet observers and tap handlers, all
/// on the main thread. Timing uses the monotonic `ProcessInfo.systemUptime` (counts time spent in an
/// in-app sheet; on iOS it pauses while the app is fully suspended, which is acceptable for a
/// best-effort dwell metric). Every emit is best-effort (`recordLifecycle` never throws into the host).
///
/// Two kinds of "away" funnel through the same pair of hooks: the app backgrounding (an `.external`
/// store/browser open) and an in-app sheet covering the ad (`SKStoreProductViewController` /
/// `SFSafariViewController`). The presenter calls ``onAway()`` / ``onReturn()`` for both.
@MainActor
final class StoreExitTracker {
    private let adId: String?
    private let adFormat: String?
    private let adUnitId: String?
    private var serveId: String? { adFormat == "interstitial" ? adId : nil }

    private var foregroundMs: Double = 0
    private var resumedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var inForeground = true

    private var pendingTrigger: String?
    private var openedAt: TimeInterval = 0

    init(adId: String?, adFormat: String?, adUnitId: String? = nil) {
        self.adId = adId
        self.adFormat = adFormat
        self.adUnitId = adUnitId
    }

    /// A CTA / store-prompt / auto-redirect opened the store. `trigger` is one of
    /// `cta` / `store_prompt` / `auto_redirect`. `durationMs` carries the foreground dwell at open.
    func recordStoreOpen(_ trigger: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let dwellMs = foregroundMs + (inForeground ? max(0, now - resumedAt) * 1000 : 0)
        openedAt = now
        pendingTrigger = trigger
        Telemetry.shared.recordLifecycle(
            stage: "store_opened", adFormat: adFormat, adUnitId: adUnitId, adId: adId,
            serveId: serveId, durationMs: Int(dwellMs), errorCode: nil, trigger: trigger
        )
    }

    /// App backgrounded, or an in-app sheet covered the ad — bank the foreground time accrued so far.
    func onAway() {
        guard inForeground else { return }
        foregroundMs += max(0, ProcessInfo.processInfo.systemUptime - resumedAt) * 1000
        inForeground = false
    }

    /// App foregrounded, or the in-app sheet dismissed — resume accrual and, if a store visit is
    /// outstanding, record the return.
    func onReturn() {
        let now = ProcessInfo.processInfo.systemUptime
        if !inForeground {
            resumedAt = now
            inForeground = true
        }
        guard let trigger = pendingTrigger else { return }
        pendingTrigger = nil
        Telemetry.shared.recordLifecycle(
            stage: "store_returned", adFormat: adFormat, adUnitId: adUnitId, adId: adId,
            serveId: serveId, durationMs: Int(max(0, now - openedAt) * 1000), errorCode: nil, trigger: trigger
        )
    }

    /// The ad closed / tore down. If a store visit never resolved with a return, it's an abandon.
    func onAdClosed() {
        guard let trigger = pendingTrigger else { return }
        pendingTrigger = nil
        Telemetry.shared.recordLifecycle(
            stage: "store_abandoned", adFormat: adFormat, adUnitId: adUnitId, adId: adId,
            serveId: serveId, durationMs: nil, errorCode: nil, trigger: trigger
        )
    }
}
#endif
