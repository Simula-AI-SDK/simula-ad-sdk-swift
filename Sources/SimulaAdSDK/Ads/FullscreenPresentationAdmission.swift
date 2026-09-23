import Foundation

func fullscreenPresentationBlocked(
    appForegrounded: Bool,
    storeSheetPresented: Bool
) -> Bool {
    !appForegrounded || storeSheetPresented
}

struct FullscreenVisualAdmissionState: Equatable, Sendable {
    enum DisplayOutcome: Equatable, Sendable {
        case pending
        case displayed
        case failed
    }

    private(set) var displayAdmitted = false
    private(set) var displayOutcome = DisplayOutcome.pending
    private(set) var impressionCommitted = false
    private(set) var visualActive = false
    private(set) var blocked = false
    private(set) var accruedImpressionMs: Double = 0
    private(set) var terminalOutcome: FullscreenPresentationTerminalOutcome?
    private(set) var htmlBillingConfirmation = HTMLBillingConfirmation.notRequired

    enum HTMLBillingConfirmation: Equatable, Sendable {
        case notRequired
        case pending
        case confirmed
        case suppressed
    }

    var impressionDwellEligible: Bool {
        displayAdmitted && visualActive && !blocked && !impressionCommitted
            && terminalOutcome == nil && htmlBillingConfirmation != .suppressed
    }

    var impressionEligible: Bool {
        impressionDwellEligible && htmlBillingConfirmation != .pending
    }

    mutating func visualBecameReady() -> Bool {
        guard displayOutcome != .failed, terminalOutcome == nil else { return false }
        visualActive = true
        guard displayOutcome == .pending else { return false }
        displayAdmitted = true
        displayOutcome = .displayed
        return true
    }

    mutating func visualBecameUnavailable() {
        visualActive = false
    }

    mutating func htmlPresentationDidSucceed() -> Bool {
        if htmlBillingConfirmation == .notRequired {
            htmlBillingConfirmation = .pending
        }
        return visualBecameReady()
    }

    mutating func htmlNavigationDidCommit(thresholdMs: Double) -> Bool {
        guard htmlBillingConfirmation != .suppressed else { return false }
        htmlBillingConfirmation = .confirmed
        return commitImpressionIfEligible(thresholdMs: thresholdMs)
    }

    mutating func htmlNavigationDidFail() {
        guard !impressionCommitted else { return }
        htmlBillingConfirmation = .suppressed
    }

    mutating func setBlocked(_ blocked: Bool) {
        self.blocked = blocked
    }

    mutating func accrueImpression(deltaMs: Double, thresholdMs: Double) -> Bool {
        guard impressionDwellEligible, deltaMs.isFinite, deltaMs > 0 else { return false }
        accruedImpressionMs += deltaMs
        return commitImpressionIfEligible(thresholdMs: thresholdMs)
    }

    mutating func commitImpressionIfEligible(thresholdMs: Double) -> Bool {
        guard impressionEligible, accruedImpressionMs >= thresholdMs else { return false }
        impressionCommitted = true
        return true
    }

    mutating func failDisplayIfNeverAdmitted() -> Bool {
        guard displayOutcome == .pending else { return false }
        displayOutcome = .failed
        visualActive = false
        return true
    }

    mutating func finish() -> FullscreenPresentationTerminalOutcome? {
        guard terminalOutcome == nil else { return nil }
        let outcome: FullscreenPresentationTerminalOutcome = failDisplayIfNeverAdmitted()
            ? .displayFailed
            : .closed
        terminalOutcome = outcome
        return outcome
    }
}

struct FullscreenImpressionDwellClock: Equatable, Sendable {
    private(set) var anchor: TimeInterval?

    mutating func resume(at now: TimeInterval) {
        guard anchor == nil, now.isFinite else { return }
        anchor = now
    }

    mutating func settle(at now: TimeInterval) -> Double {
        guard let anchor, now.isFinite else { return 0 }
        self.anchor = now
        return max(0, now - anchor) * 1_000
    }

    mutating func pause() {
        anchor = nil
    }
}

enum FullscreenPresentationTerminalOutcome: Equatable, Sendable {
    case displayFailed
    case closed
}

enum LegacyHTMLBillingCallback: Equatable, Sendable {
    case mainFrameCommitted
    case navigationFailed
    case webContentProcessTerminated
}

