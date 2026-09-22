import Foundation

let maxVideoPlanSKOverlayDelaySeconds = 60
let defaultVideoPlanSKOverlayDelaySeconds = 3

func videoPlanOverlayUsesPresentationWatchTotals(stage: String) -> Bool {
    stage == FullscreenVideoTelemetryStage.skoverlayDismissed
        || stage == FullscreenVideoTelemetryStage.skoverlayFailed
}

func effectiveVideoPlanSKOverlayConfig(
    isVideoPlanV2: Bool,
    config: SKOverlayConfig?
) -> SKOverlayConfig? {
    guard isVideoPlanV2 else { return nil }
    if let config, !config.enabled { return nil }
    return SKOverlayConfig(
        enabled: true,
        timing: .delayed,
        delaySeconds: min(
            maxVideoPlanSKOverlayDelaySeconds,
            max(0, config?.delaySeconds ?? defaultVideoPlanSKOverlayDelaySeconds)
        ),
        position: config?.position ?? .bottom,
        dismissible: config?.dismissible ?? true
    )
}

enum VideoPlanSKOverlayClockAction: Equatable, Sendable {
    case none
    case schedule(TimeInterval)
    case ready
}

/// Presentation-owned eligible-time clock. It is independent of any individual video view, so a
/// video-to-video or video-to-playable handoff neither resets nor cancels the one-shot overlay.
struct VideoPlanSKOverlayClock: Equatable, Sendable {
    let delay: TimeInterval
    private(set) var elapsed: TimeInterval = 0
    private(set) var started = false
    private(set) var blocked = true
    private(set) var ready = false
    private(set) var cancelled = false
    private var anchor: TimeInterval?

    init(delay: TimeInterval) {
        self.delay = min(
            TimeInterval(maxVideoPlanSKOverlayDelaySeconds),
            max(0, delay.isFinite ? delay : TimeInterval(defaultVideoPlanSKOverlayDelaySeconds))
        )
    }

    mutating func start(now: TimeInterval, blocked: Bool) -> VideoPlanSKOverlayClockAction {
        guard !cancelled, !ready else { return .none }
        if !started { started = true }
        return setBlocked(blocked, now: now)
    }

    mutating func setBlocked(_ blocked: Bool, now: TimeInterval) -> VideoPlanSKOverlayClockAction {
        guard started, !cancelled, !ready else { return .none }
        accrue(now: now)
        self.blocked = blocked
        anchor = blocked ? nil : now
        if elapsed >= delay {
            ready = true
            anchor = nil
            return .ready
        }
        return blocked ? .none : .schedule(delay - elapsed)
    }

    mutating func deadlineFired(now: TimeInterval) -> VideoPlanSKOverlayClockAction {
        guard started, !blocked, !cancelled, !ready else { return .none }
        accrue(now: now)
        anchor = now
        if elapsed >= delay {
            ready = true
            anchor = nil
            return .ready
        }
        return .schedule(delay - elapsed)
    }

    mutating func cancel(now: TimeInterval) {
        accrue(now: now)
        cancelled = true
        anchor = nil
    }

    private mutating func accrue(now: TimeInterval) {
        guard let anchor, !blocked, now.isFinite, now >= anchor else { return }
        elapsed = min(delay, elapsed + now - anchor)
    }
}

struct VideoPlanBlockerOwner: Hashable, Sendable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

struct VideoPlanBlockerState: Equatable, Sendable {
    private(set) var owner: VideoPlanBlockerOwner?
    private(set) var generation: UInt64 = 0

    mutating func activate(
        owner: VideoPlanBlockerOwner,
        generation: UInt64,
        blocked: Bool
    ) -> Bool {
        self.owner = owner
        self.generation = generation
        return blocked
    }

    func update(
        owner: VideoPlanBlockerOwner,
        generation: UInt64,
        blocked: Bool
    ) -> Bool? {
        guard self.owner == owner, self.generation == generation else { return nil }
        return blocked
    }

    mutating func deactivate(owner: VideoPlanBlockerOwner, generation: UInt64) -> Bool? {
        guard self.owner == owner, self.generation == generation else { return nil }
        self.owner = nil
        return true
    }
}

enum VideoPlanTerminalEvent: Equatable, Sendable {
    case userClose
    case completion
    case failure
}

