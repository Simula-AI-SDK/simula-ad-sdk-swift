import Darwin
import Foundation
#if os(iOS)
import UIKit
#endif

enum StoreDwellRoute: Equatable, Sendable {
    case storeProductSheet
    case externalAppStore
}

enum StoreDwellEndEvent: String, Equatable, Sendable {
    case sheetDismissed = "sheet_dismissed"
    case appForeground = "app_foreground"
    case adClosed = "ad_closed"
}

struct StoreDwellLifecycleEvent: Equatable, Sendable {
    let stage: String
    let durationMs: Int?
    let trigger: String
    let endEvent: StoreDwellEndEvent?
    let opens: Int
}

private enum StoreDwellBlocker: Hashable {
    case appAway
    case sheet
}

private struct StoreDwellVisit {
    let trigger: String
    let openedAtMs: Double
    let opens: Int
}

private enum StoreDwellPending {
    case externalLaunch(trigger: String, generation: Int)
    case externalAway(StoreDwellVisit)
    case sheet(StoreDwellVisit)
}

final class StoreDwellScheduledAction {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let cancellation = cancellation
        self.cancellation = nil
        cancellation?()
    }
}

/// `mach_continuous_time` is monotonic and, unlike process uptime, includes time spent suspended.
private enum StoreDwellContinuousClock {
    private static let millisecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 0.000_001 }
        return Double(info.numer) / Double(info.denom) / 1_000_000
    }()

    static func nowMilliseconds() -> Double {
        Double(mach_continuous_time()) * millisecondsPerTick
    }
}

/// Presentation-owned, main-thread store dwell tracker. It distinguishes app-away and owned-sheet
/// reasons so unrelated lifecycle signals cannot resolve a visit. External App Store handoffs are
/// provisional until an app-away signal arrives within the bounded settle window.
@MainActor
final class StoreExitTracker {
    let presentationID = UUID()
    static let externalLaunchSettleSeconds: TimeInterval = 2
    private static let maxOpens = 1_000

    typealias Clock = () -> Double
    typealias Recorder = (StoreDwellLifecycleEvent) -> Void
    typealias ErrorRecorder = () -> Void
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> StoreDwellScheduledAction

    private let now: Clock
    private let recorder: Recorder
    private let recordLaunchWithoutAway: ErrorRecorder
    private let schedule: Scheduler