enum LegacyHTMLBillingCallbackAction: Equatable, Sendable {
    case confirm
    case suppressUncommitted
    case telemetryOnly
}

func legacyHTMLBillingCallbackAction(
    for callback: LegacyHTMLBillingCallback
) -> LegacyHTMLBillingCallbackAction {
    switch callback {
    case .mainFrameCommitted: return .confirm
    case .navigationFailed: return .suppressUncommitted
    case .webContentProcessTerminated: return .telemetryOnly
    }
}

struct FullscreenPostPrimaryPolicy: Equatable, Sendable {
    let presentsFallbacks: Bool
    let notifiesPublisherClose: Bool
    let verifiesEarnedReward: Bool

    init(terminalOutcome: FullscreenPresentationTerminalOutcome, earnedReward: Bool = false) {
        presentsFallbacks = terminalOutcome == .closed
        notifiesPublisherClose = terminalOutcome == .closed
        verifiesEarnedReward = terminalOutcome == .closed && earnedReward
    }
}

struct DeferredTerminalState<Outcome: Equatable & Sendable>: Equatable, Sendable {
    private(set) var pending: Outcome?
    private(set) var isTerminal = false

    mutating func request(_ outcome: Outcome, blocked: Bool) -> Outcome? {
        guard !isTerminal else { return nil }
        if blocked {
            pending = outcome
            return nil
        }
        pending = nil
        isTerminal = true
        return outcome
    }

    mutating func blockersDidChange(blocked: Bool) -> Outcome? {
        guard !blocked, let outcome = pending, !isTerminal else { return nil }
        pending = nil
        isTerminal = true
        return outcome
    }
}

struct RewardedTerminalOutcome: Equatable, Sendable {
    let earned: Bool
    let elapsedPlayTime: TimeInterval
    let completionReason: RewardCompletionReason?

    init(
        earned: Bool,
        elapsedPlayTime: TimeInterval,
        completionReason: RewardCompletionReason? = nil
    ) {
        self.earned = earned
        self.elapsedPlayTime = elapsedPlayTime
        self.completionReason = earned ? completionReason : nil
    }
}

struct RewardCompletionState: Equatable, Sendable {
    private(set) var earned = false
    private(set) var reason: RewardCompletionReason?

    @discardableResult
    mutating func earn(reason: RewardCompletionReason) -> Bool {
        guard !earned else { return false }
        earned = true
        self.reason = reason
        return true
    }
}

struct UnitEndRewardState: Equatable, Sendable {
    enum FallbackAuthority: Equatable, Sendable {
        case unknown
        case none
        case renderableScreens
        case unavailable
    }

    private(set) var earned = false
    private(set) var primaryGateOpened = false
    private(set) var fallbackAuthority = FallbackAuthority.unknown
    private(set) var lastFallbackGateOpened = false

    mutating func primaryGateDidOpen() -> Bool {
        primaryGateOpened = true
        return claimIfAuthorized()
    }

    mutating func fallbackDidResolve(renderableScreenCount: Int) -> Bool {
        fallbackAuthority = renderableScreenCount > 0 ? .renderableScreens : .none
        return claimIfAuthorized()
    }

    mutating func fallbackBecameUnavailable() -> Bool {
        fallbackAuthority = .unavailable
        return claimLastRenderableAuthority()
    }

    mutating func fallbackGateDidOpen(isFinal: Bool) -> Bool {
        guard fallbackAuthority == .renderableScreens else { return false }
        lastFallbackGateOpened = true
        return isFinal ? claim() : false
    }

    mutating func fallbackDeliveryDidFinish() -> Bool {
        claimLastRenderableAuthority()
    }

    private mutating func claimIfAuthorized() -> Bool {
        guard primaryGateOpened,
              fallbackAuthority == .none || fallbackAuthority == .unavailable else { return false }
        return claim()
    }

    private mutating func claimLastRenderableAuthority() -> Bool {
        guard lastFallbackGateOpened || primaryGateOpened else { return false }
        return claim()
    }

    private mutating func claim() -> Bool {
        guard !earned else { return false }
        earned = true
        return true
    }
}

@MainActor
final class UnitEndRewardClaim {
    private var state = UnitEndRewardState()
    private var consumed = false