struct VideoPlanTerminalArbiter<PlayerID: Hashable & Sendable>: Sendable {
    private(set) var currentPlayerID: PlayerID?
    private(set) var generation: UInt64 = 0
    private var startedGeneration: UInt64?
    private var terminal: (generation: UInt64, event: VideoPlanTerminalEvent)?
    private(set) var cancelled = false

    @discardableResult
    mutating func register(playerID: PlayerID) -> Bool {
        guard !cancelled else { return false }
        guard currentPlayerID != playerID else { return true }
        currentPlayerID = playerID
        generation &+= 1
        startedGeneration = nil
        terminal = nil
        return true
    }

    mutating func start(playerID: PlayerID) -> Bool {
        guard !cancelled, currentPlayerID == playerID,
              startedGeneration != generation,
              terminal == nil || terminal?.event == .completion else { return false }
        startedGeneration = generation
        return true
    }

    mutating func claimTerminal(playerID: PlayerID, event: VideoPlanTerminalEvent) -> Bool {
        guard !cancelled, currentPlayerID == playerID,
              terminal?.generation != generation else { return false }
        terminal = (generation, event)
        return true
    }

    mutating func cancel() {
        cancelled = true
    }
}

enum VideoPlanOverlayPhase: String, Equatable, Sendable {
    case video
    case nextStep = "next_step"
}

struct VideoPlanOverlayPlacementState: Equatable, Sendable {
    private(set) var phase = VideoPlanOverlayPhase.nextStep
    private(set) var readyOn: VideoPlanOverlayPhase?
    private(set) var shownOn: VideoPlanOverlayPhase?

    mutating func videoBecameActive() {
        phase = .video
    }

    mutating func handoffBegan() {
        phase = .nextStep
    }

    mutating func becameReady() {
        if readyOn == nil { readyOn = phase }
    }

    mutating func shown() -> VideoPlanOverlayPhase {
        shownOn = phase
        return phase
    }
}

struct VideoHandoffTimingSample: Equatable, Sendable {
    let msToNextStepReady: Double
    let secondsSinceVideoStart: Double
}

struct VideoHandoffTimingState: Equatable, Sendable {
    private var videoStartedAt: TimeInterval?
    private var terminalAt: TimeInterval?

    mutating func videoStarted(now: TimeInterval) {
        guard now.isFinite else { return }
        videoStartedAt = now
    }

    mutating func videoTerminated(now: TimeInterval) {
        guard now.isFinite else { return }
        terminalAt = now
    }

    mutating func nextStepReady(now: TimeInterval) -> VideoHandoffTimingSample? {
        guard now.isFinite, let terminalAt, now >= terminalAt else { return nil }
        let startedAt = videoStartedAt ?? terminalAt
        self.terminalAt = nil
        videoStartedAt = nil
        return VideoHandoffTimingSample(
            msToNextStepReady: (now - terminalAt) * 1_000,
            secondsSinceVideoStart: max(0, now - startedAt)
        )
    }
}

struct VideoPlanHandoffCompletion<Origin> {
    let origin: Origin
    let timing: VideoHandoffTimingSample
}

/// Keeps the video that initiated a handoff until a later step is actually ready. A video that
/// fails before first frame has no start age and therefore cannot replace the pending origin.
struct VideoPlanHandoffState<Origin> {
    private(set) var pendingOrigin: Origin?
    private var timing = VideoHandoffTimingState()

    mutating func videoStarted(
        now: TimeInterval
    ) -> VideoPlanHandoffCompletion<Origin>? {
        let completion = nextStepReady(now: now)
        timing.videoStarted(now: now)
        return completion
    }

    mutating func videoTerminated(
        origin: Origin,
        secondsSinceVideoStart: TimeInterval?,
        now: TimeInterval
    ) {
        guard pendingOrigin == nil,
              let secondsSinceVideoStart,
              secondsSinceVideoStart.isFinite,
              secondsSinceVideoStart >= 0,
              now.isFinite else { return }
        pendingOrigin = origin
        timing.videoStarted(now: max(0, now - secondsSinceVideoStart))
        timing.videoTerminated(now: now)
    }

    mutating func nextStepReady(
        now: TimeInterval
    ) -> VideoPlanHandoffCompletion<Origin>? {
        guard let pendingOrigin,
              let sample = timing.nextStepReady(now: now) else { return nil }
        self.pendingOrigin = nil
        return VideoPlanHandoffCompletion(origin: pendingOrigin, timing: sample)
    }

