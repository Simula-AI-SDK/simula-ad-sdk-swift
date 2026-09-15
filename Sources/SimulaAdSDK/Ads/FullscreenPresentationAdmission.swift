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

    mutating func visualBecameReady() -> Bool {
        guard displayOutcome != .failed else { return false }
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
}

func earnedRewardAfterPrimaryFailure(primaryVisuallyReady: Bool) -> Bool {
    primaryVisuallyReady
}

struct FullscreenVisualSurfaceToken: Hashable, Sendable {
    fileprivate let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

#if os(iOS)
@MainActor
final class FullscreenPresentationAdmission {
    private var state = FullscreenVisualAdmissionState()
    private var impressionTask: Task<Void, Never>?
    private var activeSurface: FullscreenVisualSurfaceToken?
    private let onDisplayed: () -> Void
    private let onDisplayFailed: () -> Void
    private let onImpression: () -> Void

    init(
        onDisplayed: @escaping () -> Void,
        onDisplayFailed: @escaping () -> Void = {},
        onImpression: @escaping () -> Void
    ) {
        self.onDisplayed = onDisplayed
        self.onDisplayFailed = onDisplayFailed
        self.onImpression = onImpression
    }

    deinit {
        impressionTask?.cancel()
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

    func visualBecameUnavailable(owner: FullscreenVisualSurfaceToken) {
        guard activeSurface == owner else { return }
        activeSurface = nil
        state.visualBecameUnavailable()
    }

    func setBlocked(_ blocked: Bool) {
        state.setBlocked(blocked)
    }

    func stop() {
        activeSurface = nil
        state.visualBecameUnavailable()
        impressionTask?.cancel()
        impressionTask = nil
    }

    func finish() {
        if state.failDisplayIfNeverAdmitted() { onDisplayFailed() }
        stop()
    }

    private func runImpressionTimer() async {
        var lastTick = ProcessInfo.processInfo.systemUptime
        while !state.impressionCommitted {
            do { try await Task.sleep(nanoseconds: impressionTickNanos) } catch { return }
            if Task.isCancelled { return }
            let now = ProcessInfo.processInfo.systemUptime
            let shouldCommit = state.accrueImpression(
                deltaMs: (now - lastTick) * 1_000,
                thresholdMs: fullscreenImpressionDelayMs
            )
            lastTick = now
            if shouldCommit {
                onImpression()
                return
            }
        }
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
    func visualBecameUnavailable(owner: FullscreenVisualSurfaceToken) {}
    func setBlocked(_ blocked: Bool) {}
    func stop() {}
    func finish() {}
}
#endif