    var earned: Bool { state.earned }

    func primaryGateDidOpen() {
        _ = state.primaryGateDidOpen()
    }

    func fallbackDidResolve(renderableScreenCount: Int) {
        _ = state.fallbackDidResolve(renderableScreenCount: renderableScreenCount)
    }

    func fallbackBecameUnavailable() {
        _ = state.fallbackBecameUnavailable()
    }

    func fallbackGateDidOpen(isFinal: Bool) {
        _ = state.fallbackGateDidOpen(isFinal: isFinal)
    }

    func fallbackDeliveryDidFinish() {
        _ = state.fallbackDeliveryDidFinish()
    }

    @discardableResult
    func consumeAtUnitClose(
        onEarn: () -> Void,
        enqueueVerification: () -> Void
    ) -> Bool {
        guard state.earned, !consumed else { return false }
        consumed = true
        onEarn()
        enqueueVerification()
        return true
    }
}

struct RewardedEarlyCompletionState: Equatable, Sendable {
    private(set) var pending = false
    private(set) var consumed = false

    mutating func receive(
        signaled: Bool,
        requiresCreativeReadiness: Bool = true,
        primaryCreativeReady: Bool,
        rewardEarned: Bool
    ) -> Bool {
        guard signaled, !consumed else { return false }
        guard !rewardEarned else {
            consumed = true
            pending = false
            return false
        }
        pending = true
        return consumeIfReady(
            primaryCreativeReady: primaryCreativeReady || !requiresCreativeReadiness
        )
    }

    mutating func primaryCreativeBecameReady(rewardEarned: Bool) -> Bool {
        guard !consumed else { return false }
        guard !rewardEarned else {
            consumed = true
            pending = false
            return false
        }
        return consumeIfReady(primaryCreativeReady: true)
    }

    mutating func cancel() {
        pending = false
        consumed = true
    }

    private mutating func consumeIfReady(primaryCreativeReady: Bool) -> Bool {
        guard pending, primaryCreativeReady else { return false }
        pending = false
        consumed = true
        return true
    }
}

enum RewardedHTMLTerminalFailureAction: Equatable, Sendable {
    case none
    case preserveFailOpen
    case terminate(earned: Bool)
}

/// Presentation-local policy: a visual commit retains legacy fail-open behavior; only a terminal
/// precommit failure permanently disables the reward gate and requests teardown.
struct RewardedHTMLTerminalFailureState: Equatable, Sendable {
    private(set) var visualCommitted = false
    private(set) var gatePermanentlyIneligible = false
    private(set) var terminalTeardownRequested = false

    @discardableResult
    mutating func visualDidCommit() -> Bool {
        guard !terminalTeardownRequested else { return false }
        visualCommitted = true
        return true
    }

    mutating func terminalFailure(
        rewardAlreadyEarned: Bool
    ) -> RewardedHTMLTerminalFailureAction {
        if visualCommitted { return .preserveFailOpen }
        guard !terminalTeardownRequested else { return .none }
        gatePermanentlyIneligible = true
        terminalTeardownRequested = true
        return .terminate(earned: rewardAlreadyEarned)
    }
}

let rewardedHTMLReadinessSafetySeconds: TimeInterval = 10

enum RewardedHTMLReadinessDeadlineAction: Equatable, Sendable {
    case none
    case schedule(TimeInterval)
    case cancel
    case fail
}

struct RewardedHTMLReadinessDeadlineState: Sendable {
    let budget: TimeInterval
    private var clock = FullscreenGateClock()
    private(set) var scheduled = false
    private(set) var completed = false

    init(configuredCloseDelay: TimeInterval) {
        let closeDelay = configuredCloseDelay.isFinite ? max(0, configuredCloseDelay) : 0
        budget = max(rewardedHTMLReadinessSafetySeconds, closeDelay)
    }

    var elapsed: TimeInterval { clock.elapsed }

    mutating func reconcile(now: TimeInterval, eligible: Bool) -> RewardedHTMLReadinessDeadlineAction {
        guard !completed else { return .none }
        if eligible {
            clock.resume(at: now)
            let remaining = clock.remaining(total: budget)
            guard remaining > 0 else {
                scheduled = false
                completed = true
                return .fail
            }
            guard !scheduled else { return .none }
            scheduled = true
            return .schedule(remaining)
        }

        clock.pause(at: now, total: budget)
        guard scheduled else { return .none }
        scheduled = false
        return .cancel
    }