    mutating func closePending() -> Origin? {
        defer { pendingOrigin = nil }
        return pendingOrigin
    }
}

struct VideoPlanHandoffTelemetry: Sendable {
    let adFormat: String
    let adUnitId: String?
    let adId: String?
    let serveId: String?
    let creative: Creative?
    let behavior: AdBehavior?
    let muted: Bool
    let mutedWatchMs: Int
    let unmutedWatchMs: Int
    let videoPositionS: Double
    let durationS: Double?
    let secondsSinceVideoStart: Double?
    let reason: String
}

struct VideoPlanOverlayTelemetry: Sendable {
    let adFormat: String
    let adUnitId: String?
    let adId: String?
    let serveId: String?
    let creative: Creative?
    let behavior: AdBehavior?
}

struct VideoPlanPresentationWatchTotals: Equatable, Sendable {
    var mutedMilliseconds = 0
    var unmutedMilliseconds = 0
}

/// Aggregates cumulative per-player snapshots without counting the same media interval twice.
struct VideoPlanPresentationWatchAccounting<PlayerID: Hashable & Sendable>: Sendable {
    private var latestByPlayer: [PlayerID: VideoPlanPresentationWatchTotals] = [:]
    private(set) var totals = VideoPlanPresentationWatchTotals()

    @discardableResult
    mutating func update(
        playerID: PlayerID,
        mutedMilliseconds: Int,
        unmutedMilliseconds: Int
    ) -> VideoPlanPresentationWatchTotals {
        let snapshot = VideoPlanPresentationWatchTotals(
            mutedMilliseconds: max(0, mutedMilliseconds),
            unmutedMilliseconds: max(0, unmutedMilliseconds)
        )
        let previous = latestByPlayer[playerID] ?? VideoPlanPresentationWatchTotals()
        totals.mutedMilliseconds = addingWithoutOverflow(
            totals.mutedMilliseconds,
            max(0, snapshot.mutedMilliseconds - previous.mutedMilliseconds)
        )
        totals.unmutedMilliseconds = addingWithoutOverflow(
            totals.unmutedMilliseconds,
            max(0, snapshot.unmutedMilliseconds - previous.unmutedMilliseconds)
        )
        latestByPlayer[playerID] = VideoPlanPresentationWatchTotals(
            mutedMilliseconds: max(previous.mutedMilliseconds, snapshot.mutedMilliseconds),
            unmutedMilliseconds: max(previous.unmutedMilliseconds, snapshot.unmutedMilliseconds)
        )
        return totals
    }

    private func addingWithoutOverflow(_ value: Int, _ delta: Int) -> Int {
        let (sum, overflow) = value.addingReportingOverflow(delta)
        return overflow ? Int.max : sum
    }
}

#if os(iOS)
import StoreKit
import UIKit

@MainActor
final class VideoPlanPresentationScope {
    private(set) var isMuted = false
    private var watchAccounting = VideoPlanPresentationWatchAccounting<UUID>()
    private var terminalArbiter = VideoPlanTerminalArbiter<UUID>()

    private var clock: VideoPlanSKOverlayClock?
    private var deadlineTask: Task<Void, Never>?
    private var resolvedAppID: String?
    private var resolutionStarted = false
    private var config: SKOverlayConfig?
    private var attribution: AdAttribution?
    private weak var originatingScene: UIWindowScene?
    private var ownership: SKOverlayOwnershipToken?
    private var cancelled = false
    private var blocked = true
    private var blockerState = VideoPlanBlockerState()
    private var handoffState = VideoPlanHandoffState<VideoPlanHandoffTelemetry>()
    private var overlayTelemetry: VideoPlanOverlayTelemetry?
    private var overlayShownAt: TimeInterval?
    private var overlayFailureRecorded = false
    private var overlayPlacement = VideoPlanOverlayPlacementState()
    private var overlayClaim = SKOverlayPresentationClaim()

    func updateMuted(_ muted: Bool) {
        isMuted = muted
    }

    @discardableResult
    func registerVideoPlayer(playerID: UUID) -> Bool {
        terminalArbiter.register(playerID: playerID)
    }

