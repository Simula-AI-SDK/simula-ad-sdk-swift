import XCTest
@testable import SimulaAdSDK
#if os(iOS)
import AVFoundation
import Combine
#endif

final class FullscreenPresentationAdmissionTests: XCTestCase {
    private final class TestUptime {
        var now: TimeInterval
        init(_ now: TimeInterval) { self.now = now }
    }

    private final class LockedCleanupObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var cleanupCount = 0
        private var everyCleanupRanOnMain = true

        func record() {
            lock.lock()
            cleanupCount += 1
            everyCleanupRanOnMain = everyCleanupRanOnMain && Thread.isMainThread
            lock.unlock()
        }

        func snapshot() -> (count: Int, allOnMain: Bool) {
            lock.lock()
            let snapshot = (cleanupCount, everyCleanupRanOnMain)
            lock.unlock()
            return snapshot
        }
    }

    private final class BackgroundReleaseBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        init(_ value: Value) {
            self.value = value
        }

        func release() {
            lock.lock()
            value = nil
            lock.unlock()
        }
    }

    #if os(iOS)
    private final class AudioActivationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var ranOnMain = false
        let gate = DispatchSemaphore(value: 0)

        func activate() -> Bool {
            lock.lock()
            count += 1
            ranOnMain = ranOnMain || Thread.isMainThread
            lock.unlock()
            gate.wait()
            return true
        }

        var snapshot: (count: Int, ranOnMain: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (count, ranOnMain)
        }
    }

    @MainActor
    func testAudioCoordinatorCoalescesOffMainAndCancelsStaleClaims() async throws {
        let probe = AudioActivationProbe()
        let coordinator = VideoAudioSessionCoordinator(activate: { probe.activate() })
        defer { probe.gate.signal() }
        var cancelledDelivered = false
        var delivered = false
        let cancelled = try XCTUnwrap(coordinator.claim { _ in cancelledDelivered = true })
        let live = try XCTUnwrap(coordinator.claim { success in delivered = success })
        await waitUntil { probe.snapshot.count == 1 }
        XCTAssertFalse(probe.snapshot.ranOnMain)
        XCTAssertFalse(delivered, "a stalled activation must return to the main actor immediately")
        coordinator.release(cancelled)
        probe.gate.signal()
        await waitUntil { delivered }
        XCTAssertFalse(cancelledDelivered)
        XCTAssertEqual(probe.snapshot.count, 1)

        var overlappingDelivered = false
        let overlapping = try XCTUnwrap(coordinator.claim { success in overlappingDelivered = success })
        await waitUntil { overlappingDelivered }
        XCTAssertEqual(probe.snapshot.count, 1, "active claims reuse the existing activation")
        coordinator.release(live)
        coordinator.release(overlapping)
        var laterDelivered = false
        let later = try XCTUnwrap(coordinator.claim { success in laterDelivered = success })
        await waitUntil { probe.snapshot.count == 2 }
        probe.gate.signal()
        await waitUntil { laterDelivered }
        coordinator.release(later)
    }

    @MainActor
    func testAudioCoordinatorFailedActivationAndBoundedPendingClaims() async throws {
        let failing = VideoAudioSessionCoordinator(activate: { false })
        var failed = false
        let claim = try XCTUnwrap(failing.claim { success in failed = !success })
        await waitUntil { failed }
        failing.release(claim)

        let probe = AudioActivationProbe()
        let coordinator = VideoAudioSessionCoordinator(activate: { probe.activate() })
        defer { probe.gate.signal() }
        var ids: [UUID] = []
        for _ in 0..<16 {
            ids.append(try XCTUnwrap(coordinator.claim { _ in XCTFail("cancelled claim delivered") }))
        }
        XCTAssertNil(coordinator.claim { _ in XCTFail("rejected claim delivered") })
        await waitUntil { probe.snapshot.count == 1 }
        for id in ids { coordinator.release(id) }
        probe.gate.signal()
    }

    @MainActor
    func testAudioActivationDeadlineFiresWhileWorkerIsBlocked() async throws {
        let probe = AudioActivationProbe()
        let coordinator = VideoAudioSessionCoordinator(claimTimeout: 0.01, activate: { probe.activate() })
        defer { probe.gate.signal() }
        var results: [Bool] = []
        let claim = try XCTUnwrap(coordinator.claim { results.append($0) })
        await waitUntil { probe.snapshot.count == 1 }
        await waitUntil { !results.isEmpty }
        XCTAssertEqual(results, [false])
        XCTAssertFalse(probe.snapshot.ranOnMain)
        coordinator.release(claim)
        XCTAssertNil(coordinator.claim { _ in XCTFail("a stalled activation must not admit another wait") })
        XCTAssertEqual(probe.snapshot.count, 1)
        probe.gate.signal()
        await waitUntil {
            guard let next = coordinator.claim(completion: { _ in }) else { return false }
            coordinator.release(next)
            return true
        }
    }

    @MainActor
    func testAudioActivationFailureMutesWithoutFailingTheVideo() {
        let player = FullscreenVideoPlayer(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil)
        XCTAssertFalse(player.isMuted)
        player.continueWithoutAudioSession()
        XCTAssertTrue(player.isMuted)
        if case .failed = player.status { XCTFail("Audio failure must not fail video playback") }
        XCTAssertFalse(player.isStopped)
        player.stop()
    }

    @MainActor
    func testIdleTimerCoordinatorRestoresHostValueAfterOverlappingTerminalReleases() {
        var hostValue = false
        var writes: [Bool] = []
        let coordinator = VideoIdleTimerCoordinator(
            read: { hostValue },
            write: { hostValue = $0; writes.append($0) }
        )
        coordinator.claim()
        coordinator.claim()
        coordinator.release()
        XCTAssertTrue(hostValue)
        coordinator.release()
        XCTAssertFalse(hostValue)
        XCTAssertEqual(writes, [true, false])
    }

    @MainActor
    func testIdleTimerCoordinatorDoesNotOverwriteHostChange() {
        var hostValue = false
        var writes: [Bool] = []
        let coordinator = VideoIdleTimerCoordinator(
            read: { hostValue },
            write: { hostValue = $0; writes.append($0) }
        )
        coordinator.claim()
        hostValue = false

        coordinator.release()

        XCTAssertFalse(hostValue)
        XCTAssertEqual(writes, [true])
    }
    #endif

    func testVideoFailureNeverEarnsBeforeGateEvenAfterFirstFrame() {
        let beforeFrame = rewardedTerminalOutcome(earned: false, actualElapsedPlayTime: 0)
        let afterFrame = rewardedTerminalOutcome(earned: false, actualElapsedPlayTime: 2.5)
        XCTAssertFalse(beforeFrame.earned)
        XCTAssertFalse(afterFrame.earned)
        XCTAssertEqual(afterFrame.elapsedPlayTime, 2.5)
    }

    func testFailurePreservesRewardThatWasAlreadyEarned() {
        let outcome = rewardedTerminalOutcome(
            earned: true,
            actualElapsedPlayTime: 12.5,
            completionReason: .durationElapsed
        )
        XCTAssertTrue(outcome.earned)
        XCTAssertEqual(outcome.elapsedPlayTime, 12.5)
        XCTAssertEqual(outcome.completionReason, .durationElapsed)
    }

    func testUnearnedTerminalOutcomeOmitsCompletionReason() {
        let outcome = rewardedTerminalOutcome(
            earned: false,
            actualElapsedPlayTime: 2.5,
            completionReason: .creativeCompleted
        )
        XCTAssertFalse(outcome.earned)
        XCTAssertNil(outcome.completionReason)
    }

    func testFirstEarnedCompletionReasonIsMonotonic() {
        var state = RewardCompletionState()
        state.earn(reason: .creativeCompleted)
        state.earn(reason: .durationElapsed)
        state.earn(reason: .videoCompleted)

        XCTAssertTrue(state.earned)
        XCTAssertEqual(state.reason, .creativeCompleted)
    }

    func testLegacyHTMLEarlyCompleteBeforeReadinessEarnsImmediately() {
        var early = RewardedEarlyCompletionState()
        var reward = RewardCompletionState()

        XCTAssertTrue(early.receive(
            signaled: true,
            requiresCreativeReadiness: false,
            primaryCreativeReady: false,
            rewardEarned: reward.earned
        ))
        reward.earn(reason: .creativeCompleted)

        XCTAssertTrue(early.consumed)
        XCTAssertFalse(early.pending)
        XCTAssertTrue(reward.earned)
        XCTAssertEqual(reward.reason, .creativeCompleted)
    }

    func testNativeVideoEarlyCompletionStillWaitsForFirstFrameReadiness() {
        var early = RewardedEarlyCompletionState()
        XCTAssertFalse(early.receive(
            signaled: true,
            requiresCreativeReadiness: true,
            primaryCreativeReady: false,
            rewardEarned: false
        ))
        XCTAssertTrue(early.pending)
        XCTAssertTrue(early.primaryCreativeBecameReady(rewardEarned: false))
    }

    func testEarlyCompleteDuplicateSignalsApplyExactlyOnce() {
        var early = RewardedEarlyCompletionState()

        XCTAssertTrue(early.receive(
            signaled: true,
            primaryCreativeReady: true,
            rewardEarned: false
        ))
        XCTAssertFalse(early.receive(
            signaled: true,
            primaryCreativeReady: true,
            rewardEarned: false
        ))
        XCTAssertFalse(early.primaryCreativeBecameReady(rewardEarned: false))
    }

    func testPendingEarlyCompleteWinsOverZeroAndPositiveHTMLGates() {
        for gateDuration in [0.0, 30.0] {
            var early = RewardedEarlyCompletionState()
            var reward = RewardCompletionState()
            XCTAssertFalse(early.receive(
                signaled: true,
                primaryCreativeReady: false,
                rewardEarned: false
            ))

            if early.primaryCreativeBecameReady(rewardEarned: reward.earned) {
                reward.earn(reason: .creativeCompleted)
            } else if let reason = rewardedHTMLGateCompletionReason(
                actualElapsedPlayTime: 0,
                gateDuration: gateDuration
            ) {
                reward.earn(reason: reason)
            }

            XCTAssertEqual(reward.reason, .creativeCompleted)
            XCTAssertFalse(shouldRunRewardedHTMLGate(
                appForegrounded: true,
                storeSheetPresented: false,
                rewardEarned: reward.earned,
                gatePermanentlyIneligible: false
            ))
        }
    }

    func testRewardedHTMLReadinessBudgetUsesSafetyFloorAndCloseDelay() {
        XCTAssertEqual(
            RewardedHTMLReadinessDeadlineState(configuredCloseDelay: 0).budget,
            rewardedHTMLReadinessSafetySeconds
        )
        XCTAssertEqual(RewardedHTMLReadinessDeadlineState(configuredCloseDelay: 30).budget, 30)
    }

    func testHungRewardedHTMLFailsOnceAtForegroundDeadline() {
        var state = RewardedHTMLReadinessDeadlineState(configuredCloseDelay: 0)
        XCTAssertEqual(state.reconcile(now: 0, eligible: true), .schedule(10))
        XCTAssertEqual(state.deadlineFired(now: 10), .fail)
        XCTAssertTrue(state.completed)
        XCTAssertEqual(state.deadlineFired(now: 20), .none)
    }

    func testSlowRewardedHTMLGetsConfiguredCloseDelayBeforeFailure() {
        var state = RewardedHTMLReadinessDeadlineState(configuredCloseDelay: 30)
        XCTAssertEqual(state.reconcile(now: 0, eligible: true), .schedule(30))
        XCTAssertEqual(state.reconcile(now: 10, eligible: false), .cancel)
        XCTAssertEqual(state.elapsed, 10)
        XCTAssertEqual(state.reconcile(now: 10, eligible: true), .schedule(20))
        XCTAssertEqual(state.deadlineFired(now: 30), .fail)
    }

    func testRewardedHTMLReadyBeforeDeadlineCancelsFailure() {
        var state = RewardedHTMLReadinessDeadlineState(configuredCloseDelay: 0)
        XCTAssertEqual(state.reconcile(now: 0, eligible: true), .schedule(10))
        XCTAssertEqual(state.complete(now: 4), .cancel)
        XCTAssertTrue(state.completed)
        XCTAssertEqual(state.deadlineFired(now: 10), .none)
    }

    func testRewardedHTMLReadinessDeadlineExcludesBackgroundTime() {
        var state = RewardedHTMLReadinessDeadlineState(configuredCloseDelay: 0)
        XCTAssertEqual(state.reconcile(now: 0, eligible: true), .schedule(10))
        XCTAssertEqual(state.reconcile(now: 4, eligible: false), .cancel)
        XCTAssertEqual(state.elapsed, 4)
        XCTAssertEqual(state.reconcile(now: 100, eligible: true), .schedule(6))
        XCTAssertEqual(state.deadlineFired(now: 106), .fail)
    }

    func testLegacyHTMLRewardGateRunsFromPresentationWithoutNavigationReadiness() {
        XCTAssertTrue(shouldRunRewardedHTMLGate(
            appForegrounded: true,
            storeSheetPresented: false,
            rewardEarned: false,
            gatePermanentlyIneligible: false
        ))
        XCTAssertEqual(rewardedHTMLGateCompletionReason(
            actualElapsedPlayTime: 30,
            gateDuration: 30
        ), .durationElapsed)
    }

    func testLegacyHTMLZeroGateEarnsAtPresentation() {
        XCTAssertEqual(
            rewardedHTMLGateCompletionReason(
                actualElapsedPlayTime: 0,
                gateDuration: 0
            ),
            .durationElapsed
        )
    }

    func testLegacyHTMLNavigationFailureDoesNotRevokePresentationTimedReward() {
        var completion = RewardCompletionState()
        if let reason = rewardedHTMLGateCompletionReason(
            actualElapsedPlayTime: 30,
            gateDuration: 30
        ) {
            completion.earn(reason: reason)
        }
        let outcome = rewardedTerminalOutcome(
            earned: completion.earned,
            actualElapsedPlayTime: 30,
            completionReason: completion.reason
        )
        let policy = FullscreenPostPrimaryPolicy(
            terminalOutcome: .closed,
            earnedReward: outcome.earned
        )

        XCTAssertTrue(policy.presentsFallbacks)
        XCTAssertTrue(policy.verifiesEarnedReward)
        XCTAssertTrue(outcome.earned)
        XCTAssertEqual(outcome.completionReason, .durationElapsed)
        XCTAssertEqual(rewardVerificationElapsedPlayTime(
            earned: outcome.earned,
            actualElapsedPlayTime: outcome.elapsedPlayTime
        ), 30)
    }

    func testUncommittedRewardedHTMLNavigationFailureCannotEarnAfterDeferredTeardown() {
        var failure = RewardedHTMLTerminalFailureState()
        var terminal = DeferredTerminalState<RewardedTerminalOutcome>()
        var early = RewardedEarlyCompletionState()

        XCTAssertFalse(early.receive(
            signaled: true,
            primaryCreativeReady: false,
            rewardEarned: false
        ))
        XCTAssertTrue(early.pending)
        XCTAssertEqual(failure.terminalFailure(rewardAlreadyEarned: false), .terminate(earned: false))
        early.cancel()
        XCTAssertFalse(early.pending)
        XCTAssertFalse(early.receive(
            signaled: true,
            primaryCreativeReady: true,
            rewardEarned: false
        ))
        XCTAssertTrue(failure.gatePermanentlyIneligible)
        let outcome = RewardedTerminalOutcome(earned: false, elapsedPlayTime: 3)
        XCTAssertNil(terminal.request(outcome, blocked: true))
        XCTAssertFalse(shouldRunRewardedHTMLGate(
            appForegrounded: true,
            storeSheetPresented: false,
            rewardEarned: false,
            gatePermanentlyIneligible: failure.gatePermanentlyIneligible
        ))
        XCTAssertEqual(terminal.blockersDidChange(blocked: false), outcome)
        XCTAssertFalse(outcome.earned)
    }

    func testUncommittedRewardedHTMLReadinessTimeoutCannotEarn() {
        var deadline = RewardedHTMLReadinessDeadlineState(configuredCloseDelay: 0)
        var failure = RewardedHTMLTerminalFailureState()

        XCTAssertEqual(deadline.reconcile(now: 0, eligible: true), .schedule(10))
        XCTAssertEqual(deadline.deadlineFired(now: 10), .fail)
        XCTAssertEqual(failure.terminalFailure(rewardAlreadyEarned: false), .terminate(earned: false))
        XCTAssertFalse(shouldRunRewardedHTMLGate(
            appForegrounded: true,
            storeSheetPresented: false,
            rewardEarned: false,
            gatePermanentlyIneligible: failure.gatePermanentlyIneligible
        ))
    }

    func testCommittedRewardedHTMLFailurePreservesFailOpenRewardGate() {
        var failure = RewardedHTMLTerminalFailureState()
        var deadline = RewardedHTMLReadinessDeadlineState(configuredCloseDelay: 0)
        XCTAssertEqual(deadline.reconcile(now: 0, eligible: true), .schedule(10))
        XCTAssertTrue(failure.visualDidCommit())
        XCTAssertEqual(deadline.complete(now: 1), .cancel)

        XCTAssertEqual(failure.terminalFailure(rewardAlreadyEarned: false), .preserveFailOpen)
        XCTAssertEqual(deadline.deadlineFired(now: 10), .none)
        XCTAssertFalse(failure.gatePermanentlyIneligible)
        XCTAssertTrue(shouldRunRewardedHTMLGate(
            appForegrounded: true,
            storeSheetPresented: false,
            rewardEarned: false,
            gatePermanentlyIneligible: failure.gatePermanentlyIneligible
        ))
    }

    func testAlreadyEarnedEarlyCompleteSurvivesPrecommitRewardedHTMLFailure() {
        var early = RewardedEarlyCompletionState()
        var reward = RewardCompletionState()
        var failure = RewardedHTMLTerminalFailureState()

        XCTAssertTrue(early.receive(
            signaled: true,
            requiresCreativeReadiness: false,
            primaryCreativeReady: false,
            rewardEarned: false
        ))
        reward.earn(reason: .creativeCompleted)
        XCTAssertEqual(failure.terminalFailure(rewardAlreadyEarned: reward.earned), .terminate(earned: true))

        let outcome = rewardedTerminalOutcome(
            earned: reward.earned,
            actualElapsedPlayTime: 1,
            completionReason: reward.reason
        )
        XCTAssertTrue(outcome.earned)
        XCTAssertEqual(outcome.completionReason, .creativeCompleted)
    }

    func testRendererTerminationTelemetryOnlyAllowsSuccessfulRewardedHTMLCommit() {
        var failure = RewardedHTMLTerminalFailureState()

        XCTAssertEqual(
            legacyHTMLBillingCallbackAction(for: .webContentProcessTerminated),
            .telemetryOnly
        )
        XCTAssertFalse(failure.visualCommitted)
        XCTAssertTrue(failure.visualDidCommit())
        XCTAssertTrue(failure.visualCommitted)
        XCTAssertFalse(failure.gatePermanentlyIneligible)
    }

    func testFailedRendererRecoveryUsesCommitAwareRewardedHTMLPolicy() {
        var precommit = RewardedHTMLTerminalFailureState()
        XCTAssertEqual(
            legacyHTMLBillingCallbackAction(for: .webContentProcessTerminated),
            .telemetryOnly
        )
        XCTAssertEqual(precommit.terminalFailure(rewardAlreadyEarned: false), .terminate(earned: false))

        var postcommit = RewardedHTMLTerminalFailureState()
        XCTAssertTrue(postcommit.visualDidCommit())
        XCTAssertEqual(
            legacyHTMLBillingCallbackAction(for: .webContentProcessTerminated),
            .telemetryOnly
        )
        XCTAssertEqual(postcommit.terminalFailure(rewardAlreadyEarned: false), .preserveFailOpen)
    }

    func testTerminalUncommittedRewardedHTMLGateCannotRestartAfterBlockersChange() {
        var failure = RewardedHTMLTerminalFailureState()
        XCTAssertEqual(failure.terminalFailure(rewardAlreadyEarned: false), .terminate(earned: false))

        for (foregrounded, sheetPresented) in [(false, false), (true, true), (true, false)] {
            XCTAssertFalse(shouldRunRewardedHTMLGate(
                appForegrounded: foregrounded,
                storeSheetPresented: sheetPresented,
                rewardEarned: false,
                gatePermanentlyIneligible: failure.gatePermanentlyIneligible
            ))
        }
    }

    func testRewardedHTMLTerminalFailureAndDeferredCallbackRemainOneShot() {
        var failure = RewardedHTMLTerminalFailureState()
        var terminal = DeferredTerminalState<RewardedTerminalOutcome>()
        let outcome = RewardedTerminalOutcome(earned: false, elapsedPlayTime: 2)
        var callbackCount = 0

        XCTAssertEqual(failure.terminalFailure(rewardAlreadyEarned: false), .terminate(earned: false))
        XCTAssertEqual(failure.terminalFailure(rewardAlreadyEarned: false), .none)
        XCTAssertNil(terminal.request(outcome, blocked: true))
        if terminal.blockersDidChange(blocked: false) != nil { callbackCount += 1 }
        if terminal.blockersDidChange(blocked: false) != nil { callbackCount += 1 }
        if terminal.request(outcome, blocked: false) != nil { callbackCount += 1 }

        XCTAssertEqual(callbackCount, 1)
    }

    func testConfiguredGateVerificationUsesActualVisiblePlayback() {
        XCTAssertEqual(
            rewardVerificationElapsedPlayTime(
                earned: true,
                actualElapsedPlayTime: 34.5
            ),
            34.5
        )
    }

    func testShortVideoCompletionVerificationUsesActualVisiblePlayback() {
        XCTAssertEqual(
            rewardVerificationElapsedPlayTime(
                earned: true,
                actualElapsedPlayTime: 8
            ),
            8
        )
    }

    func testEarlyCompleteVerificationUsesActualVisiblePlayback() {
        XCTAssertEqual(
            rewardVerificationElapsedPlayTime(
                earned: true,
                actualElapsedPlayTime: 2.25
            ),
            2.25
        )
    }

    func testUnearnedOrNonFinitePlaybackNeverProducesVerificationEvidence() {
        XCTAssertNil(
            rewardVerificationElapsedPlayTime(
                earned: false,
                actualElapsedPlayTime: 30
            )
        )
        XCTAssertNil(rewardVerificationElapsedPlayTime(earned: true, actualElapsedPlayTime: .nan))
        XCTAssertEqual(rewardVerificationElapsedPlayTime(earned: true, actualElapsedPlayTime: -2), 0)
    }

    func testTerminalWaitsForClickHandoffAndCompletesExactlyOnce() {
        let outcome = RewardedTerminalOutcome(earned: true, elapsedPlayTime: 5)
        var state = DeferredTerminalState<RewardedTerminalOutcome>()

        XCTAssertNil(state.request(outcome, blocked: true))
        XCTAssertEqual(state.pending, outcome)
        XCTAssertNil(state.blockersDidChange(blocked: true))
        XCTAssertEqual(state.blockersDidChange(blocked: false), outcome)
        XCTAssertNil(state.blockersDidChange(blocked: false))
        XCTAssertNil(state.request(outcome, blocked: false))
    }

    func testTerminalWaitsForPresentedStoreSheetAfterHandoffClears() {
        let outcome = RewardedTerminalOutcome(earned: true, elapsedPlayTime: 3)
        var state = DeferredTerminalState<RewardedTerminalOutcome>()
        XCTAssertNil(state.request(outcome, blocked: true))
        // Persistence finished, but the route's sheet is still covering the creative.
        XCTAssertNil(state.blockersDidChange(blocked: true))
        XCTAssertEqual(state.blockersDidChange(blocked: false), outcome)
    }

    @MainActor
    func testRouteRegistersSheetBlockerBeforePersistenceHandoffRelease() {
        var clickHandoffPending = true
        var sheetPresented = false
        var terminal = DeferredTerminalState<Bool>()
        var consumedOutcome: Bool?
        XCTAssertNil(terminal.request(true, blocked: true))

        let execution = AttributionRouteExecution(
            isActive: { true },
            onUIHandoffReleased: {
                clickHandoffPending = false
                consumedOutcome = terminal.blockersDidChange(
                    blocked: clickHandoffPending || sheetPresented
                )
            },
            onOutcome: { _ in }
        )
        XCTAssertTrue(execution.begin(path: .directStore))
        execution.complete {
            // Mirrors the synchronous will-present notification emitted by StoreKit/Safari routes.
            sheetPresented = true
            return true
        }

        XCTAssertFalse(clickHandoffPending)
        XCTAssertTrue(sheetPresented)
        XCTAssertNil(consumedOutcome)

        sheetPresented = false
        consumedOutcome = terminal.blockersDidChange(
            blocked: clickHandoffPending || sheetPresented
        )
        XCTAssertEqual(consumedOutcome, true)
    }

    func testFirstVisualReadinessAdmitsDisplayAndBillingNeverAccruesOnBlackLoading() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertFalse(state.accrueImpression(deltaMs: 5_000, thresholdMs: 2_000))
        XCTAssertTrue(state.visualBecameReady())
        XCTAssertFalse(state.visualBecameReady())
        XCTAssertFalse(state.accrueImpression(deltaMs: 1_000, thresholdMs: 2_000))

        state.visualBecameUnavailable()
        XCTAssertFalse(state.accrueImpression(deltaMs: 5_000, thresholdMs: 2_000))

        XCTAssertEqual(state.finish(), .closed)
        // Parent accounting is terminal before fallbacks; even a stale reference cannot bill it.
        XCTAssertFalse(state.visualBecameReady())
        XCTAssertFalse(state.accrueImpression(deltaMs: 2_000, thresholdMs: 2_000))
        XCTAssertFalse(state.impressionCommitted)
    }

    func testBillingAdmissionPausesWhileExternalSurfaceBlocksCreative() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.visualBecameReady())
        state.setBlocked(true)
        XCTAssertFalse(state.accrueImpression(deltaMs: 3_000, thresholdMs: 2_000))
        state.setBlocked(false)
        XCTAssertTrue(state.accrueImpression(deltaMs: 2_000, thresholdMs: 2_000))
    }

    func testHTMLBillingDwellStartsAtPresentationButWaitsForMainFrameCommit() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.htmlPresentationDidSucceed())
        XCTAssertFalse(state.accrueImpression(deltaMs: 2_500, thresholdMs: 2_000))
        XCTAssertEqual(state.accruedImpressionMs, 2_500)
        XCTAssertFalse(state.impressionCommitted)
        XCTAssertTrue(state.htmlNavigationDidCommit(thresholdMs: 2_000))
        XCTAssertTrue(state.impressionCommitted)
    }

    func testHTMLCommitBeforeThresholdDoesNotRestartPresentationDwell() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.htmlPresentationDidSucceed())
        XCTAssertFalse(state.accrueImpression(deltaMs: 750, thresholdMs: 2_000))
        XCTAssertFalse(state.htmlNavigationDidCommit(thresholdMs: 2_000))
        XCTAssertTrue(state.accrueImpression(deltaMs: 1_250, thresholdMs: 2_000))
        XCTAssertEqual(state.accruedImpressionMs, 2_000)
    }

    func testHTMLNavigationFailurePermanentlySuppressesUncommittedBilling() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.htmlPresentationDidSucceed())
        XCTAssertFalse(state.accrueImpression(deltaMs: 1_500, thresholdMs: 2_000))
        state.htmlNavigationDidFail()

        XCTAssertFalse(state.impressionDwellEligible)
        XCTAssertFalse(state.htmlNavigationDidCommit(thresholdMs: 2_000))
        XCTAssertFalse(state.accrueImpression(deltaMs: 10_000, thresholdMs: 2_000))
        XCTAssertFalse(state.impressionCommitted)
    }

    func testHTMLNavigationFailureAfterBillingDoesNotUndoOneShotCommit() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.htmlPresentationDidSucceed())
        XCTAssertFalse(state.htmlNavigationDidCommit(thresholdMs: 2_000))
        XCTAssertTrue(state.accrueImpression(deltaMs: 2_000, thresholdMs: 2_000))
        state.htmlNavigationDidFail()

        XCTAssertTrue(state.impressionCommitted)
        XCTAssertFalse(state.accrueImpression(deltaMs: 2_000, thresholdMs: 2_000))
    }

    func testLegacyHTMLPresenterCallbackPolicyKeepsRendererTerminationTelemetryOnly() {
        XCTAssertEqual(
            legacyHTMLBillingCallbackAction(for: .mainFrameCommitted),
            .confirm
        )
        XCTAssertEqual(
            legacyHTMLBillingCallbackAction(for: .navigationFailed),
            .suppressUncommitted
        )
        XCTAssertEqual(
            legacyHTMLBillingCallbackAction(for: .webContentProcessTerminated),
            .telemetryOnly
        )
    }

    func testRendererTerminationTelemetryOnlyStillAllowsRecoveredCommitToBill() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.htmlPresentationDidSucceed())
        XCTAssertFalse(state.accrueImpression(deltaMs: 2_500, thresholdMs: 2_000))

        XCTAssertEqual(
            legacyHTMLBillingCallbackAction(for: .webContentProcessTerminated),
            .telemetryOnly
        )
        XCTAssertTrue(state.impressionDwellEligible)
        XCTAssertTrue(state.htmlNavigationDidCommit(thresholdMs: 2_000))
        XCTAssertTrue(state.impressionCommitted)
    }

    func testTerminalRecoveryFailureAfterRendererTerminationSuppressesUncommittedBilling() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.htmlPresentationDidSucceed())
        XCTAssertFalse(state.accrueImpression(deltaMs: 1_500, thresholdMs: 2_000))
        XCTAssertEqual(
            legacyHTMLBillingCallbackAction(for: .webContentProcessTerminated),
            .telemetryOnly
        )

        XCTAssertEqual(
            legacyHTMLBillingCallbackAction(for: .navigationFailed),
            .suppressUncommitted
        )
        state.htmlNavigationDidFail()
        XCTAssertFalse(state.htmlNavigationDidCommit(thresholdMs: 2_000))
        XCTAssertFalse(state.accrueImpression(deltaMs: 10_000, thresholdMs: 2_000))
        XCTAssertFalse(state.impressionCommitted)
    }

    func testImpressionDwellClockDropsPausedTimeAndReanchorsOnResume() {
        var clock = FullscreenImpressionDwellClock()
        clock.resume(at: 10)
        XCTAssertEqual(clock.settle(at: 10.25), 250, accuracy: 0.000_001)
        clock.pause()
        XCTAssertEqual(clock.settle(at: 100), 0)
        clock.resume(at: 200)
        XCTAssertEqual(clock.settle(at: 200.75), 750, accuracy: 0.000_001)
    }

    func testVideoDisappearReappearBeforeImpressionResumesRemainingDwellWithoutRedisplay() {
        var state = FullscreenVisualAdmissionState()
        var displayed = 0
        var shown = 0
        var impressions = 0
        var paid = 0

        if state.visualBecameReady() {
            displayed += 1
            shown += 1
        }
        XCTAssertFalse(state.accrueImpression(deltaMs: 600, thresholdMs: 1_000))
        state.visualBecameUnavailable()
        XCTAssertFalse(state.accrueImpression(deltaMs: 1_000, thresholdMs: 1_000))

        if state.visualBecameReady() {
            displayed += 1
            shown += 1
        }
        if state.accrueImpression(deltaMs: 400, thresholdMs: 1_000) {
            impressions += 1
            paid += 1
        }

        XCTAssertEqual(state.accruedImpressionMs, 1_000)
        XCTAssertEqual(displayed, 1)
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(impressions, 1)
        XCTAssertEqual(paid, 1)
    }

    func testVideoDisappearReappearAfterImpressionDoesNotRepeatAccounting() {
        var state = FullscreenVisualAdmissionState()
        var displayed = 0
        var impressions = 0

        if state.visualBecameReady() { displayed += 1 }
        if state.accrueImpression(deltaMs: 1_000, thresholdMs: 1_000) { impressions += 1 }
        state.visualBecameUnavailable()
        if state.visualBecameReady() { displayed += 1 }
        if state.accrueImpression(deltaMs: 1_000, thresholdMs: 1_000) { impressions += 1 }

        XCTAssertTrue(state.impressionCommitted)
        XCTAssertEqual(displayed, 1)
        XCTAssertEqual(impressions, 1)
    }

    func testVideoReappearanceWhileInactiveStaysBlockedUntilForeground() {
        var state = FullscreenVisualAdmissionState()

        XCTAssertTrue(state.visualBecameReady())
        XCTAssertFalse(state.accrueImpression(deltaMs: 400, thresholdMs: 1_000))
        state.visualBecameUnavailable()
        state.setBlocked(true)
        XCTAssertFalse(state.visualBecameReady())
        XCTAssertFalse(state.accrueImpression(deltaMs: 600, thresholdMs: 1_000))
        XCTAssertEqual(state.accruedImpressionMs, 400)

        state.setBlocked(false)
        XCTAssertTrue(state.accrueImpression(deltaMs: 600, thresholdMs: 1_000))
    }

    func testFailedEndedAndStoppedVideoDoNotReadmitAfterDisappear() {
        let player = NSObject()
        let identity = ObjectIdentifier(player)
        for (status, stopped) in [
            (FullscreenVideoStatus.failed(.playbackFailed), false),
            (.ended, false),
            (.paused, true),
        ] {
            XCTAssertFalse(shouldAcceptFullscreenVideoFirstFrameCallback(
                presentationActive: true,
                failureHandled: false,
                callbackPlayerIdentity: identity,
                currentPlayerIdentity: identity,
                status: status,
                isStopped: stopped
            ))
        }
    }

    func testReplacedVideoDoesNotReadmitUsingPreviousPlayersFirstFrame() {
        let admittedPlayer = NSObject()
        let replacementPlayer = NSObject()

        XCTAssertFalse(shouldAcceptFullscreenVideoFirstFrameCallback(
            presentationActive: true,
            failureHandled: false,
            callbackPlayerIdentity: ObjectIdentifier(admittedPlayer),
            currentPlayerIdentity: ObjectIdentifier(replacementPlayer),
            status: .playing,
            isStopped: false
        ))
    }

    func testFallbackTerminalAdvanceWaitsForHandoff() {
        var state = FallbackTerminalAdvanceState()
        XCTAssertFalse(state.request(index: 2, blocked: true))
        XCTAssertNil(state.blockersDidClear(currentIndex: 1))
        XCTAssertEqual(state.blockersDidClear(currentIndex: 2), 2)
        XCTAssertNil(state.blockersDidClear(currentIndex: 2))
        XCTAssertTrue(state.request(index: 3, blocked: false))
    }

    func testFallbackTerminalAdvanceAlsoWaitsForStoreSheet() {
        var state = FallbackTerminalAdvanceState()
        XCTAssertFalse(state.request(index: 0, blocked: true))
        XCTAssertNil(state.blockersDidClear(currentIndex: 1))
        XCTAssertEqual(state.blockersDidClear(currentIndex: 0), 0)
    }

    func testFallbackCountdownWaitsForRenderAdmissionAndEveryBlocker() {
        XCTAssertFalse(shouldRunFallbackCountdown(
            isVideo: false,
            pageFinished: false,
            hasAppeared: true,
            appForegrounded: true,
            storeSheetPresented: false
        ))
        XCTAssertFalse(shouldRunFallbackCountdown(
            isVideo: true,
            pageFinished: false,
            hasAppeared: true,
            appForegrounded: true,
            storeSheetPresented: false
        ))
        XCTAssertTrue(shouldRunFallbackCountdown(
            isVideo: false,
            pageFinished: true,
            hasAppeared: true,
            appForegrounded: true,
            storeSheetPresented: false
        ))
        XCTAssertFalse(shouldRunFallbackCountdown(
            isVideo: false,
            pageFinished: true,
            hasAppeared: true,
            appForegrounded: false,
            storeSheetPresented: false
        ))
        XCTAssertFalse(shouldRunFallbackCountdown(
            isVideo: false,
            pageFinished: true,
            hasAppeared: true,
            appForegrounded: true,
            storeSheetPresented: true
        ))
        XCTAssertFalse(shouldRunFallbackCountdown(
            isVideo: false,
            pageFinished: true,
            hasAppeared: true,
            appForegrounded: true,
            storeSheetPresented: false,
            clickHandoffPending: true
        ))
    }

    func testDeclarativeFallbackTerminalWaitsUntilEveryRouteBlockerClears() {
        var state = FallbackTerminalAdvanceState()
        let clickPending = true
        let sheetPresented = true
        XCTAssertFalse(state.request(index: 1, blocked: clickPending || sheetPresented))
        // Click persistence clearing is insufficient while the sheet remains presented.
        XCTAssertNotNil(state.pendingIndex)
        XCTAssertEqual(state.blockersDidClear(currentIndex: 1), 1)
    }

    @MainActor
    func testInflightFallbackPrefetchOwnershipCanTransferToLoadingPresenter() {
        let ownership = FallbackPrefetchOwnership()
        XCTAssertFalse(ownership.consumedByLoadingPresenter)
        ownership.transferToLoadingPresenter(windowInstalled: false)
        XCTAssertFalse(ownership.consumedByLoadingPresenter)
        ownership.transferToLoadingPresenter(windowInstalled: true)
        XCTAssertTrue(ownership.consumedByLoadingPresenter)
    }

    func testMiniGameFallbackFetchCancellationRejectsLateResultWithoutSideEffects() {
        var ownership = MiniGameFallbackFetchOwnership()
        let request = ownership.begin(serveId: "serve-a", menuId: "menu-a")
        var presentationSideEffects = 0

        let resolution = ownership.resolve(
            request,
            taskCancelled: true,
            currentServeId: "serve-a",
            currentMenuId: "menu-a"
        )
        if resolution == .apply { presentationSideEffects += 1 }

        XCTAssertEqual(resolution, .rejectCurrent)
        XCTAssertEqual(presentationSideEffects, 0)
        XCTAssertNil(ownership.activeRequest)
    }

    func testMiniGameFallbackFetchExplicitCancelMakesGenerationStale() {
        var ownership = MiniGameFallbackFetchOwnership()
        let request = ownership.begin(serveId: "serve-a", menuId: "menu-a")

        ownership.cancel()

        XCTAssertEqual(ownership.resolve(
            request,
            taskCancelled: false,
            currentServeId: "serve-a",
            currentMenuId: "menu-a"
        ), .stale)
        XCTAssertNil(ownership.activeRequest)
    }

    func testMiniGameFallbackFetchGenerationAndContextOwnResultApplication() {
        var ownership = MiniGameFallbackFetchOwnership()
        let superseded = ownership.begin(serveId: "serve-a", menuId: "menu-a")
        let current = ownership.begin(serveId: "serve-b", menuId: "menu-a")

        XCTAssertEqual(ownership.resolve(
            superseded,
            taskCancelled: false,
            currentServeId: "serve-b",
            currentMenuId: "menu-a"
        ), .stale)
        XCTAssertEqual(ownership.resolve(
            current,
            taskCancelled: false,
            currentServeId: "serve-b",
            currentMenuId: "menu-a"
        ), .apply)

        let wrongMenu = ownership.begin(serveId: "serve-c", menuId: "menu-a")
        XCTAssertEqual(ownership.resolve(
            wrongMenu,
            taskCancelled: false,
            currentServeId: "serve-c",
            currentMenuId: "menu-b"
        ), .rejectCurrent)
        XCTAssertNil(ownership.activeRequest)
    }

    func testMiniGameRetainedV2PresentationRecreatesScopeBeforeReconciliation() {
        let recovery = miniGameFallbackV2ScopeRecovery(
            showAdOverlay: true,
            containsVideoPlanV2: true,
            hasScope: false,
            currentAdUsesVideoPlanV2: true,
            ownsCurrentPlayer: false
        )

        XCTAssertTrue(recovery.createScope)
        XCTAssertFalse(recovery.reattachCurrentPlayer)
        XCTAssertEqual(miniGameFallbackVideoLifecycleAction(
            event: .appear,
            showAdOverlay: true,
            hasSelectedAd: true,
            selectedAdIsVideo: true,
            ownsCurrentPlayer: false
        ), .reconcile)
    }

    func testMiniGameRetainedV2PlayerIsReattachedWithoutReconciliation() {
        let recovery = miniGameFallbackV2ScopeRecovery(
            showAdOverlay: true,
            containsVideoPlanV2: true,
            hasScope: false,
            currentAdUsesVideoPlanV2: true,
            ownsCurrentPlayer: true
        )

        XCTAssertTrue(recovery.createScope)
        XCTAssertTrue(recovery.reattachCurrentPlayer)
        XCTAssertEqual(miniGameFallbackVideoLifecycleAction(
            event: .appear,
            showAdOverlay: true,
            hasSelectedAd: true,
            selectedAdIsVideo: true,
            ownsCurrentPlayer: true
        ), .none)
    }

    func testMiniGameScopeRecoveryIgnoresNonV2AndInactivePresentations() {
        XCTAssertEqual(miniGameFallbackV2ScopeRecovery(
            showAdOverlay: false,
            containsVideoPlanV2: true,
            hasScope: false,
            currentAdUsesVideoPlanV2: true,
            ownsCurrentPlayer: true
        ), MiniGameFallbackV2ScopeRecovery(createScope: false, reattachCurrentPlayer: false))
        XCTAssertEqual(miniGameFallbackV2ScopeRecovery(
            showAdOverlay: true,
            containsVideoPlanV2: false,
            hasScope: false,
            currentAdUsesVideoPlanV2: false,
            ownsCurrentPlayer: true
        ), MiniGameFallbackV2ScopeRecovery(createScope: false, reattachCurrentPlayer: false))
    }

    #if os(iOS)
    @MainActor
    func testMiniGameReattachedV2PlayerPreservesMuteAndRestoresTerminalClaims() {
        let events: [VideoPlanTerminalEvent] = [.completion, .failure, .userClose]
        for (index, event) in events.enumerated() {
            let player = FullscreenVideoPlayer(
                url: URL(fileURLWithPath: "/dev/null"),
                posterURL: nil,
                startsMuted: index.isMultiple(of: 2),
                stallTimeout: FullscreenVideoPlayer.videoPlanV2StallTimeout
            )
            let expectedMuted = player.isMuted
            let scope = VideoPlanPresentationScope()

            reattachMiniGameFallbackV2Player(player, to: scope)

            XCTAssertEqual(scope.isMuted, expectedMuted)
            XCTAssertEqual(player.isMuted, expectedMuted)
            XCTAssertTrue(scope.claimVideoTerminal(
                playerID: player.videoPlanPresentationID,
                event: event
            ))
            XCTAssertFalse(scope.claimVideoTerminal(
                playerID: player.videoPlanPresentationID,
                event: event
            ))
            scope.cancel()
            player.stop()
        }
    }
    #endif

    @MainActor
    func testMiniGameFallbackVideoReacquiresOnceAfterDisappearReappear() {
        final class Resource {}
        var factoryCalls = 0
        var stopCalls = 0
        func makeOwnership() -> FallbackVideoOwnership<Resource, String> {
            FallbackVideoOwnership(
                token: nil,
                claim: { _ in nil },
                discardUnclaimed: { _ in },
                makeCold: { factoryCalls += 1; return Resource() },
                releaseClaimed: { _ in },
                stopCold: { _ in stopCalls += 1 }
            )
        }

        var ownership: FallbackVideoOwnership<Resource, String>? = makeOwnership()
        let firstPlayer = ownership?.resource
        XCTAssertEqual(miniGameFallbackVideoLifecycleAction(
            event: .appear,
            showAdOverlay: true,
            hasSelectedAd: true,
            selectedAdIsVideo: true,
            ownsCurrentPlayer: ownership?.resource != nil
        ), .none)

        let disappearAction = miniGameFallbackVideoLifecycleAction(
            event: .disappear,
            showAdOverlay: true,
            hasSelectedAd: true,
            selectedAdIsVideo: true,
            ownsCurrentPlayer: ownership?.resource != nil
        )
        XCTAssertEqual(disappearAction, .release)
        if disappearAction == .release {
            ownership?.release()
            ownership = nil
        }

        let reappearAction = miniGameFallbackVideoLifecycleAction(
            event: .appear,
            showAdOverlay: true,
            hasSelectedAd: true,
            selectedAdIsVideo: true,
            ownsCurrentPlayer: false
        )
        XCTAssertEqual(reappearAction, .reconcile)
        if reappearAction == .reconcile { ownership = makeOwnership() }

        let reappearedPlayer = retainedFallbackVideoResource(
            requestedIndex: 1,
            ownershipIndex: 1,
            resource: ownership?.resource
        )
        let rebuiltPlayer = retainedFallbackVideoResource(
            requestedIndex: 1,
            ownershipIndex: 1,
            resource: ownership?.resource
        )
        XCTAssertFalse(firstPlayer === reappearedPlayer)
        XCTAssertTrue(reappearedPlayer === rebuiltPlayer)
        XCTAssertNil(retainedFallbackVideoResource(
            requestedIndex: 2,
            ownershipIndex: 1,
            resource: ownership?.resource
        ))
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(stopCalls, 1)
        XCTAssertEqual(miniGameFallbackVideoLifecycleAction(
            event: .appear,
            showAdOverlay: true,
            hasSelectedAd: true,
            selectedAdIsVideo: true,
            ownsCurrentPlayer: ownership?.resource != nil
        ), .none)

        ownership?.release()
        XCTAssertEqual(stopCalls, 2)
    }

    @MainActor
    func testFallbackVideoOwnershipUsesColdPlayerWhenTokenIsMissing() {
        final class Resource {}
        let cold = Resource()
        var factoryCalls = 0
        var stopCalls = 0
        let ownership = FallbackVideoOwnership<Resource, String>(
            token: nil,
            claim: { _ in XCTFail("A missing token must not be claimed"); return nil },
            discardUnclaimed: { _ in XCTFail("A missing token has nothing to discard") },
            makeCold: { factoryCalls += 1; return cold },
            releaseClaimed: { _ in XCTFail("A cold player must not release a pool claim") },
            stopCold: { resource in
                XCTAssertTrue(resource === cold)
                stopCalls += 1
            }
        )

        XCTAssertTrue(ownership.resource === cold)
        XCTAssertEqual(factoryCalls, 1)
        ownership.release()
        ownership.release()
        XCTAssertEqual(stopCalls, 1)
    }

    @MainActor
    func testFallbackVideoOwnershipUsesColdPlayerWhenClaimFails() {
        final class Resource {}
        let cold = Resource()
        var discardedTokens: [String] = []
        var pooledReleaseCalls = 0
        var stopCalls = 0
        let ownership = FallbackVideoOwnership<Resource, String>(
            token: "prepared",
            claim: { token in
                XCTAssertEqual(token, "prepared")
                return nil
            },
            discardUnclaimed: { discardedTokens.append($0) },
            makeCold: { cold },
            releaseClaimed: { _ in pooledReleaseCalls += 1 },
            stopCold: { _ in stopCalls += 1 }
        )

        XCTAssertTrue(ownership.resource === cold)
        XCTAssertEqual(discardedTokens, ["prepared"])
        ownership.release()
        ownership.release()
        XCTAssertEqual(pooledReleaseCalls, 0)
        XCTAssertEqual(stopCalls, 1)
    }

    @MainActor
    func testFallbackVideoOwnershipReusesClaimAcrossViewRebuildsAndReleasesOnce() {
        final class Resource {}
        let pooled = Resource()
        var claimCalls = 0
        var factoryCalls = 0
        var releasedTokens: [String] = []
        var stopCalls = 0
        let ownership = FallbackVideoOwnership<Resource, String>(
            token: "prepared",
            claim: { _ in claimCalls += 1; return pooled },
            discardUnclaimed: { _ in XCTFail("A claimed token must not be discarded") },
            makeCold: { factoryCalls += 1; return Resource() },
            releaseClaimed: { releasedTokens.append($0) },
            stopCold: { _ in stopCalls += 1 }
        )

        let firstBuild = retainedFallbackVideoResource(
            requestedIndex: 0,
            ownershipIndex: 0,
            resource: ownership.resource
        )
        let secondBuild = retainedFallbackVideoResource(
            requestedIndex: 0,
            ownershipIndex: 0,
            resource: ownership.resource
        )
        XCTAssertTrue(firstBuild === pooled)
        XCTAssertTrue(secondBuild === pooled)
        XCTAssertNil(retainedFallbackVideoResource(
            requestedIndex: 1,
            ownershipIndex: 0,
            resource: ownership.resource
        ))
        XCTAssertEqual(claimCalls, 1)
        XCTAssertEqual(factoryCalls, 0)
        ownership.release()
        ownership.release()
        XCTAssertEqual(releasedTokens, ["prepared"])
        XCTAssertEqual(stopCalls, 0)
    }

    @MainActor
    func testFallbackVideoOwnershipOffMainDeinitCleansUpOnceOnMain() async {
        final class Resource {}
        let cleanupRan = expectation(description: "cleanup ran")
        let backgroundReleaseFinished = expectation(description: "background release finished")
        let observation = LockedCleanupObservation()
        var ownership: FallbackVideoOwnership<Resource, String>? = FallbackVideoOwnership(
            token: nil,
            claim: { _ in nil },
            discardUnclaimed: { _ in },
            makeCold: { Resource() },
            releaseClaimed: { _ in },
            stopCold: { _ in
                observation.record()
                cleanupRan.fulfill()
            }
        )
        let releaseBox = BackgroundReleaseBox(ownership)
        ownership = nil

        DispatchQueue.global(qos: .userInitiated).async {
            releaseBox.release()
            backgroundReleaseFinished.fulfill()
        }

        await fulfillment(
            of: [backgroundReleaseFinished, cleanupRan],
            timeout: TestWait.timeout
        )
        let snapshot = observation.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertTrue(snapshot.allOnMain)
    }

    @MainActor
    func testFallbackVideoOwnershipExplicitReleaseThenOffMainDeinitDoesNotRepeatCleanup() async {
        final class Resource {}
        let backgroundReleaseFinished = expectation(description: "background release finished")
        let mainQueueDrained = expectation(description: "main queue drained")
        let observation = LockedCleanupObservation()
        var ownership: FallbackVideoOwnership<Resource, String>? = FallbackVideoOwnership(
            token: nil,
            claim: { _ in nil },
            discardUnclaimed: { _ in },
            makeCold: { Resource() },
            releaseClaimed: { _ in },
            stopCold: { _ in observation.record() }
        )
        ownership?.release()
        let releaseBox = BackgroundReleaseBox(ownership)
        ownership = nil

        DispatchQueue.global(qos: .userInitiated).async {
            releaseBox.release()
            DispatchQueue.main.async { mainQueueDrained.fulfill() }
            backgroundReleaseFinished.fulfill()
        }

        await fulfillment(
            of: [backgroundReleaseFinished, mainQueueDrained],
            timeout: TestWait.timeout
        )
        let snapshot = observation.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertTrue(snapshot.allOnMain)
    }

    @MainActor
    func testFallbackVideoOwnershipOffMainClaimedResourceLivesThroughMainCleanup() async {
        final class Resource {
            let onDeinit: () -> Void
            init(onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }

        let cleanup = expectation(description: "claimed cleanup on main")
        let resourceDeinit = expectation(description: "claimed resource deinit on main")
        var ownership: FallbackVideoOwnership<Resource, String>? = FallbackVideoOwnership(
            token: "token",
            claim: { _ in
                Resource {
                    XCTAssertTrue(Thread.isMainThread)
                    resourceDeinit.fulfill()
                }
            },
            discardUnclaimed: { _ in },
            makeCold: { Resource(onDeinit: {}) },
            releaseClaimed: { _ in
                XCTAssertTrue(Thread.isMainThread)
                cleanup.fulfill()
            },
            stopCold: { _ in }
        )

        let releaseBox = BackgroundReleaseBox(ownership)
        ownership = nil
        await Task.detached { releaseBox.release() }.value

        await fulfillment(of: [cleanup, resourceDeinit], timeout: TestWait.timeout)
    }

    func testPreparedPlayerRetentionIsBoundedAndNeverEvictsActiveEntry() {
        let policy = VideoPreparationRetentionPolicy(capacity: 2, retention: 300)
        let active = UUID()
        let idle = UUID()
        let entries = [
            VideoPreparationRetentionPolicy.Entry(id: active, active: true, lastTouched: 0),
            VideoPreparationRetentionPolicy.Entry(id: idle, active: false, lastTouched: 10),
        ]
        XCTAssertEqual(policy.evictionCandidate(entries), idle)
        XCTAssertEqual(policy.expiredEntryIDs(entries, now: 311), [idle])
        XCTAssertNil(policy.evictionCandidate([
            .init(id: UUID(), active: true, lastTouched: 0),
            .init(id: UUID(), active: true, lastTouched: 1),
        ]))
    }

    func testVideoPromptCannotAppearAtOrAfterDismissUnlock() {
        XCTAssertTrue(shouldShowVideoStorePrompt(
            enabled: true,
            reachedMidpoint: true,
            dismissUnlocked: false
        ))
        XCTAssertFalse(shouldShowVideoStorePrompt(
            enabled: true,
            reachedMidpoint: true,
            dismissUnlocked: true
        ))
    }

    func testVideoClockDoesNotAccrueBeforeFirstVisualFrame() {
        var clock = VideoVisiblePlaybackClock()
        XCTAssertEqual(clock.update(mediaTime: 4), 0)
        XCTAssertEqual(clock.playedSeconds, 0)
        clock.admitFirstFrame(mediaTime: 4)
        XCTAssertEqual(clock.update(mediaTime: 4.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(clock.update(mediaTime: 4.25), 0.5, accuracy: 0.001)
        XCTAssertEqual(clock.update(mediaTime: 4.5), 0.75, accuracy: 0.001)
    }

    func testNonfiniteFirstFrameAnchorsAtFirstLaterFinitePeriodicSample() {
        for invalidFirstFrame in [Double.nan, .infinity, -.infinity] {
            var clock = VideoVisiblePlaybackClock()
            clock.admitFirstFrame(mediaTime: invalidFirstFrame)
            XCTAssertNil(clock.firstFrameMediaTime)
            XCTAssertEqual(clock.update(mediaTime: .infinity), 0)
            XCTAssertEqual(clock.update(mediaTime: 8), 0)
            XCTAssertEqual(clock.firstFrameMediaTime, 8)
            XCTAssertEqual(clock.update(mediaTime: 8.75), 0.75, accuracy: 0.001)
        }
    }

    func testLateFiniteAnchorPreservesVisibleCompletionAcrossBackwardSeek() {
        var clock = VideoVisiblePlaybackClock()
        clock.admitFirstFrame(mediaTime: .nan)
        XCTAssertEqual(clock.update(mediaTime: 5), 0)
        XCTAssertEqual(clock.update(mediaTime: 6), 1)
        XCTAssertEqual(clock.update(mediaTime: 2), 1)
        XCTAssertEqual(clock.update(mediaTime: 2.5), 1.5)
        XCTAssertEqual(clock.update(mediaTime: 3), 2)
    }

    func testFirstFrameDeadlineFailsOnceAndCannotAdmitAfterTimeout() {
        var state = VideoFirstFrameDeadlineState()
        XCTAssertTrue(state.arm())
        XCTAssertTrue(state.timeout())
        XCTAssertFalse(state.timeout())
        XCTAssertFalse(state.admit())
        XCTAssertTrue(state.failed)
    }

    func testFirstFrameAdmissionCancelsDeadlineOwnership() {
        var state = VideoFirstFrameDeadlineState()
        XCTAssertTrue(state.arm())
        XCTAssertTrue(state.admit())
        XCTAssertFalse(state.timeout())
        XCTAssertTrue(state.admitted)
    }

    func testLateFirstFrameCallbackIsRejectedAfterFailure() {
        var state = VideoFirstFrameDeadlineState()
        XCTAssertTrue(state.arm())
        state.fail()
        XCTAssertFalse(state.admit())
        XCTAssertFalse(state.admitted)
    }

    func testShortVideoEndWaitsForRealLayerReadiness() {
        var state = VideoFirstFrameDeadlineState()
        XCTAssertTrue(state.arm())
        XCTAssertTrue(state.deferEndUntilFrame())
        XCTAssertTrue(state.pendingEnd)
        XCTAssertTrue(state.admit())
        XCTAssertTrue(state.consumePendingEnd())
        XCTAssertFalse(state.pendingEnd)
    }

    func testPendingShortVideoEndFailsIfGraceExpiresWithoutFrame() {
        var state = VideoFirstFrameDeadlineState()
        XCTAssertTrue(state.deferEndUntilFrame())
        state.fail()
        XCTAssertFalse(state.pendingEnd)
        XCTAssertFalse(state.admit())
    }

    func testPrimaryVideoControlsRequireFrameAndDisplayAdmission() {
        XCTAssertFalse(canUseVideoControls(firstFrameAdmitted: false, displayAdmitted: false))
        XCTAssertFalse(canUseVideoControls(firstFrameAdmitted: true, displayAdmitted: false))
        XCTAssertFalse(canUseVideoControls(firstFrameAdmitted: false, displayAdmitted: true))
        XCTAssertTrue(canUseVideoControls(firstFrameAdmitted: true, displayAdmitted: true))
    }

    func testPreFirstFrameEscapeRoutesEachSurfaceAsCanonicalUserClose() {
        XCTAssertEqual(videoPreFirstFrameEscapeDecision(
            surface: .interstitial,
            presentationMounted: true,
            firstFrameAdmitted: false,
            terminal: false
        ), VideoPreFirstFrameEscapeDecision(
            action: .failInterstitialDisplay,
            terminalEvent: .userClose,
            telemetryStage: FullscreenVideoTelemetryStage.close,
            telemetryReason: FullscreenVideoTerminationReason.user
        ))
        XCTAssertEqual(videoPreFirstFrameEscapeDecision(
            surface: .rewarded,
            presentationMounted: true,
            firstFrameAdmitted: false,
            terminal: false
        ), VideoPreFirstFrameEscapeDecision(
            action: .finishRewardedUnearned,
            terminalEvent: .userClose,
            telemetryStage: FullscreenVideoTelemetryStage.close,
            telemetryReason: FullscreenVideoTerminationReason.user
        ))
        XCTAssertEqual(videoPreFirstFrameEscapeDecision(
            surface: .fallback,
            presentationMounted: true,
            firstFrameAdmitted: false,
            terminal: false
        ), VideoPreFirstFrameEscapeDecision(
            action: .requestFallbackFailureAdvance,
            terminalEvent: .userClose,
            telemetryStage: FullscreenVideoTelemetryStage.close,
            telemetryReason: FullscreenVideoTerminationReason.user
        ))
    }

    func testPreFirstFrameEscapeRejectsUnmountedTerminalAndStalePostFrameTaps() {
        XCTAssertEqual(videoPreFirstFrameEscapeAction(
            surface: .interstitial,
            presentationMounted: false,
            firstFrameAdmitted: false,
            terminal: false
        ), .none)
        XCTAssertEqual(videoPreFirstFrameEscapeAction(
            surface: .rewarded,
            presentationMounted: true,
            firstFrameAdmitted: false,
            terminal: true
        ), .none)
        XCTAssertEqual(videoPreFirstFrameEscapeAction(
            surface: .fallback,
            presentationMounted: true,
            firstFrameAdmitted: true,
            terminal: false
        ), .none)
        XCTAssertFalse(shouldShowVideoPreFirstFrameEscape(
            firstFrameAdmitted: true,
            terminal: false
        ))
    }

    func testPreFirstFrameChromeShowsExactlyOneCloseAction() {
        XCTAssertEqual(
            videoPreFirstFrameChromeVisibility(
                hasVideo: false,
                firstFrameAdmitted: false,
                terminal: false
            ),
            .init(showsEscape: false, showsServerControl: true)
        )
        XCTAssertEqual(
            videoPreFirstFrameChromeVisibility(
                hasVideo: true,
                firstFrameAdmitted: false,
                terminal: false
            ),
            .init(showsEscape: true, showsServerControl: false)
        )
        XCTAssertEqual(
            videoPreFirstFrameChromeVisibility(
                hasVideo: true,
                firstFrameAdmitted: true,
                terminal: false
            ),
            .init(showsEscape: false, showsServerControl: true)
        )
        XCTAssertEqual(
            videoPreFirstFrameChromeVisibility(
                hasVideo: true,
                firstFrameAdmitted: false,
                terminal: true
            ),
            .init(showsEscape: false, showsServerControl: false)
        )
    }

    func testCompletedVideoRestoresServerCloseWhileFailureHidesAllChrome() {
        let ended = videoPreFirstFrameChromeVisibility(
            hasVideo: true,
            firstFrameAdmitted: true,
            terminal: FullscreenVideoStatus.ended.isFailure
        )
        XCTAssertFalse(ended.showsEscape)
        XCTAssertTrue(ended.showsServerControl)

        let failed = videoPreFirstFrameChromeVisibility(
            hasVideo: true,
            firstFrameAdmitted: true,
            terminal: FullscreenVideoStatus.failed(.playbackFailed).isFailure
        )
        XCTAssertFalse(failed.showsEscape)
        XCTAssertFalse(failed.showsServerControl)
    }

    func testInterstitialPreFrameTerminalMapsToDisplayFailureWithoutPostPrimaryCallbacks() {
        XCTAssertEqual(videoPreFirstFrameEscapeAction(
            surface: .interstitial,
            presentationMounted: true,
            firstFrameAdmitted: false,
            terminal: false
        ), .failInterstitialDisplay)
        var admission = FullscreenVisualAdmissionState()
        let outcome = admission.finish()
        let policy = outcome.map { FullscreenPostPrimaryPolicy(terminalOutcome: $0) }

        XCTAssertEqual(outcome, .displayFailed)
        XCTAssertFalse(policy?.presentsFallbacks == true)
        XCTAssertFalse(policy?.notifiesPublisherClose == true)
    }

    func testFallbackPreFrameTerminalRequestsOneDeferredFailureAdvance() {
        XCTAssertEqual(videoPreFirstFrameEscapeAction(
            surface: .fallback,
            presentationMounted: true,
            firstFrameAdmitted: false,
            terminal: false
        ), .requestFallbackFailureAdvance)
        var handoff = PendingFirstFrameHandoff<String>()
        handoff.activate("current-player")
        var advance = FallbackTerminalAdvanceState()

        XCTAssertTrue(handoff.claimPreFirstFrameFailure("current-player"))
        XCTAssertFalse(advance.request(index: 1, blocked: true))
        XCTAssertFalse(handoff.claimPreFirstFrameFailure("current-player"))
        XCTAssertEqual(advance.blockersDidClear(currentIndex: 1), 1)
        XCTAssertNil(advance.blockersDidClear(currentIndex: 1))
    }

    func testRewardedPreFrameCancellationIsUnearnedZeroTimeWithoutVerificationOrClosePolicy() {
        let outcome = rewardedTerminalOutcome(
            earned: false,
            actualElapsedPlayTime: 0,
            completionReason: .videoCompleted
        )
        let policy = FullscreenPostPrimaryPolicy(
            terminalOutcome: .displayFailed,
            earnedReward: outcome.earned
        )

        XCTAssertFalse(outcome.earned)
        XCTAssertEqual(outcome.elapsedPlayTime, 0)
        XCTAssertNil(outcome.completionReason)
        XCTAssertNil(rewardVerificationElapsedPlayTime(
            earned: outcome.earned,
            actualElapsedPlayTime: outcome.elapsedPlayTime
        ))
        XCTAssertFalse(policy.presentsFallbacks)
        XCTAssertFalse(policy.notifiesPublisherClose)
        XCTAssertFalse(policy.verifiesEarnedReward)
    }

    func testMutedAudioTrackPolicyDisablesOnlyAudioAndPreservesOriginalState() {
        var policy = VideoAudioTrackPolicy<String>()
        let commands = policy.prepareMutedPlayback(tracks: [
            .init(id: "enabled-audio", isAudio: true, isEnabled: true),
            .init(id: "disabled-audio", isAudio: true, isEnabled: false),
            .init(id: "video", isAudio: false, isEnabled: true),
        ])

        XCTAssertEqual(commands, [.init(id: "enabled-audio", isEnabled: false)])
        XCTAssertEqual(policy.originalEnabled, [
            "enabled-audio": true,
            "disabled-audio": false,
        ])
    }

    func testMutedAudioTrackPolicyRestoresRemovedTrackBeforeCapturingReplacementBaseline() {
        var policy = VideoAudioTrackPolicy<String>()
        _ = policy.prepareMutedPlayback(tracks: [
            .init(id: "old", isAudio: true, isEnabled: true),
        ])
        let commands = policy.tracksDidChange([
            .init(id: "replacement", isAudio: true, isEnabled: true),
        ])

        XCTAssertEqual(commands, [
            .init(id: "old", isEnabled: true),
            .init(id: "replacement", isEnabled: false),
        ])
        XCTAssertEqual(policy.originalEnabled, ["replacement": true])
    }

    func testMediaSelectionNotificationCannotOverwriteSDKDisabledBaseline() {
        var policy = VideoAudioTrackPolicy<String>()
        XCTAssertEqual(policy.prepareMutedPlayback(tracks: [
            .init(id: "A", isAudio: true, isEnabled: true),
        ]), [.init(id: "A", isEnabled: false)])

        XCTAssertTrue(policy.tracksDidChange([
            .init(id: "A", isAudio: true, isEnabled: false),
        ]).isEmpty)
        XCTAssertEqual(policy.originalEnabled, ["A": true])

        XCTAssertEqual(policy.unmute(tracks: [
            .init(id: "A", isAudio: true, isEnabled: false),
        ]), [.init(id: "A", isEnabled: true)])
    }

    func testTrackListChangePreservesExistingBaselineAndCapturesOnlyNewTrack() {
        var policy = VideoAudioTrackPolicy<String>()
        _ = policy.prepareMutedPlayback(tracks: [
            .init(id: "A", isAudio: true, isEnabled: true),
        ])

        XCTAssertEqual(policy.tracksDidChange([
            .init(id: "A", isAudio: true, isEnabled: false),
            .init(id: "B", isAudio: true, isEnabled: true),
        ]), [.init(id: "B", isEnabled: false)])
        XCTAssertEqual(policy.originalEnabled, ["A": true, "B": true])
    }

    func testStrongGeneratedTrackRecordsDoNotTransferBaselineToReplacementObject() throws {
        final class Track {
            let onDeinit: () -> Void
            init(onDeinit: @escaping () -> Void = {}) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }
        var records = StrongVideoAudioTrackRecords<Track>()
        var oldTrackReleases = 0
        var oldTrack: Track? = Track { oldTrackReleases += 1 }
        let oldID = records.id(for: try XCTUnwrap(oldTrack))
        records.retain(ids: [oldID])
        oldTrack = nil
        XCTAssertEqual(oldTrackReleases, 0)

        let replacement = Track()
        let replacementID = records.id(for: replacement)
        XCTAssertNotEqual(oldID, replacementID)
        XCTAssertFalse(records.track(for: oldID) === replacement)
        XCTAssertTrue(records.track(for: replacementID) === replacement)

        records.retain(ids: [replacementID])
        XCTAssertEqual(oldTrackReleases, 1)
        XCTAssertNil(records.track(for: oldID))
        XCTAssertEqual(records.count, 1)
    }

    func testExplicitUnmuteRestoresRecordedCurrentStatesExactlyOnce() {
        var policy = VideoAudioTrackPolicy<String>()
        _ = policy.prepareMutedPlayback(tracks: [
            .init(id: "originally-enabled", isAudio: true, isEnabled: true),
            .init(id: "originally-disabled", isAudio: true, isEnabled: false),
        ])
        let commands = policy.unmute(tracks: [
            .init(id: "originally-enabled", isAudio: true, isEnabled: false),
            .init(id: "originally-disabled", isAudio: true, isEnabled: false),
        ])

        XCTAssertEqual(commands, [.init(id: "originally-enabled", isEnabled: true)])
        XCTAssertFalse(policy.isMuted)
        XCTAssertTrue(policy.originalEnabled.isEmpty)
        XCTAssertTrue(policy.tracksDidChange([
            .init(id: "new", isAudio: true, isEnabled: false),
        ]).isEmpty, "Lifecycle/media-selection changes must never enable tracks while unmuted")
        XCTAssertTrue(policy.unmute(tracks: []).isEmpty)
    }

    func testRemuteRecordsCurrentStateAndDisablesBeforePlayback() {
        var policy = VideoAudioTrackPolicy<String>()
        _ = policy.unmute(tracks: [])
        let commands = policy.remute(tracks: [
            .init(id: "audio", isAudio: true, isEnabled: true),
        ])

        XCTAssertTrue(policy.isMuted)
        XCTAssertEqual(commands, [.init(id: "audio", isEnabled: false)])
        XCTAssertEqual(policy.originalEnabled, ["audio": true])
    }

    func testDisplayOutcomeFailsExactlyOnceWhenNothingWasAdmitted() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertEqual(state.finish(), .displayFailed)
        XCTAssertNil(state.finish())
        XCTAssertFalse(state.visualBecameReady())
        XCTAssertEqual(state.displayOutcome, .failed)
        XCTAssertFalse(state.visualActive)
    }

    func testAdmittedDisplayCanNeverBecomeDisplayFailed() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.visualBecameReady())
        XCTAssertEqual(state.finish(), .closed)
        XCTAssertNil(state.finish())
        XCTAssertEqual(state.displayOutcome, .displayed)
    }

    func testDisplayFailureSkipsFallbackCloseAndReward() {
        let policy = FullscreenPostPrimaryPolicy(
            terminalOutcome: .displayFailed,
            earnedReward: true
        )
        var callbacks: [String] = []
        if policy.presentsFallbacks { callbacks.append("fallback") }
        if policy.notifiesPublisherClose { callbacks.append("close") }
        if policy.verifiesEarnedReward { callbacks.append("reward") }
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testFullscreenPresenterInitialBlockerIncludesInactiveAppAndExistingSheet() {
        XCTAssertFalse(fullscreenPresentationBlocked(
            appForegrounded: true,
            storeSheetPresented: false
        ))
        XCTAssertTrue(fullscreenPresentationBlocked(
            appForegrounded: false,
            storeSheetPresented: false
        ))
        XCTAssertTrue(fullscreenPresentationBlocked(
            appForegrounded: true,
            storeSheetPresented: true
        ))
    }

    func testAdmittedClosePresentsFallbackThenPublishesClose() {
        let policy = FullscreenPostPrimaryPolicy(terminalOutcome: .closed, earnedReward: true)
        var callbacks: [String] = []
        if policy.presentsFallbacks { callbacks.append("fallback") }
        if policy.notifiesPublisherClose { callbacks.append("close") }
        if policy.verifiesEarnedReward { callbacks.append("reward") }
        XCTAssertEqual(callbacks, ["fallback", "close", "reward"])
    }

    func testNativeVideoTapWithoutRoutableDestinationIsNotAdmitted() {
        XCTAssertFalse(hasRoutableVideoDestination(
            trackingUrl: nil,
            destination: .web,
            storeUrl: nil
        ))
        XCTAssertFalse(hasRoutableVideoDestination(
            trackingUrl: "file:///tmp/click",
            destination: .appstore,
            storeUrl: "https://example.com/no-id"
        ))
        XCTAssertTrue(hasRoutableVideoDestination(
            trackingUrl: "https://tracker.example/click",
            destination: .web,
            storeUrl: nil
        ))
        XCTAssertTrue(hasRoutableVideoDestination(
            trackingUrl: nil,
            destination: .appstore,
            storeUrl: "https://apps.apple.com/app/id123456"
        ))
    }

    func testVideoTelemetryStageNamesMatchCrossPlatformContract() {
        XCTAssertEqual(FullscreenVideoTelemetryStage.start, "video_start")
        XCTAssertEqual(FullscreenVideoTelemetryStage.complete, "video_complete")
        XCTAssertEqual(FullscreenVideoTelemetryStage.fail, "video_fail")
    }

    #if os(iOS)
    @MainActor
    func testInjectedClockExcludesBlockedSleeperGapAndCommitsImpressionOnce() {
        let clock = TestUptime(10)
        let owner = FullscreenVisualSurfaceToken()
        var displayed = 0
        var impressions = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: { displayed += 1 },
            onImpression: { impressions += 1 },
            impressionDelayMs: 1_000,
            tickNanos: 60_000_000_000,
            uptime: { clock.now },
            initialApplicationActive: true
        )

        admission.visualBecameReady(owner: owner)
        clock.now = 10.4
        admission.setBlocked(true)
        clock.now = 100
        admission.setBlocked(false)
        clock.now = 100.59
        admission.setBlocked(true)
        XCTAssertEqual(impressions, 0)
        clock.now = 500
        admission.setBlocked(false)
        clock.now = 500.02
        admission.setBlocked(true)
        XCTAssertEqual(impressions, 1)

        clock.now = 900
        admission.setBlocked(false)
        clock.now = 1_000
        admission.setBlocked(true)
        XCTAssertEqual(displayed, 1)
        XCTAssertEqual(impressions, 1)
        admission.stop()
    }

    @MainActor
    func testInjectedClockExcludesDisappearedGapAndResumesRemainingDwell() {
        let clock = TestUptime(0)
        let owner = FullscreenVisualSurfaceToken()
        var displayed = 0
        var impressions = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: { displayed += 1 },
            onImpression: { impressions += 1 },
            impressionDelayMs: 1_000,
            tickNanos: 60_000_000_000,
            uptime: { clock.now },
            initialApplicationActive: true
        )

        admission.visualBecameReady(owner: owner)
        clock.now = 0.25
        admission.visualBecameUnavailable(owner: owner)
        clock.now = 100
        admission.visualBecameReady(owner: owner)
        XCTAssertEqual(impressions, 0)
        clock.now = 100.75
        admission.visualBecameUnavailable(owner: owner)
        XCTAssertEqual(impressions, 1)

        clock.now = 200
        admission.visualBecameReady(owner: owner)
        clock.now = 300
        admission.visualBecameUnavailable(owner: owner)
        XCTAssertEqual(displayed, 1)
        XCTAssertEqual(impressions, 1)
        admission.stop()
    }

    @MainActor
    func testInjectedClockExcludesBackgroundGap() {
        let clock = TestUptime(0)
        let owner = FullscreenVisualSurfaceToken()
        var impressions = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: {},
            onImpression: { impressions += 1 },
            impressionDelayMs: 1_000,
            tickNanos: 60_000_000_000,
            uptime: { clock.now },
            initialApplicationActive: true
        )

        admission.visualBecameReady(owner: owner)
        clock.now = 0.3
        admission.setApplicationActive(false)
        clock.now = 50
        admission.setApplicationActive(true)
        clock.now = 50.7
        admission.setApplicationActive(false)

        XCTAssertEqual(impressions, 1)
        admission.stop()
    }

    @MainActor
    func testInactiveOnAppearBlocksBeforeReadmissionNearImpressionThreshold() {
        let clock = TestUptime(0)
        let owner = FullscreenVisualSurfaceToken()
        var impressions = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: {},
            onImpression: { impressions += 1 },
            impressionDelayMs: 1_000,
            tickNanos: 60_000_000_000,
            uptime: { clock.now },
            initialApplicationActive: true
        )

        admission.visualBecameReady(owner: owner)
        clock.now = 0.99
        admission.visualBecameUnavailable(owner: owner)
        clock.now = 100
        admission.setBlocked(true)
        admission.visualBecameReady(owner: owner)
        clock.now = 200
        admission.setBlocked(false)
        XCTAssertEqual(impressions, 0)

        clock.now = 200.02
        admission.setBlocked(true)
        XCTAssertEqual(impressions, 1)
        admission.stop()
    }

    @MainActor
    func testPresentationAccountingRetainsOwnerUntilContextIsReleased() {
        final class Owner {}
        weak var weakOwner: Owner?
        var admission: FullscreenPresentationAdmission?
        do {
            let owner = Owner()
            weakOwner = owner
            admission = FullscreenPresentationAdmission(
                onDisplayed: { _ = owner },
                onDisplayFailed: { _ = owner },
                onImpression: { _ = owner }
            )
        }
        XCTAssertNotNil(weakOwner)
        admission = nil
        XCTAssertNil(weakOwner)
    }

    @MainActor
    func testInterstitialAdmissionDoesNotRetainAdButAccountingSurvives() throws {
        var recorded: [(String, FullscreenPresentationAccountingSnapshot)] = []
        var beacons: [(String, FullscreenPresentationAccountingSnapshot)] = []
        var publisherCallbacks = 0
        var autoPreloads = 0
        let sink = FullscreenPresentationAccountingSink(
            recordDisplayed: { recorded.append(("displayed", $0)) },
            recordImpression: { recorded.append(("impression", $0)) },
            enqueueShown: { beacons.append(("shown", $0)) },
            enqueueSeen: { beacons.append(("seen", $0)) }
        )
        var ad: SimulaInterstitialAd? = SimulaInterstitialAd(adUnitId: "interstitial-unit")
        weak var weakAd = ad
        let owner = WeakFullscreenPresentationOwner(try XCTUnwrap(ad))
        let callbacks = fullscreenPresentationAccountingCallbacks(
            owner: owner,
            snapshot: FullscreenPresentationAccountingSnapshot(
                adFormat: "interstitial",
                adUnitId: "interstitial-unit",
                adId: "interstitial-impression",
                serveId: "interstitial-impression",
                adValue: .fromBidCpm(5),
                metadata: ["surface": "test"],
                showStartNanos: DispatchTime.now().uptimeNanoseconds
            ),
            sink: sink,
            notifyDisplayed: { _ in publisherCallbacks += 1 },
            notifyDisplayFailed: { _ in publisherCallbacks += 1 },
            notifyImpression: { _, _ in publisherCallbacks += 1 }
        )
        let admission = FullscreenPresentationAdmission(
            onDisplayed: callbacks.onDisplayed,
            onDisplayFailed: callbacks.onDisplayFailed,
            onImpression: callbacks.onImpression
        )
        let closeAndPreload = { [owner] in
            guard owner.value != nil else { return }
            publisherCallbacks += 1
            autoPreloads += 1
        }

        ad = nil
        XCTAssertNil(weakAd)

        admission.presentationDidSucceed()
        admission.presentationDidSucceed()
        callbacks.onImpression()
        callbacks.onDisplayFailed()
        closeAndPreload()

        XCTAssertEqual(recorded.map(\.0), ["displayed", "impression"])
        XCTAssertEqual(beacons.map(\.0), ["shown", "seen"])
        XCTAssertEqual(recorded.last?.1.adValue, .fromBidCpm(5))
        XCTAssertEqual(beacons.last?.1.metadata, ["surface": "test"])
        XCTAssertEqual(publisherCallbacks, 0)
        XCTAssertEqual(autoPreloads, 0)
        admission.stop()
    }

    @MainActor
    func testRewardedAdmissionDoesNotRetainAdButAccountingSurvives() throws {
        var recorded: [(String, FullscreenPresentationAccountingSnapshot)] = []
        var beacons: [(String, FullscreenPresentationAccountingSnapshot)] = []
        var publisherCallbacks = 0
        var autoPreloads = 0
        let sink = FullscreenPresentationAccountingSink(
            recordDisplayed: { recorded.append(("displayed", $0)) },
            recordImpression: { recorded.append(("impression", $0)) },
            enqueueShown: { beacons.append(("shown", $0)) },
            enqueueSeen: { beacons.append(("seen", $0)) }
        )
        var ad: SimulaRewardedAd? = SimulaRewardedAd(adUnitId: "rewarded-unit")
        weak var weakAd = ad
        let owner = WeakFullscreenPresentationOwner(try XCTUnwrap(ad))
        let callbacks = fullscreenPresentationAccountingCallbacks(
            owner: owner,
            snapshot: FullscreenPresentationAccountingSnapshot(
                adFormat: "rewarded",
                adUnitId: "rewarded-unit",
                adId: "rewarded-impression",
                serveId: nil,
                adValue: .fromBidCpm(7),
                metadata: ["surface": "test"],
                showStartNanos: DispatchTime.now().uptimeNanoseconds
            ),
            sink: sink,
            notifyDisplayed: { _ in publisherCallbacks += 1 },
            notifyDisplayFailed: { _ in publisherCallbacks += 1 },
            notifyImpression: { _, _ in publisherCallbacks += 1 }
        )
        let admission = FullscreenPresentationAdmission(
            onDisplayed: callbacks.onDisplayed,
            onDisplayFailed: callbacks.onDisplayFailed,
            onImpression: callbacks.onImpression
        )
        let closeAndPreload = { [owner] in
            guard owner.value != nil else { return }
            publisherCallbacks += 1
            autoPreloads += 1
        }

        ad = nil
        XCTAssertNil(weakAd)

        admission.presentationDidSucceed()
        admission.presentationDidSucceed()
        callbacks.onImpression()
        callbacks.onDisplayFailed()
        closeAndPreload()

        XCTAssertEqual(recorded.map(\.0), ["displayed", "impression"])
        XCTAssertEqual(beacons.map(\.0), ["shown", "seen"])
        XCTAssertNil(recorded.last?.1.serveId)
        XCTAssertEqual(recorded.last?.1.adValue, .fromBidCpm(7))
        XCTAssertEqual(publisherCallbacks, 0)
        XCTAssertEqual(autoPreloads, 0)
        admission.stop()
    }

    @MainActor
    func testPresentationFinishEmitsOnlyNoDisplayFailure() {
        var displayed = 0
        var failed = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: { displayed += 1 },
            onDisplayFailed: { failed += 1 },
            onImpression: {}
        )
        XCTAssertEqual(admission.finish(), .displayFailed)
        XCTAssertNil(admission.finish())
        XCTAssertEqual(displayed, 0)
        XCTAssertEqual(failed, 1)
    }

    @MainActor
    func testDisplayFailureCallbackCanReentrantlyLeaveOwnerLoading() {
        enum OwnerState: Equatable { case showing, idle, loading }
        var ownerState = OwnerState.showing
        let admission = FullscreenPresentationAdmission(
            onDisplayed: {},
            onDisplayFailed: {
                XCTAssertTrue(ownerState == .idle)
                ownerState = .loading
            },
            onImpression: {}
        )
        ownerState = .idle
        XCTAssertEqual(admission.finish(), .displayFailed)
        XCTAssertTrue(ownerState == .loading)
    }

    @MainActor
    func testLegacyHTMLPresentationAdmitsDisplayBeforeNavigationReadiness() {
        var displayed = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: { displayed += 1 },
            onImpression: {}
        )
        admission.presentationDidSucceed()
        XCTAssertEqual(displayed, 1)
        XCTAssertTrue(admission.hasAdmittedDisplay)
        XCTAssertEqual(admission.finish(), .closed)
    }

    @MainActor
    func testLegacyHTMLEngineCommitsAtPresentationAnchoredThresholdAfterDidCommit() {
        let clock = TestUptime(10)
        var displayed = 0
        var impressions = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: { displayed += 1 },
            onImpression: { impressions += 1 },
            impressionDelayMs: 2_000,
            tickNanos: 60_000_000_000,
            uptime: { clock.now },
            initialApplicationActive: true
        )

        admission.presentationDidSucceed()
        clock.now = 12.5
        admission.htmlNavigationDidCommit()
        admission.htmlNavigationDidCommit()

        XCTAssertEqual(displayed, 1)
        XCTAssertEqual(impressions, 1)
        XCTAssertEqual(admission.finish(), .closed)
    }

    @MainActor
    func testLegacyHTMLEngineFailureBeforeBillingStopsDwellPermanently() {
        let clock = TestUptime(0)
        var impressions = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: {},
            onImpression: { impressions += 1 },
            impressionDelayMs: 2_000,
            tickNanos: 60_000_000_000,
            uptime: { clock.now },
            initialApplicationActive: true
        )

        admission.presentationDidSucceed()
        clock.now = 1
        admission.htmlNavigationDidFail()
        clock.now = 100
        admission.htmlNavigationDidCommit()
        admission.setBlocked(true)

        XCTAssertEqual(impressions, 0)
        XCTAssertEqual(admission.finish(), .closed)
    }

    @MainActor
    func testPresentationShownAndCommittedInactiveStartsImpressionAfterDidBecomeActive() async throws {
        var impressions = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: {},
            onImpression: { impressions += 1 },
            impressionDelayMs: 5,
            tickNanos: 1_000_000
        )
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        admission.presentationDidSucceed()
        admission.htmlNavigationDidCommit()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(impressions, 0)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { impressions == 1 }
        XCTAssertEqual(impressions, 1)
        XCTAssertEqual(admission.finish(), .closed)
    }

    func testAudioInterruptionEndingWithoutShouldResumeStaysPaused() {
        XCTAssertEqual(
            videoInterruptionEndAction(pausedByInterruption: true, userInfo: nil),
            .stayPaused
        )
        XCTAssertEqual(videoInterruptionEndAction(pausedByInterruption: true, userInfo: [
            AVAudioSessionInterruptionOptionKey: UInt(0),
        ]), .stayPaused)
        XCTAssertEqual(videoInterruptionEndAction(pausedByInterruption: true, userInfo: [
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]), .resume)
    }

    func testActiveInterruptionOffersResumeWheneverPlaybackIsWanted() {
        XCTAssertTrue(shouldOfferVideoInterruptionResume(
            audioInterrupted: true,
            wantsPlayback: true
        ))
        XCTAssertFalse(shouldOfferVideoInterruptionResume(
            audioInterrupted: true,
            wantsPlayback: false
        ))
        XCTAssertFalse(shouldOfferVideoInterruptionResume(
            audioInterrupted: false,
            wantsPlayback: true
        ))
    }

    func testLatePlaybackIntentRearmsExpiredInterruptionFallback() {
        XCTAssertTrue(shouldScheduleVideoInterruptionFallback(
            audioInterrupted: true,
            wantsPlayback: true,
            resumeOffered: false,
            fallbackPending: false
        ))
        XCTAssertFalse(shouldScheduleVideoInterruptionFallback(
            audioInterrupted: true,
            wantsPlayback: true,
            resumeOffered: true,
            fallbackPending: false
        ))
        XCTAssertFalse(shouldScheduleVideoInterruptionFallback(
            audioInterrupted: true,
            wantsPlayback: true,
            resumeOffered: false,
            fallbackPending: true
        ))
    }

    @MainActor
    func testInterruptionUserResumeClearsPauseWithoutFailure() {
        let url = URL(fileURLWithPath: "/dev/null")
        let player = FullscreenVideoPlayer(url: url, posterURL: nil)
        player.play()
        player.applyInterruptionEndAction(.stayPaused)
        XCTAssertTrue(player.requiresUserResume)
        player.play()
        XCTAssertTrue(player.requiresUserResume)
        player.resumeAfterInterruption()
        XCTAssertFalse(player.requiresUserResume)
        if case .failed = player.status { XCTFail("Explicit interruption resume must not fail playback") }
        player.stop()
    }

    @MainActor
    func testPlayerMuteDefenseRemainsSynchronizedAcrossExplicitToggle() {
        let player = FullscreenVideoPlayer(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil)
        XCTAssertFalse(player.isMuted)
        XCTAssertFalse(player.player.isMuted)
        XCTAssertTrue(player.admitFirstVisualFrame())

        player.toggleMuted()
        XCTAssertTrue(player.isMuted)
        XCTAssertTrue(player.player.isMuted)
        player.toggleMuted()
        XCTAssertFalse(player.isMuted)
        XCTAssertFalse(player.player.isMuted)
        player.stop()
    }

    @MainActor
    func testLegacyAndV2ColdFallbackVideosStartUnmuted() throws {
        for timeout in [FullscreenVideoPlayer.preparationTimeout, FullscreenVideoPlayer.videoPlanV2StallTimeout] {
            let ownership = makeFallbackVideoOwnership(
                url: URL(fileURLWithPath: "/dev/null"),
                posterURL: nil,
                token: nil,
                stallTimeout: timeout
            )
            defer { ownership.release() }
            let player = try XCTUnwrap(ownership.resource)
            XCTAssertFalse(player.isMuted)
            XCTAssertFalse(player.player.isMuted)
        }
    }

    @MainActor
    func testLegacyAndV2PreparedVideosStartUnmutedAndPreserveUserMuteOnReuse() throws {
        let url = URL(fileURLWithPath: "/dev/null")
        let pool = FullscreenVideoPreparationPool(capacity: 1)
        for timeout in [FullscreenVideoPlayer.preparationTimeout, FullscreenVideoPlayer.videoPlanV2StallTimeout] {
            let token = try XCTUnwrap(pool.prepare(url: url, posterURL: nil, stallTimeout: timeout))
            defer { pool.release(token) }
            let player = try XCTUnwrap(pool.claim(token, url: url, posterURL: nil, stallTimeout: timeout))
            XCTAssertFalse(player.isMuted)
            XCTAssertFalse(player.player.isMuted)

            player.setMuted(true)
            pool.returnToPrepared(token)
            let reclaimed = try XCTUnwrap(pool.claim(token, url: url, posterURL: nil, stallTimeout: timeout))
            XCTAssertTrue(reclaimed === player)
            XCTAssertTrue(reclaimed.isMuted)
            XCTAssertTrue(reclaimed.player.isMuted)
        }
    }

    @MainActor
    func testAudioInterruptionObserverForwardsBeganNotification() async {
        let player = FullscreenVideoPlayer.makeStateTestingPlayer(
            url: URL(fileURLWithPath: "/dev/null"),
            posterURL: nil
        )
        defer { player.stop() }
        await Task.yield()
        XCTAssertEqual(player.status, .preparing)
        XCTAssertFalse(player.status.isTerminal)
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        XCTAssertFalse(
            player.hasActiveAudioInterruption,
            "notification delivery must return before publishing interruption state"
        )
        await waitUntil { player.hasActiveAudioInterruption }
        XCTAssertEqual(player.status, .preparing)
        XCTAssertFalse(player.status.isTerminal)
        XCTAssertTrue(player.hasActiveAudioInterruption)
    }

    @MainActor
    func testTerminalObserverSchedulesTeardownAfterCallbackReturnsExactlyOnce() async {
        let player = FullscreenVideoPlayer.makeStateTestingPlayer(
            url: URL(fileURLWithPath: "/dev/null"),
            posterURL: nil
        )
        XCTAssertTrue(player.admitFirstVisualFrame())
        var callbackReturned = false
        var terminalPublications = 0
        var teardownRanAfterCallback = false
        let observation = player.$status.dropFirst().sink { status in
            guard status.isTerminal else { return }
            terminalPublications += 1
            teardownRanAfterCallback = callbackReturned
            player.stop()
        }

        player.enqueueEndedObserverCallbackForTests()
        XCTAssertFalse(player.isStopped)
        XCTAssertEqual(terminalPublications, 0)
        callbackReturned = true
        await waitUntil { player.isStopped }

        player.enqueueEndedObserverCallbackForTests()
        await Task.yield()
        XCTAssertTrue(teardownRanAfterCallback)
        XCTAssertEqual(terminalPublications, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testUnmatchedInterruptionAcrossReactivationOffersResumeAndExplicitResumeClearsIt() {
        let player = FullscreenVideoPlayer(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil)
        player.play()
        player.receiveAudioInterruption(type: .began)
        player.receiveApplicationActiveState(false)
        player.receiveApplicationActiveState(true)

        XCTAssertTrue(player.requiresUserResume)
        XCTAssertTrue(player.hasActiveAudioInterruption)
        player.resumeAfterInterruption()
        XCTAssertFalse(player.requiresUserResume)
        XCTAssertFalse(player.hasActiveAudioInterruption)
        player.stop()
    }

    @MainActor
    func testInterruptionBeforeFirstFrameStillOffersRecoveryAfterFrameAdmission() {
        let player = FullscreenVideoPlayer(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil)
        player.play()
        player.receiveAudioInterruption(type: .began)

        XCTAssertTrue(player.hasActiveAudioInterruption)
        XCTAssertTrue(player.hasPendingInterruptionFallback)
        XCTAssertTrue(player.admitFirstVisualFrame())
        XCTAssertTrue(player.hasPendingInterruptionFallback)
        player.fireInterruptionFallbackForTests()

        XCTAssertTrue(player.hasActiveAudioInterruption)
        XCTAssertTrue(player.requiresUserResume)
        player.resumeAfterInterruption()
        player.stop()
    }

    @MainActor
    func testLongSystemInterruptionRemainsActiveUntilExplicitRecovery() {
        let player = FullscreenVideoPlayer(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil)
        player.play()
        player.receiveAudioInterruption(type: .began)

        XCTAssertTrue(player.hasActiveAudioInterruption)
        XCTAssertTrue(player.hasPendingInterruptionFallback)
        player.fireInterruptionFallbackForTests()

        XCTAssertTrue(player.hasActiveAudioInterruption)
        XCTAssertTrue(player.requiresUserResume)
        player.play()
        XCTAssertTrue(player.hasActiveAudioInterruption)
        XCTAssertTrue(player.requiresUserResume)

        player.resumeAfterInterruption()
        XCTAssertFalse(player.hasActiveAudioInterruption)
        XCTAssertFalse(player.requiresUserResume)
        player.stop()
    }

    @MainActor
    func testIdleInterruptionRearmsRecoveryWhenPlaybackIsRequestedLater() {
        let player = FullscreenVideoPlayer(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil)
        player.receiveAudioInterruption(type: .began)

        XCTAssertTrue(player.hasActiveAudioInterruption)
        XCTAssertTrue(player.hasPendingInterruptionFallback)
        player.fireInterruptionFallbackForTests()
        XCTAssertTrue(player.hasActiveAudioInterruption)
        XCTAssertFalse(player.requiresUserResume)
        XCTAssertFalse(player.hasPendingInterruptionFallback)

        player.play()
        XCTAssertTrue(player.hasActiveAudioInterruption)
        XCTAssertFalse(player.requiresUserResume)
        XCTAssertTrue(player.hasPendingInterruptionFallback)

        player.fireInterruptionFallbackForTests()
        XCTAssertTrue(player.hasActiveAudioInterruption)
        XCTAssertTrue(player.requiresUserResume)

        player.resumeAfterInterruption()
        XCTAssertFalse(player.hasActiveAudioInterruption)
        XCTAssertFalse(player.requiresUserResume)
        player.stop()
    }

    func testPreparedPoolClaimRejectsTerminalAndReplayedStatuses() {
        XCTAssertTrue(shouldReusePreparedVideoPlayer(status: .preparing, isStopped: false, isActive: false))
        XCTAssertTrue(shouldReusePreparedVideoPlayer(status: .ready, isStopped: false, isActive: false))
        XCTAssertTrue(shouldReusePreparedVideoPlayer(status: .paused, isStopped: false, isActive: false))
        XCTAssertFalse(shouldReusePreparedVideoPlayer(status: .playing, isStopped: false, isActive: true))
        XCTAssertFalse(shouldReusePreparedVideoPlayer(status: .ended, isStopped: false, isActive: false))
        XCTAssertFalse(shouldReusePreparedVideoPlayer(
            status: .failed(.playbackFailed),
            isStopped: false,
            isActive: false
        ))
        XCTAssertFalse(shouldReusePreparedVideoPlayer(status: .ready, isStopped: true, isActive: false))
    }

    func testIndefiniteFirstFrameAnchorsAtFirstFinitePeriodicSample() {
        var clock = VideoVisiblePlaybackClock()
        clock.admitFirstFrame(mediaTime: CMTime.indefinite.seconds)
        XCTAssertNil(clock.firstFrameMediaTime)
        XCTAssertEqual(clock.update(mediaTime: 12), 0)
        XCTAssertEqual(clock.update(mediaTime: 12.5), 0.5, accuracy: 0.001)
    }

    @MainActor
    func testPreparationPoolReturnsNilWhenEveryBoundedSlotIsActive() throws {
        let pool = FullscreenVideoPreparationPool(capacity: 2)
        let firstURL = URL(fileURLWithPath: "/dev/null/first")
        let secondURL = URL(fileURLWithPath: "/dev/null/second")
        let firstToken = try XCTUnwrap(pool.prepare(url: firstURL, posterURL: nil))
        let secondToken = try XCTUnwrap(pool.prepare(url: secondURL, posterURL: nil))
        let firstPlayer = try XCTUnwrap(pool.claim(firstToken, url: firstURL, posterURL: nil))
        let secondPlayer = try XCTUnwrap(pool.claim(secondToken, url: secondURL, posterURL: nil))

        XCTAssertNil(pool.prepare(url: URL(fileURLWithPath: "/dev/null/third"), posterURL: nil))
        XCTAssertFalse(firstPlayer.isStopped)
        XCTAssertFalse(secondPlayer.isStopped)

        pool.release(firstToken)
        pool.release(secondToken)
    }

    @MainActor
    func testDiscardingUnclaimedPreparationNeverStopsActivePooledPlayer() throws {
        let pool = FullscreenVideoPreparationPool(capacity: 1)
        let url = URL(fileURLWithPath: "/dev/null")
        let token = try XCTUnwrap(pool.prepare(url: url, posterURL: nil))
        let player = try XCTUnwrap(pool.claim(token, url: url, posterURL: nil))

        pool.discardPrepared(token)

        XCTAssertFalse(player.isStopped)
        pool.release(token)
        XCTAssertTrue(player.isStopped)
    }

    @MainActor
    func testZeroCapacityPreparationPoolReturnsNoToken() {
        let pool = FullscreenVideoPreparationPool(capacity: 0)
        XCTAssertNil(pool.prepare(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil))
    }

    @MainActor
    func testVideoLoadPreparationSaturationFallsBackToColdShowPreparation() {
        let video = FullscreenCreativeContent.video(
            url: URL(fileURLWithPath: "/dev/null"),
            posterURL: nil
        )
        guard case .cold = reserveFullscreenVideoPreparation(
            for: video,
            prepare: { _, _ in nil }
        ) else { return XCTFail("Expected cold video preparation fallback") }

        guard case .notRequired = reserveFullscreenVideoPreparation(
            for: .playable(html: "<html/>"),
            prepare: { _, _ in
                XCTFail("HTML must not reserve video capacity")
                return nil
            }
        ) else { return XCTFail("Expected no video reservation requirement") }
    }

    @MainActor
    func testStoppedPreparedPlayerIsEvictedAndClaimReturnsFreshPlayer() throws {
        let url = URL(fileURLWithPath: "/dev/null")
        let pool = FullscreenVideoPreparationPool.shared
        let token = try XCTUnwrap(pool.prepare(url: url, posterURL: nil))
        let first = try XCTUnwrap(pool.claim(token, url: url, posterURL: nil))
        first.stop()
        pool.returnToPrepared(token)
        let replay = try XCTUnwrap(pool.claim(token, url: url, posterURL: nil))
        XCTAssertFalse(first === replay)
        XCTAssertFalse(replay.isStopped)
        pool.release(token)
    }

    @MainActor
    func testAdOwnerDeinitCannotReleaseTransferredActivePresentation() throws {
        final class AdOwner {
            var preparation: FullscreenVideoPreparationOwnership?
            let onDeinit: () -> Void

            init(onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }

        let url = URL(fileURLWithPath: "/dev/null")
        let token = try XCTUnwrap(FullscreenVideoPreparationPool.shared.prepare(url: url, posterURL: nil))
        var ownerDeinitialized = false
        var owner: AdOwner? = AdOwner { ownerDeinitialized = true }
        let preparation = FullscreenVideoPreparationOwnership(token: token)
        owner?.preparation = preparation
        let player = try XCTUnwrap(preparation.claim(url: url, posterURL: nil))
        XCTAssertTrue(preparation.transferToPresentation())

        owner?.preparation = nil
        owner = nil

        XCTAssertTrue(ownerDeinitialized)
        XCTAssertEqual(preparation.state, .presentation)
        XCTAssertFalse(player.isStopped)
        XCTAssertFalse(preparation.releaseFromAd())
        XCTAssertFalse(player.isStopped)
        XCTAssertTrue(preparation.releaseFromPresentation())
        XCTAssertTrue(player.isStopped)
        XCTAssertFalse(preparation.releaseFromPresentation(), "presentation teardown releases exactly once")
    }

    @MainActor
    func testFailedPresentationReturnsClaimedPreparationToAdOwnership() throws {
        let url = URL(fileURLWithPath: "/dev/null")
        let token = try XCTUnwrap(FullscreenVideoPreparationPool.shared.prepare(url: url, posterURL: nil))
        let preparation = FullscreenVideoPreparationOwnership(token: token)
        let player = try XCTUnwrap(preparation.claim(url: url, posterURL: nil))
        XCTAssertTrue(preparation.transferToPresentation())

        XCTAssertTrue(preparation.returnToAdAfterPresentationFailure())
        XCTAssertEqual(preparation.state, .ad)
        XCTAssertFalse(player.isStopped)
        XCTAssertTrue(preparation.releaseFromAd())
        XCTAssertTrue(player.isStopped)
    }

    @MainActor
    func testFallbackPreparedTokenReleaseInvalidatesPlayerAndToken() throws {
        let url = URL(fileURLWithPath: "/dev/null")
        let pool = FullscreenVideoPreparationPool.shared
        let token = try XCTUnwrap(pool.prepare(url: url, posterURL: nil))
        let first = try XCTUnwrap(pool.claim(token, url: url, posterURL: nil))
        pool.returnToPrepared(token)
        releasePreparedFallbackVideos(in: .content([], preparedVideos: [0: token]))
        XCTAssertNil(pool.claim(token, url: url, posterURL: nil))
        XCTAssertTrue(first.isStopped)
        pool.release(token)
    }

    @MainActor
    func testEmptyFallbackCleanupDiscardsIdleButPreservesActivePreparation() throws {
        let pool = FullscreenVideoPreparationPool(capacity: 2)
        let idleURL = URL(fileURLWithPath: "/dev/null/idle")
        let activeURL = URL(fileURLWithPath: "/dev/null/active")
        let idleToken = try XCTUnwrap(pool.prepare(url: idleURL, posterURL: nil))
        let activeToken = try XCTUnwrap(pool.prepare(url: activeURL, posterURL: nil))
        defer {
            pool.release(idleToken)
            pool.release(activeToken)
        }
        let idlePlayer = try XCTUnwrap(pool.claim(idleToken, url: idleURL, posterURL: nil))
        let activePlayer = try XCTUnwrap(pool.claim(activeToken, url: activeURL, posterURL: nil))
        pool.returnToPrepared(idleToken)

        let accepted = acceptPreparedFallbackContent(
            ads: [],
            preparedVideos: [0: idleToken, 1: activeToken],
            discard: { pool.discardPrepared($0) }
        )

        XCTAssertFalse(accepted)
        XCTAssertTrue(idlePlayer.isStopped)
        XCTAssertFalse(activePlayer.isStopped)
        pool.release(activeToken)
        XCTAssertTrue(activePlayer.isStopped)
    }

    @MainActor
    func testNonemptyFallbackContentTransfersPreparationWithoutDiscarding() {
        let token = FullscreenVideoPreparationToken()
        var discarded: [FullscreenVideoPreparationToken] = []
        let ad = FallbackAd(
            adId: "fallback",
            iframeUrl: "",
            html: "<html/>",
            nativeClickBeaconV1Enabled: false,
            closeBehavior: .fallbackDefault
        )

        XCTAssertTrue(acceptPreparedFallbackContent(
            ads: [ad],
            preparedVideos: [0: token],
            discard: { discarded.append($0) }
        ))
        XCTAssertTrue(discarded.isEmpty)
    }

    func testPendingEndGraceIsBoundedInsideFirstFrameDeadline() {
        XCTAssertGreaterThan(FullscreenVideoPlayer.pendingEndFrameGrace, 0)
        XCTAssertLessThan(FullscreenVideoPlayer.pendingEndFrameGrace, FullscreenVideoPlayer.firstFrameTimeout)
    }

    func testVideoFailureStringsMatchAndroid() {
        XCTAssertEqual(FullscreenVideoFailure.preparationTimeout.rawValue, "prepare_timeout")
        XCTAssertEqual(FullscreenVideoFailure.playbackTimeout.rawValue, "playback_timeout")
        XCTAssertEqual(FullscreenVideoFailure.itemFailed.rawValue, "prepare_failed")
        XCTAssertEqual(FullscreenVideoFailure.playbackFailed.rawValue, "playback_error")
        XCTAssertEqual(FullscreenVideoFailure.firstFrameTimeout.rawValue, "first_frame_timeout")
    }
    #endif
}