    mutating func complete(now: TimeInterval) -> RewardedHTMLReadinessDeadlineAction {
        guard !completed else { return .none }
        clock.pause(at: now, total: budget)
        completed = true
        guard scheduled else { return .none }
        scheduled = false
        return .cancel
    }

    mutating func deadlineFired(now: TimeInterval) -> RewardedHTMLReadinessDeadlineAction {
        guard scheduled, !completed else { return .none }
        scheduled = false
        clock.pause(at: now, total: budget)
        guard clock.remaining(total: budget) <= 0 else {
            return reconcile(now: now, eligible: true)
        }
        completed = true
        return .fail
    }
}

func shouldRunRewardedHTMLGate(
    appForegrounded: Bool,
    storeSheetPresented: Bool,
    rewardEarned: Bool,
    gatePermanentlyIneligible: Bool
) -> Bool {
    appForegrounded && !storeSheetPresented && !rewardEarned && !gatePermanentlyIneligible
}

func rewardedHTMLGateCompletionReason(
    actualElapsedPlayTime: TimeInterval,
    gateDuration: TimeInterval
) -> RewardCompletionReason? {
    guard actualElapsedPlayTime.isFinite, gateDuration.isFinite,
          actualElapsedPlayTime >= max(0, gateDuration) else { return nil }
    return .durationElapsed
}

func rewardedTerminalOutcome(
    earned: Bool,
    actualElapsedPlayTime: TimeInterval,
    completionReason: RewardCompletionReason? = nil
) -> RewardedTerminalOutcome {
    let elapsed = actualElapsedPlayTime.isFinite ? max(0, actualElapsedPlayTime) : 0
    return RewardedTerminalOutcome(
        earned: earned,
        elapsedPlayTime: elapsed,
        completionReason: completionReason
    )
}

func rewardVerificationElapsedPlayTime(
    earned: Bool,
    actualElapsedPlayTime: TimeInterval
) -> TimeInterval? {
    guard earned, actualElapsedPlayTime.isFinite else { return nil }
    return max(0, actualElapsedPlayTime)
}

struct FullscreenVisualSurfaceToken: Hashable, Sendable {
    fileprivate let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

final class WeakFullscreenPresentationOwner<Owner: AnyObject> {
    weak var value: Owner?

    init(_ value: Owner) {
        self.value = value
    }
}

struct FullscreenPresentationAccountingSnapshot {
    let adFormat: String
    let adUnitId: String
    let adId: String
    let serveId: String?
    let adValue: AdValue
    let metadata: [String: String]?
    let showStartNanos: UInt64

    var showDurationMs: Int? {
        guard showStartNanos != 0 else { return nil }
        return Int((DispatchTime.now().uptimeNanoseconds &- showStartNanos) / 1_000_000)
    }
}

struct FullscreenPresentationAccountingSink {
    let recordDisplayed: (FullscreenPresentationAccountingSnapshot) -> Void
    let recordImpression: (FullscreenPresentationAccountingSnapshot) -> Void
    let enqueueShown: (FullscreenPresentationAccountingSnapshot) -> Void
    let enqueueSeen: (FullscreenPresentationAccountingSnapshot) -> Void