    func claimVideoTerminal(playerID: UUID, event: VideoPlanTerminalEvent) -> Bool {
        terminalArbiter.claimTerminal(playerID: playerID, event: event)
    }

    func reserveLegacySKOverlay() -> SKOverlayPresentationClaim.Reservation? {
        overlayClaim.reserve()
    }

    @discardableResult
    func legacySKOverlayDidPresent(_ reservation: SKOverlayPresentationClaim.Reservation) -> Bool {
        overlayClaim.succeed(reservation)
    }

    func legacySKOverlayDidFail(_ reservation: SKOverlayPresentationClaim.Reservation) {
        overlayClaim.fail(reservation)
    }

    @discardableResult
    func updateWatchAccounting(
        playerID: UUID,
        mutedMilliseconds: Int,
        unmutedMilliseconds: Int
    ) -> VideoPlanPresentationWatchTotals {
        watchAccounting.update(
            playerID: playerID,
            mutedMilliseconds: mutedMilliseconds,
            unmutedMilliseconds: unmutedMilliseconds
        )
    }

    func firstVideoFrame(
        playerID: UUID,
        creative: Creative?,
        behavior: AdBehavior?,
        adFormat: String,
        adUnitId: String?,
        adId: String?,
        serveId: String?,
        config sourceConfig: SKOverlayConfig?,
        trackingUrl: String?,
        destination: AdDestination,
        storeUrl: String?,
        attribution: AdAttribution?,
        originatingScene: UIWindowScene,
        blocked: Bool
    ) {
        guard !cancelled, creative?.isVideoPlanV2Clip == true,
              terminalArbiter.start(playerID: playerID) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let completion = handoffState.videoStarted(now: now) {
            recordHandoff(completion)
        }
        overlayPlacement.videoBecameActive()
        guard let effective = effectiveVideoPlanSKOverlayConfig(
            isVideoPlanV2: true,
            config: sourceConfig
        ) else { return }
        self.blocked = blocked
        if clock == nil {
            overlayTelemetry = VideoPlanOverlayTelemetry(
                adFormat: adFormat,
                adUnitId: adUnitId,
                adId: adId,
                serveId: serveId,
                creative: creative,
                behavior: behavior
            )
            config = effective
            self.attribution = attribution
            self.originatingScene = originatingScene
            clock = VideoPlanSKOverlayClock(delay: TimeInterval(effective.delaySeconds))
            resolveAppIDIfNeeded(
                trackingUrl: trackingUrl,
                destination: destination,
                storeUrl: storeUrl
            )
        }
        guard var clock else { return }
        let action = clock.start(now: ProcessInfo.processInfo.systemUptime, blocked: blocked)
        self.clock = clock
        apply(action)
    }

    func videoTerminated(_ telemetry: VideoPlanHandoffTelemetry) {
        guard !cancelled else { return }
        overlayPlacement.handoffBegan()
        let now = ProcessInfo.processInfo.systemUptime
        handoffState.videoTerminated(
            origin: telemetry,
            secondsSinceVideoStart: telemetry.secondsSinceVideoStart,
            now: now
        )
    }

    func handoffBegan() {
        guard !cancelled else { return }
        overlayPlacement.handoffBegan()
    }

    func playableStepReady() {
        guard !cancelled else { return }
        completePendingHandoff(now: ProcessInfo.processInfo.systemUptime)
    }

    func nextStepFailed() {
        closePendingHandoff(reason: FullscreenVideoTerminationReason.nextStepFailed)
    }

    func closePendingHandoff(reason: String?) {
        guard !cancelled else { return }
        closePendingHandoffIfNeeded(reasonOverride: reason)
    }

    private func completePendingHandoff(now: TimeInterval) {
        guard let completion = handoffState.nextStepReady(now: now) else { return }
        recordHandoff(completion)
    }

