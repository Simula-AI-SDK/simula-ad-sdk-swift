import Foundation

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

    mutating func setBlocked(_ blocked: Bool) {
        self.blocked = blocked
    }

    mutating func accrueImpression(deltaMs: Double, thresholdMs: Double) -> Bool {
        guard displayAdmitted, visualActive, !blocked, !impressionCommitted,
              deltaMs.isFinite, deltaMs > 0 else { return false }
        accruedImpressionMs += deltaMs
        guard accruedImpressionMs >= thresholdMs else { return false }
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

enum FullscreenPresentationTerminalOutcome: Equatable, Sendable {
    case displayFailed
    case closed
}

struct FullscreenPostPrimaryPolicy: Equatable, Sendable {
    let presentsFallbacks: Bool
    let notifiesPublisherClose: Bool
    let verifiesEarnedReward: Bool

    init(terminalOutcome: FullscreenPresentationTerminalOutcome, earnedReward: Bool = false) {
        presentsFallbacks = true
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

    mutating func earn(reason: RewardCompletionReason) {
        guard !earned else { return }
        earned = true
        self.reason = reason
    }
}

func shouldRunRewardedHTMLGate(
    primaryCreativeReady: Bool,
    appForegrounded: Bool,
    storeSheetPresented: Bool,
    rewardEarned: Bool
) -> Bool {
    primaryCreativeReady && appForegrounded && !storeSheetPresented && !rewardEarned
}

func rewardedHTMLGateCompletionReason(
    primaryCreativeReady: Bool,
    actualElapsedPlayTime: TimeInterval,
    gateDuration: TimeInterval
) -> RewardCompletionReason? {
    guard primaryCreativeReady, actualElapsedPlayTime.isFinite, gateDuration.isFinite,
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

#if os(iOS)
import UIKit

@MainActor
final class FullscreenPresentationAdmission {
    private var state = FullscreenVisualAdmissionState()
    private var impressionTask: Task<Void, Never>?
    private var activeSurface: FullscreenVisualSurfaceToken?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var applicationActive: Bool
    private var surfaceBlocked = false
    private let onDisplayed: () -> Void
    private let onDisplayFailed: () -> Void
    private let onImpression: () -> Void
    private let impressionDelayMs: Double
    private let tickNanos: UInt64

    init(
        onDisplayed: @escaping () -> Void,
        onDisplayFailed: @escaping () -> Void = {},
        onImpression: @escaping () -> Void,
        impressionDelayMs: Double = fullscreenImpressionDelayMs,
        tickNanos: UInt64 = impressionTickNanos
    ) {
        applicationActive = UIApplication.shared.applicationState == .active
        self.onDisplayed = onDisplayed
        self.onDisplayFailed = onDisplayFailed
        self.onImpression = onImpression
        self.impressionDelayMs = impressionDelayMs
        self.tickNanos = tickNanos
        state.setBlocked(!applicationActive)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.setApplicationActive(false) }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.setApplicationActive(true) }
        })
    }

    deinit {
        impressionTask?.cancel()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var hasAdmittedDisplay: Bool { state.displayAdmitted }
    var visualIsActive: Bool { state.visualActive }

    func visualBecameReady(owner: FullscreenVisualSurfaceToken) {
        let shouldNotifyDisplayed = state.visualBecameReady()
        guard state.visualActive else { return }
        activeSurface = owner
        if shouldNotifyDisplayed { onDisplayed() }
        guard impressionTask == nil, !state.impressionCommitted else { return }
        impressionTask = Task { [weak self] in await self?.runImpressionTimer() }
    }

    func presentationDidSucceed() {
        let shouldNotifyDisplayed = state.visualBecameReady()
        guard state.visualActive else { return }
        if shouldNotifyDisplayed { onDisplayed() }
        guard impressionTask == nil, !state.impressionCommitted else { return }
        impressionTask = Task { [weak self] in await self?.runImpressionTimer() }
    }

    func visualBecameUnavailable(owner: FullscreenVisualSurfaceToken) {
        guard activeSurface == owner else { return }
        activeSurface = nil
        state.visualBecameUnavailable()
    }

    func setBlocked(_ blocked: Bool) {
        surfaceBlocked = blocked
        reconcileBlockedState()
    }

    func stop() {
        activeSurface = nil
        state.visualBecameUnavailable()
        impressionTask?.cancel()
        impressionTask = nil
    }

    @discardableResult
    func finish() -> FullscreenPresentationTerminalOutcome? {
        let outcome = state.finish()
        if outcome == .displayFailed { onDisplayFailed() }
        stop()
        return outcome
    }

    private func runImpressionTimer() async {
        var lastTick = ProcessInfo.processInfo.systemUptime
        while !state.impressionCommitted {
            do { try await Task.sleep(nanoseconds: tickNanos) } catch { return }
            if Task.isCancelled { return }
            let now = ProcessInfo.processInfo.systemUptime
            let shouldCommit = state.accrueImpression(
                deltaMs: (now - lastTick) * 1_000,
                thresholdMs: impressionDelayMs
            )
            lastTick = now
            if shouldCommit {
                onImpression()
                return
            }
        }
    }

    private func setApplicationActive(_ active: Bool) {
        applicationActive = active
        reconcileBlockedState()
    }

    private func reconcileBlockedState() {
        state.setBlocked(surfaceBlocked || !applicationActive)
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
    func visualBecameUnavailable(owner: FullscreenVisualSurfaceToken) {}
    func setBlocked(_ blocked: Bool) {}
    func stop() {}
    @discardableResult
    func finish() -> FullscreenPresentationTerminalOutcome? { nil }
}
#endif