    static let live = FullscreenPresentationAccountingSink(
        recordDisplayed: { snapshot in
            Telemetry.shared.recordLifecycle(
                stage: "displayed",
                adFormat: snapshot.adFormat,
                adUnitId: snapshot.adUnitId,
                adId: snapshot.adId,
                serveId: snapshot.serveId,
                durationMs: snapshot.showDurationMs,
                errorCode: nil
            )
        },
        recordImpression: { snapshot in
            Telemetry.shared.recordLifecycle(
                stage: "impression",
                adFormat: snapshot.adFormat,
                adUnitId: snapshot.adUnitId,
                adId: snapshot.adId,
                serveId: snapshot.serveId
            )
            Telemetry.shared.recordLifecycle(
                stage: "paid",
                adFormat: snapshot.adFormat,
                adUnitId: snapshot.adUnitId,
                adId: snapshot.adId,
                serveId: snapshot.serveId
            )
        },
        enqueueShown: { snapshot in
            AdBeaconManager.shared.enqueue(
                impressionId: snapshot.adId,
                action: "shown",
                adFormat: snapshot.adFormat,
                adUnitId: snapshot.adUnitId
            )
        },
        enqueueSeen: { snapshot in
            AdBeaconManager.shared.enqueue(
                impressionId: snapshot.adId,
                action: "seen",
                adFormat: snapshot.adFormat,
                adUnitId: snapshot.adUnitId,
                metadata: snapshot.metadata
            )
        }
    )
}

struct FullscreenPresentationAccountingCallbacks {
    let onDisplayed: () -> Void
    let onDisplayFailed: () -> Void
    let onImpression: () -> Void
}

func fullscreenPresentationAccountingCallbacks<Owner: AnyObject>(
    owner: WeakFullscreenPresentationOwner<Owner>,
    snapshot: FullscreenPresentationAccountingSnapshot,
    sink: FullscreenPresentationAccountingSink = .live,
    onCommittedImpression: @escaping () -> Void = {},
    notifyDisplayed: @escaping (Owner) -> Void,
    notifyDisplayFailed: @escaping (Owner) -> Void,
    notifyImpression: @escaping (Owner, AdValue) -> Void
) -> FullscreenPresentationAccountingCallbacks {
    FullscreenPresentationAccountingCallbacks(
        onDisplayed: {
            sink.recordDisplayed(snapshot)
            if let owner = owner.value { notifyDisplayed(owner) }
            sink.enqueueShown(snapshot)
        },
        onDisplayFailed: {
            if let owner = owner.value { notifyDisplayFailed(owner) }
        },
        onImpression: {
            onCommittedImpression()
            sink.recordImpression(snapshot)
            if let owner = owner.value { notifyImpression(owner, snapshot.adValue) }
            sink.enqueueSeen(snapshot)
        }
    )
}

#if os(iOS)
import UIKit

@MainActor
final class FullscreenPresentationAdmission {
    private var state = FullscreenVisualAdmissionState()
    private var dwellClock = FullscreenImpressionDwellClock()
    private var impressionTask: Task<Void, Never>?
    private var impressionGeneration: UInt64 = 0
    private var activeSurface: FullscreenVisualSurfaceToken?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var applicationActive: Bool
    private var surfaceBlocked = false
    private let onDisplayed: () -> Void
    private let onDisplayFailed: () -> Void
    private let onImpression: () -> Void
    private let impressionDelayMs: Double
    private let tickNanos: UInt64
    private let uptime: () -> TimeInterval