    private func recordHandoff(
        _ completion: VideoPlanHandoffCompletion<VideoPlanHandoffTelemetry>
    ) {
        let pendingHandoff = completion.origin
        let watchTotals = watchAccounting.totals
        recordFullscreenVideoLifecycle(
            stage: FullscreenVideoTelemetryStage.handoff,
            adFormat: pendingHandoff.adFormat,
            adUnitId: pendingHandoff.adUnitId,
            adId: pendingHandoff.adId,
            serveId: pendingHandoff.serveId,
            isVideoPlanV2: true,
            creative: pendingHandoff.creative,
            behavior: pendingHandoff.behavior,
            muted: pendingHandoff.muted,
            mutedWatchMs: watchTotals.mutedMilliseconds,
            unmutedWatchMs: watchTotals.unmutedMilliseconds,
            videoPositionS: pendingHandoff.videoPositionS,
            durationS: pendingHandoff.durationS,
            reason: pendingHandoff.reason,
            msToNextStepReady: completion.timing.msToNextStepReady,
            secondsSinceVideoStart: completion.timing.secondsSinceVideoStart,
            on: "next_step"
        )
    }

    func activateBlocker(
        owner: VideoPlanBlockerOwner,
        generation: UInt64,
        blocked: Bool
    ) {
        applyBlocked(blockerState.activate(owner: owner, generation: generation, blocked: blocked))
    }

    func updateBlocker(
        owner: VideoPlanBlockerOwner,
        generation: UInt64,
        blocked: Bool
    ) {
        guard let accepted = blockerState.update(
            owner: owner,
            generation: generation,
            blocked: blocked
        ) else { return }
        applyBlocked(accepted)
    }

    func deactivateBlocker(owner: VideoPlanBlockerOwner, generation: UInt64) {
        guard let blocked = blockerState.deactivate(owner: owner, generation: generation) else { return }
        applyBlocked(blocked)
    }

    private func applyBlocked(_ blocked: Bool) {
        self.blocked = blocked
        guard var clock else { return }
        let action = clock.setBlocked(blocked, now: ProcessInfo.processInfo.systemUptime)
        self.clock = clock
        apply(action)
        if !blocked { presentIfReady() }
    }

