import XCTest
@testable import SimulaAdSDK
#if os(iOS)
import AVFoundation
#endif

final class FullscreenPresentationAdmissionTests: XCTestCase {
    func testRewardFailureFailsOpenOnlyAfterPrimaryVisualReadiness() {
        XCTAssertFalse(earnedRewardAfterPrimaryFailure(primaryVisuallyReady: false))
        XCTAssertTrue(earnedRewardAfterPrimaryFailure(primaryVisuallyReady: true))
    }

    func testConfiguredGateVerificationPreservesActualPlaybackAboveRequirement() {
        XCTAssertEqual(
            rewardVerificationElapsedPlayTime(
                earned: true,
                actualElapsedPlayTime: 34.5,
                configuredDelaySeconds: 30
            ),
            34.5
        )
    }

    func testShortVideoCompletionVerificationClampsToConfiguredGate() {
        XCTAssertEqual(
            rewardVerificationElapsedPlayTime(
                earned: true,
                actualElapsedPlayTime: 8,
                configuredDelaySeconds: 30
            ),
            30
        )
    }

    func testEarlyCompleteVerificationClampsToConfiguredGate() {
        XCTAssertEqual(
            rewardVerificationElapsedPlayTime(
                earned: true,
                actualElapsedPlayTime: 2.25,
                configuredDelaySeconds: 30
            ),
            30
        )
    }

    func testPostFirstFrameFailOpenVerificationClampsToConfiguredGate() {
        XCTAssertEqual(
            rewardVerificationElapsedPlayTime(
                earned: true,
                actualElapsedPlayTime: 0.5,
                configuredDelaySeconds: 30
            ),
            30
        )
    }

    func testPreEarnedOutcomeNeverProducesVerificationEvidence() {
        XCTAssertNil(
            rewardVerificationElapsedPlayTime(
                earned: false,
                actualElapsedPlayTime: 30,
                configuredDelaySeconds: 30
            )
        )
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

        // A fallback can become the first usable surface without producing a second DISPLAYED.
        XCTAssertFalse(state.visualBecameReady())
        XCTAssertTrue(state.accrueImpression(deltaMs: 1_000, thresholdMs: 2_000))
        XCTAssertTrue(state.impressionCommitted)
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
        ownership.consumedByLoadingPresenter = true
        XCTAssertTrue(ownership.consumedByLoadingPresenter)
    }

    func testPreparedPlayerRetentionIsBoundedAndNeverEvictsActiveEntry() {
        let policy = VideoPreparationRetentionPolicy(capacity: 2, retention: 300)
        let entries = [
            VideoPreparationRetentionPolicy.Entry(id: "active", active: true, lastTouched: 0),
            VideoPreparationRetentionPolicy.Entry(id: "idle", active: false, lastTouched: 10),
        ]
        XCTAssertEqual(policy.evictionCandidate(entries), "idle")
        XCTAssertEqual(policy.expiredEntryIDs(entries, now: 311), ["idle"])
        XCTAssertNil(policy.evictionCandidate([
            .init(id: "a", active: true, lastTouched: 0),
            .init(id: "b", active: true, lastTouched: 1),
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

    func testCompletedVideoReconcilesDurationBeforeEndedPublication() {
        XCTAssertEqual(
            reconciledCompletedVideoTime(
                playedSeconds: 2.5,
                finalPosition: 7.8,
                duration: 8
            ),
            8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            reconciledCompletedVideoTime(
                playedSeconds: 5,
                finalPosition: .nan,
                duration: nil
            ),
            5,
            accuracy: 0.001
        )
    }

    func testPrimaryVideoControlsRequireFrameAndDisplayAdmission() {
        XCTAssertFalse(canUseVideoControls(firstFrameAdmitted: false, displayAdmitted: false))
        XCTAssertFalse(canUseVideoControls(firstFrameAdmitted: true, displayAdmitted: false))
        XCTAssertFalse(canUseVideoControls(firstFrameAdmitted: false, displayAdmitted: true))
        XCTAssertTrue(canUseVideoControls(firstFrameAdmitted: true, displayAdmitted: true))
    }

    func testDisplayOutcomeFailsExactlyOnceWhenNothingWasAdmitted() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.failDisplayIfNeverAdmitted())
        XCTAssertFalse(state.failDisplayIfNeverAdmitted())
        XCTAssertFalse(state.visualBecameReady())
        XCTAssertEqual(state.displayOutcome, .failed)
        XCTAssertFalse(state.visualActive)
    }

    func testAdmittedDisplayCanNeverBecomeDisplayFailed() {
        var state = FullscreenVisualAdmissionState()
        XCTAssertTrue(state.visualBecameReady())
        XCTAssertFalse(state.failDisplayIfNeverAdmitted())
        XCTAssertEqual(state.displayOutcome, .displayed)
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
        admission.finish()
        admission.finish()
        XCTAssertEqual(displayed, 0)
        XCTAssertEqual(failed, 1)
    }

    @MainActor
    func testStalePrimaryDisappearCannotDeactivateReadyFallback() {
        let admission = FullscreenPresentationAdmission(onDisplayed: {}, onImpression: {})
        let primary = FullscreenVisualSurfaceToken()
        let fallback = FullscreenVisualSurfaceToken()
        admission.visualBecameReady(owner: primary)
        admission.visualBecameReady(owner: fallback)
        admission.visualBecameUnavailable(owner: primary)
        XCTAssertTrue(admission.visualIsActive)
        admission.stop()
    }

    func testAudioInterruptionResumesOnlyWhenSystemAllowsIt() {
        XCTAssertFalse(videoInterruptionShouldResume(nil))
        XCTAssertFalse(videoInterruptionShouldResume([
            AVAudioSessionInterruptionOptionKey: UInt(0),
        ]))
        XCTAssertTrue(videoInterruptionShouldResume([
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]))
    }
    #endif
}