    init(
        onDisplayed: @escaping () -> Void,
        onDisplayFailed: @escaping () -> Void = {},
        onImpression: @escaping () -> Void,
        impressionDelayMs: Double = fullscreenImpressionDelayMs,
        tickNanos: UInt64 = impressionTickNanos,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        initialApplicationActive: Bool? = nil
    ) {
        applicationActive = initialApplicationActive ?? (UIApplication.shared.applicationState == .active)
        self.onDisplayed = onDisplayed
        self.onDisplayFailed = onDisplayFailed
        self.onImpression = onImpression
        self.impressionDelayMs = impressionDelayMs
        self.tickNanos = tickNanos
        self.uptime = uptime
        state.setBlocked(!applicationActive)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setApplicationActive(false) }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setApplicationActive(true) }
        })
    }

    deinit {
        impressionTask?.cancel()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var hasAdmittedDisplay: Bool { state.displayAdmitted }
    var visualIsActive: Bool { state.visualActive }

    func visualBecameReady(owner: FullscreenVisualSurfaceToken) {
        let now = uptime()
        settleEligibleImpressionDwell(at: now)
        let shouldNotifyDisplayed = state.visualBecameReady()
        guard state.visualActive else { return }
        activeSurface = owner
        if shouldNotifyDisplayed { onDisplayed() }
        reconcileImpressionTimer(at: now)
    }

    func presentationDidSucceed() {
        let now = uptime()
        settleEligibleImpressionDwell(at: now)
        let shouldNotifyDisplayed = state.htmlPresentationDidSucceed()
        guard state.visualActive else { return }
        if shouldNotifyDisplayed { onDisplayed() }
        reconcileImpressionTimer(at: now)
    }

    func htmlNavigationDidCommit() {
        let now = uptime()
        settleEligibleImpressionDwell(at: now)
        if state.htmlNavigationDidCommit(thresholdMs: impressionDelayMs) { onImpression() }
        reconcileImpressionTimer(at: now)
    }

    func htmlNavigationDidFail() {
        let now = uptime()
        settleEligibleImpressionDwell(at: now)
        state.htmlNavigationDidFail()
        reconcileImpressionTimer(at: now)
    }

    func visualBecameUnavailable(owner: FullscreenVisualSurfaceToken) {
        guard activeSurface == owner else { return }
        let now = uptime()
        settleEligibleImpressionDwell(at: now)
        activeSurface = nil
        state.visualBecameUnavailable()
        reconcileImpressionTimer(at: now)
    }

    func setBlocked(_ blocked: Bool) {
        let now = uptime()
        settleEligibleImpressionDwell(at: now)
        surfaceBlocked = blocked
        reconcileBlockedState(at: now)
    }

    func stop() {
        let now = uptime()
        settleEligibleImpressionDwell(at: now)
        activeSurface = nil
        state.visualBecameUnavailable()
        reconcileImpressionTimer(at: now)
    }

    @discardableResult
    func finish() -> FullscreenPresentationTerminalOutcome? {
        let now = uptime()
        settleEligibleImpressionDwell(at: now)
        let outcome = state.finish()
        if outcome == .displayFailed { onDisplayFailed() }
        activeSurface = nil
        state.visualBecameUnavailable()
        reconcileImpressionTimer(at: now)
        return outcome
    }

    private func runImpressionTimer(generation: UInt64) async {
        while generation == impressionGeneration, state.impressionDwellEligible {
            do { try await Task.sleep(nanoseconds: tickNanos) } catch { return }
            if Task.isCancelled { return }
            guard generation == impressionGeneration else { return }
            let now = uptime()
            settleEligibleImpressionDwell(at: now)
            if state.impressionCommitted { cancelImpressionTimer() }
        }
    }

    func setApplicationActive(_ active: Bool) {
        let now = uptime()
        settleEligibleImpressionDwell(at: now)
        applicationActive = active
        reconcileBlockedState(at: now)
    }

    private func reconcileBlockedState(at now: TimeInterval) {
        state.setBlocked(surfaceBlocked || !applicationActive)
        reconcileImpressionTimer(at: now)
    }

    private func settleEligibleImpressionDwell(at now: TimeInterval) {
        let deltaMs = dwellClock.settle(at: now)
        guard state.accrueImpression(deltaMs: deltaMs, thresholdMs: impressionDelayMs) else { return }
        onImpression()
    }

    private func reconcileImpressionTimer(at now: TimeInterval) {
        if state.commitImpressionIfEligible(thresholdMs: impressionDelayMs) {
            onImpression()
        }
        guard state.impressionDwellEligible else {
            cancelImpressionTimer()
            return
        }
        dwellClock.resume(at: now)
        guard impressionTask == nil else { return }
        impressionGeneration &+= 1
        let generation = impressionGeneration
        impressionTask = Task { [weak self] in await self?.runImpressionTimer(generation: generation) }
    }

    private func cancelImpressionTimer() {
        impressionGeneration &+= 1
        impressionTask?.cancel()
        impressionTask = nil
        dwellClock.pause()
    }
}
#else
@MainActor
final class FullscreenPresentationAdmission {
    var hasAdmittedDisplay: Bool { false }
    var visualIsActive: Bool { false }
    init(
        onDisplayed: @escaping () -> Void,
        onDisplayFailed: @escaping () -> Void = {},
        onImpression: @escaping () -> Void
    ) {}
    func visualBecameReady(owner: FullscreenVisualSurfaceToken) {}
    func presentationDidSucceed() {}
    func htmlNavigationDidCommit() {}
    func htmlNavigationDidFail() {}
    func visualBecameUnavailable(owner: FullscreenVisualSurfaceToken) {}
    func setBlocked(_ blocked: Bool) {}
    func stop() {}
    @discardableResult
    func finish() -> FullscreenPresentationTerminalOutcome? { nil }
}
#endif