    func cancel() {
        guard !cancelled else { return }
        closePendingHandoffIfNeeded()
        cancelled = true
        terminalArbiter.cancel()
        deadlineTask?.cancel()
        deadlineTask = nil
        if var clock {
            clock.cancel(now: ProcessInfo.processInfo.systemUptime)
            self.clock = clock
        }
        if let ownership, #available(iOS 14.0, *) {
            SKOverlayPresenter.dismiss(ownershipToken: ownership)
            recordOverlay(
                stage: FullscreenVideoTelemetryStage.skoverlayDismissed,
                visibleS: overlayShownAt.map { max(0, ProcessInfo.processInfo.systemUptime - $0) }
            )
        }
        ownership = nil
    }

    private func closePendingHandoffIfNeeded(reasonOverride: String? = nil) {
        guard let pendingHandoff = handoffState.closePending() else { return }
        let watchTotals = watchAccounting.totals
        recordFullscreenVideoLifecycle(
            stage: FullscreenVideoTelemetryStage.close,
            adFormat: pendingHandoff.adFormat,
            adUnitId: pendingHandoff.adUnitId,
            adId: pendingHandoff.adId,
            serveId: pendingHandoff.serveId,
            isVideoPlanV2: true,
            creative: pendingHandoff.creative,
            behavior: pendingHandoff.behavior,
            muted: pendingHandoff.muted,
            mutedWatchMs: watchTotals.mutedMilliseconds,
            unmutedWatchMs: watchTotals.unmutedMilliseconds,
            videoPositionS: pendingHandoff.videoPositionS,
            durationS: pendingHandoff.durationS,
            reason: reasonOverride ?? pendingHandoff.reason,
            secondsSinceVideoStart: pendingHandoff.secondsSinceVideoStart
        )
    }

    private func resolveAppIDIfNeeded(
        trackingUrl: String?,
        destination: AdDestination,
        storeUrl: String?
    ) {
        guard !resolutionStarted, #available(iOS 14.0, *) else { return }
        resolutionStarted = true
        CreativeCTARouter.resolveAppStoreID(
            trackingUrl: trackingUrl,
            destination: destination,
            storeUrl: storeUrl
        ) { [weak self] appID in
            guard let self, !self.cancelled else { return }
            self.resolvedAppID = appID
            if appID?.isEmpty != false {
                self.recordOverlayFailure("app_id_unresolved")
            }
            self.presentIfReady()
        }
    }

    private func apply(_ action: VideoPlanSKOverlayClockAction) {
        deadlineTask?.cancel()
        deadlineTask = nil
        switch action {
        case .none:
            break
        case .ready:
            overlayPlacement.becameReady()
            presentIfReady()
        case .schedule(let delay):
            guard delay.isFinite, delay >= 0 else { return }
            deadlineTask = Task { [weak self] in
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                self?.deadlineFired()
            }
        }
    }

    private func deadlineFired() {
        deadlineTask = nil
        guard var clock else { return }
        let action = clock.deadlineFired(now: ProcessInfo.processInfo.systemUptime)
        self.clock = clock
        apply(action)
    }

    private func presentIfReady() {
        guard !cancelled, ownership == nil, clock?.ready == true, !blocked,
              let config, let appID = resolvedAppID, !appID.isEmpty,
              let originatingScene,
              UIApplication.shared.applicationState == .active,
              originatingScene.activationState == .foregroundActive,
              #available(iOS 14.0, *) else { return }
        guard let reservation = overlayClaim.reserve() else { return }
        let presented = SKOverlayPresenter.present(
            appID: appID,
            config: config,
            attribution: attribution,
            originatingScene: originatingScene
        )
        guard let presented else {
            overlayClaim.fail(reservation)
            recordOverlayFailure("presentation_failed")
            return
        }
        guard overlayClaim.succeed(reservation) else {
            SKOverlayPresenter.dismiss(ownershipToken: presented)
            return
        }
        ownership = presented
        overlayShownAt = ProcessInfo.processInfo.systemUptime
        recordOverlay(
            stage: FullscreenVideoTelemetryStage.skoverlayShown,
            on: overlayPlacement.shown().rawValue
        )
    }

    private func recordOverlayFailure(_ error: String) {
        guard !overlayFailureRecorded else { return }
        overlayFailureRecorded = true
        recordOverlay(stage: FullscreenVideoTelemetryStage.skoverlayFailed, error: error)
    }

    private func recordOverlay(
        stage: String,
        visibleS: Double? = nil,
        error: String? = nil,
        on: String? = nil
    ) {
        guard let telemetry = overlayTelemetry else { return }
        // Overlay shown is non-terminal and carries no presentation watch totals. Terminal overlay
        // events are explicitly presentation-wide because they close the presentation-owned overlay.
        let includesPresentationTotals = videoPlanOverlayUsesPresentationWatchTotals(stage: stage)
        let watchTotals = includesPresentationTotals ? watchAccounting.totals : nil
        recordFullscreenVideoLifecycle(
            stage: stage,
            adFormat: telemetry.adFormat,
            adUnitId: telemetry.adUnitId,
            adId: telemetry.adId,
            serveId: telemetry.serveId,
            isVideoPlanV2: true,
            creative: telemetry.creative,
            behavior: telemetry.behavior,
            muted: isMuted,
            mutedWatchMs: watchTotals?.mutedMilliseconds,
            unmutedWatchMs: watchTotals?.unmutedMilliseconds,
            errorCode: error,
            visibleS: visibleS,
            on: on
        )
    }
}
#else
@MainActor
final class VideoPlanPresentationScope {
    private(set) var isMuted = false
    private var watchAccounting = VideoPlanPresentationWatchAccounting<UUID>()
    func updateMuted(_ muted: Bool) { isMuted = muted }
    @discardableResult
    func registerVideoPlayer(playerID: UUID) -> Bool { false }
    func claimVideoTerminal(playerID: UUID, event: VideoPlanTerminalEvent) -> Bool { false }
    @discardableResult
    func updateWatchAccounting(
        playerID: UUID,
        mutedMilliseconds: Int,
        unmutedMilliseconds: Int
    ) -> VideoPlanPresentationWatchTotals {
        watchAccounting.update(
            playerID: playerID,
            mutedMilliseconds: mutedMilliseconds,
            unmutedMilliseconds: unmutedMilliseconds
        )
    }
    func videoTerminated(_ telemetry: VideoPlanHandoffTelemetry) {}
    func handoffBegan() {}
    func playableStepReady() {}
    func nextStepFailed() {}
    func closePendingHandoff(reason: String?) {}
    func activateBlocker(owner: VideoPlanBlockerOwner, generation: UInt64, blocked: Bool) {}
    func updateBlocker(owner: VideoPlanBlockerOwner, generation: UInt64, blocked: Bool) {}
    func deactivateBlocker(owner: VideoPlanBlockerOwner, generation: UInt64) {}
    func cancel() {}
}
#endif
