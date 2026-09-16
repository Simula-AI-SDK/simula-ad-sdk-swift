import XCTest
@testable import SimulaAdSDK
#if os(iOS)
import AVFoundation
#endif

final class FullscreenPresentationAdmissionTests: XCTestCase {
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

    func testHTMLRewardGateWaitsForPrimaryCreativeReadiness() {
        XCTAssertFalse(shouldRunRewardedHTMLGate(
            primaryCreativeReady: false,
            appForegrounded: true,
            storeSheetPresented: false,
            rewardEarned: false
        ))
        XCTAssertNil(rewardedHTMLGateCompletionReason(
            primaryCreativeReady: false,
            actualElapsedPlayTime: 30,
            gateDuration: 30
        ))
        XCTAssertTrue(shouldRunRewardedHTMLGate(
            primaryCreativeReady: true,
            appForegrounded: true,
            storeSheetPresented: false,
            rewardEarned: false
        ))
    }

    func testHTMLZeroGateEarnsOnlyAfterPrimaryCreativeReadiness() {
        XCTAssertNil(rewardedHTMLGateCompletionReason(
            primaryCreativeReady: false,
            actualElapsedPlayTime: 0,
            gateDuration: 0
        ))
        XCTAssertEqual(
            rewardedHTMLGateCompletionReason(
                primaryCreativeReady: true,
                actualElapsedPlayTime: 0,
                gateDuration: 0
            ),
            .durationElapsed
        )
    }

    func testHTMLFailureBeforeReadinessFallsBackWithoutRewardOrVerification() {
        var completion = RewardCompletionState()
        if let reason = rewardedHTMLGateCompletionReason(
            primaryCreativeReady: false,
            actualElapsedPlayTime: 30,
            gateDuration: 0
        ) {
            completion.earn(reason: reason)
        }
        let outcome = rewardedTerminalOutcome(
            earned: completion.earned,
            actualElapsedPlayTime: 0,
            completionReason: completion.reason
        )
        let policy = FullscreenPostPrimaryPolicy(
            terminalOutcome: .closed,
            earnedReward: outcome.earned
        )

        XCTAssertTrue(policy.presentsFallbacks)
        XCTAssertFalse(policy.verifiesEarnedReward)
        XCTAssertFalse(outcome.earned)
        XCTAssertNil(outcome.completionReason)
        XCTAssertNil(rewardVerificationElapsedPlayTime(
            earned: outcome.earned,
            actualElapsedPlayTime: outcome.elapsedPlayTime
        ))
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

    func testFallbackFailureAdvanceWaitsForHandoff() {
        var state = FallbackFailureAdvanceState()
        XCTAssertFalse(state.request(index: 2, blocked: true))
        XCTAssertNil(state.blockersDidClear(currentIndex: 1))
        XCTAssertEqual(state.blockersDidClear(currentIndex: 2), 2)
        XCTAssertNil(state.blockersDidClear(currentIndex: 2))
        XCTAssertTrue(state.request(index: 3, blocked: false))
    }

    func testFallbackFailureAdvanceAlsoWaitsForStoreSheet() {
        var state = FallbackFailureAdvanceState()
        XCTAssertFalse(state.request(index: 0, blocked: true))
        XCTAssertNil(state.blockersDidClear(currentIndex: 1))
        XCTAssertEqual(state.blockersDidClear(currentIndex: 0), 0)
    }

    func testDeclarativeFallbackFailureWaitsUntilEveryRouteBlockerClears() {
        var state = FallbackFailureAdvanceState()
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

    func testDisplayFailureStillPresentsFallbackWithoutCloseOrReward() {
        let policy = FullscreenPostPrimaryPolicy(
            terminalOutcome: .displayFailed,
            earnedReward: true
        )
        var callbacks: [String] = []
        if policy.presentsFallbacks { callbacks.append("fallback") }
        if policy.notifiesPublisherClose { callbacks.append("close") }
        if policy.verifiesEarnedReward { callbacks.append("reward") }
        XCTAssertEqual(callbacks, ["fallback"])
    }

    func testAdmittedClosePresentsFallbackThenPublishesClose() {
        let policy = FullscreenPostPrimaryPolicy(terminalOutcome: .closed)
        var callbacks: [String] = []
        if policy.presentsFallbacks { callbacks.append("fallback") }
        if policy.notifiesPublisherClose { callbacks.append("close") }
        XCTAssertEqual(callbacks, ["fallback", "close"])
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
    func testPresentationShownInactiveStartsImpressionAfterDidBecomeActive() async throws {
        var impressions = 0
        let admission = FullscreenPresentationAdmission(
            onDisplayed: {},
            onImpression: { impressions += 1 },
            impressionDelayMs: 5,
            tickNanos: 1_000_000
        )
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        admission.presentationDidSucceed()
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

    @MainActor
    func testStoppedPreparedPlayerIsEvictedAndClaimReturnsFreshPlayer() throws {
        let url = URL(fileURLWithPath: "/dev/null")
        let pool = FullscreenVideoPreparationPool.shared
        let token = pool.prepare(url: url, posterURL: nil)
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
        let token = FullscreenVideoPreparationPool.shared.prepare(url: url, posterURL: nil)
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
        let token = FullscreenVideoPreparationPool.shared.prepare(url: url, posterURL: nil)
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
    func testFallbackPreparedTokenReleasePreventsPlayerReuse() throws {
        let url = URL(fileURLWithPath: "/dev/null")
        let pool = FullscreenVideoPreparationPool.shared
        let token = pool.prepare(url: url, posterURL: nil)
        let first = try XCTUnwrap(pool.claim(token, url: url, posterURL: nil))
        pool.returnToPrepared(token)
        releasePreparedFallbackVideos(in: .content([], preparedVideos: [0: token]))
        let replacement = try XCTUnwrap(pool.claim(token, url: url, posterURL: nil))
        XCTAssertFalse(first === replacement)
        pool.release(token)
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