    private var blockers: Set<StoreDwellBlocker> = []
    private var foregroundMs: Double = 0
    private var activeSinceMs: Double
    private var appAwayAtMs: Double?
    private var sheetPresentedAtMs: Double?
    private var pending: StoreDwellPending?
    private var launchTimer: StoreDwellScheduledAction?
    private var launchGeneration = 0
    private var openCount = 0
    private var closed = false
    private var sheetOwner: StoreProductOwnershipToken?
    private let notificationCenter: NotificationCenter
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        adId: String?,
        adFormat: String?,
        adUnitId: String? = nil,
        now: @escaping Clock = StoreDwellContinuousClock.nowMilliseconds,
        recorder: Recorder? = nil,
        recordLaunchWithoutAway: ErrorRecorder? = nil,
        schedule: Scheduler? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.notificationCenter = notificationCenter
        self.now = now
        self.activeSinceMs = now()
        self.recorder = recorder ?? { event in
            Telemetry.shared.recordLifecycle(
                stage: event.stage,
                adFormat: adFormat,
                adUnitId: adUnitId,
                adId: adId,
                serveId: (adFormat == "interstitial" || adFormat == "rewarded") ? adId : nil,
                durationMs: event.durationMs,
                errorCode: nil,
                trigger: event.trigger,
                endEvent: event.endEvent?.rawValue,
                opens: event.opens
            )
        }
        self.recordLaunchWithoutAway = recordLaunchWithoutAway ?? {
            Telemetry.shared.recordError(
                signature: "store:launch_no_pause",
                breadcrumb: "surface=fullscreen"
            )
        }
        self.schedule = schedule ?? { delay, action in
            let item = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return StoreDwellScheduledAction { item.cancel() }
        }
        #if os(iOS)
        observeLifecycle()
        #endif
    }

    deinit {
        for observer in lifecycleObservers { notificationCenter.removeObserver(observer) }
        launchTimer?.cancel()
    }

    #if os(iOS)
    private func observeLifecycle() {
        observe(UIApplication.willResignActiveNotification) { tracker, _ in tracker.onAppAway() }
        observe(UIApplication.didBecomeActiveNotification) { tracker, _ in tracker.onAppForeground() }
        observe(.simulaAdExternalSheetWillPresent) { tracker, owner in
            guard let owner, owner.storeDwellPresentationID == tracker.presentationID else { return }
            tracker.onSheetPresented(owner: owner)
        }
        observe(.simulaAdExternalSheetDidDismiss) { tracker, owner in
            guard let owner, owner.storeDwellPresentationID == tracker.presentationID else { return }
            tracker.onSheetDismissed(owner: owner)
        }
    }

    /// Four observers per presentation, never per screen/visit. No synchronous hop from a posting
    /// background thread, no polling, and no strong capture of the presentation or host controller.
    private func observe(
        _ name: Notification.Name,
        action: @escaping @MainActor (StoreExitTracker, StoreProductOwnershipToken?) -> Void
    ) {
        lifecycleObservers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
            let owner = notification.object as? StoreProductOwnershipToken
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    action(self, owner)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    action(self, owner)
                }
            }
        })
    }
    #endif

    func recordStoreOpen(_ trigger: String, route: StoreDwellRoute) {
        guard !closed, pending == nil else { return }
        let timestamp = now()
        switch route {
        case .storeProductSheet:
            let visit = makeVisit(trigger: trigger, openedAtMs: sheetPresentedAtMs ?? timestamp)
            pending = .sheet(visit)
            recordOpened(visit)
        case .externalAppStore:
            launchGeneration += 1
            let generation = launchGeneration
            pending = .externalLaunch(trigger: trigger, generation: generation)
            if let appAwayAtMs {
                qualifyExternalVisit(trigger: trigger, openedAtMs: appAwayAtMs)
            } else {
                launchTimer?.cancel()
                launchTimer = schedule(Self.externalLaunchSettleSeconds) { [weak self] in
                    self?.externalLaunchTimedOut(generation: generation)
                }
            }
        }
    }

    func onAppAway() {
        guard !closed else { return }
        let timestamp = now()
        appAwayAtMs = timestamp
        addBlocker(.appAway, at: timestamp)
        guard case .externalLaunch(let trigger, _) = pending else { return }
        qualifyExternalVisit(trigger: trigger, openedAtMs: timestamp)
    }

    func onAppForeground() {
        guard !closed else { return }
        let timestamp = now()
        appAwayAtMs = nil
        removeBlocker(.appAway, at: timestamp)
        guard case .externalAway(let visit) = pending else { return }
        resolve(visit, endEvent: .appForeground, at: timestamp)
    }

    func onSheetPresented(owner: StoreProductOwnershipToken? = nil) {
        guard !closed, sheetPresentedAtMs == nil else { return }
        sheetOwner = owner
        let timestamp = now()
        sheetPresentedAtMs = timestamp
        addBlocker(.sheet, at: timestamp)
    }

    func onSheetDismissed(owner: StoreProductOwnershipToken? = nil) {
        guard !closed, sheetOwner === owner else { return }
        sheetOwner = nil
        let timestamp = now()
        sheetPresentedAtMs = nil
        removeBlocker(.sheet, at: timestamp)
        guard case .sheet(let visit) = pending else { return }
        resolve(visit, endEvent: .sheetDismissed, at: timestamp)
    }

    func onAdClosed() {
        guard !closed else { return }
        closed = true
        for observer in lifecycleObservers { notificationCenter.removeObserver(observer) }
        lifecycleObservers.removeAll()
        sheetOwner = nil
        launchTimer?.cancel()
        launchTimer = nil
        switch pending {
        case .externalLaunch:
            // Intentional teardown cancels a provisional launch; only the settle timeout is an error.
            pending = nil
        case .externalAway(let visit), .sheet(let visit):
            pending = nil
            recorder(StoreDwellLifecycleEvent(
                stage: "store_abandoned",
                durationMs: nil,
                trigger: visit.trigger,
                endEvent: .adClosed,
                opens: visit.opens
            ))
        case nil:
            break
        }
    }

    private func makeVisit(trigger: String, openedAtMs: Double) -> StoreDwellVisit {
        openCount = min(Self.maxOpens, openCount + 1)
        return StoreDwellVisit(trigger: trigger, openedAtMs: openedAtMs, opens: openCount)
    }

    private func qualifyExternalVisit(trigger: String, openedAtMs: Double) {
        launchTimer?.cancel()
        launchTimer = nil
        let visit = makeVisit(trigger: trigger, openedAtMs: openedAtMs)
        pending = .externalAway(visit)
        recordOpened(visit)
    }

    private func recordOpened(_ visit: StoreDwellVisit) {
        let activeMs = blockers.isEmpty ? max(0, now() - activeSinceMs) : 0
        recorder(StoreDwellLifecycleEvent(
            stage: "store_opened",
            durationMs: Int(max(0, foregroundMs + activeMs)),
            trigger: visit.trigger,
            endEvent: nil,
            opens: visit.opens
        ))
    }

    private func resolve(_ visit: StoreDwellVisit, endEvent: StoreDwellEndEvent, at timestamp: Double) {
        pending = nil
        recorder(StoreDwellLifecycleEvent(
            stage: "store_returned",
            durationMs: Int(max(0, timestamp - visit.openedAtMs)),
            trigger: visit.trigger,
            endEvent: endEvent,
            opens: visit.opens
        ))
    }

    private func addBlocker(_ blocker: StoreDwellBlocker, at timestamp: Double) {
        guard blockers.insert(blocker).inserted else { return }
        if blockers.count == 1 {
            foregroundMs += max(0, timestamp - activeSinceMs)
        }
    }

    private func removeBlocker(_ blocker: StoreDwellBlocker, at timestamp: Double) {
        guard blockers.remove(blocker) != nil else { return }
        if blockers.isEmpty { activeSinceMs = timestamp }
    }

    private func externalLaunchTimedOut(generation: Int) {
        guard case .externalLaunch(_, let pendingGeneration) = pending,
              generation == pendingGeneration else { return }
        launchTimer = nil
        pending = nil
        recordLaunchWithoutAway()
    }
}
