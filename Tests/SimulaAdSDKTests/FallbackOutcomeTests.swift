import XCTest
@testable import SimulaAdSDK

final class FallbackOutcomeTests: XCTestCase {
    func testFallbackVideoNeverMountsWithoutPreparedPlayer() {
        XCTAssertEqual(fallbackVideoReadiness(isVideo: true, hasPreparedPlayer: false), .prepare)
        XCTAssertEqual(fallbackVideoReadiness(isVideo: true, hasPreparedPlayer: true), .mount)
        XCTAssertEqual(fallbackVideoReadiness(isVideo: false, hasPreparedPlayer: false), .mount)
    }

    func testFallbackAdvanceRequiresCurrentScreenWithoutPendingClickRoute() {
        XCTAssertTrue(canAdvanceFallback(renderedIndex: 0, currentIndex: 0, clickHandoffIndex: nil))
        XCTAssertFalse(canAdvanceFallback(renderedIndex: 0, currentIndex: 0, clickHandoffIndex: 0))
        XCTAssertFalse(canAdvanceFallback(renderedIndex: 0, currentIndex: 1, clickHandoffIndex: nil))
        XCTAssertTrue(canAdvanceFallback(renderedIndex: 1, currentIndex: 1, clickHandoffIndex: 0))
    }

    func testFallbackScreenMountIsOnceOnlyAndIndependentOfPageCompletion() {
        var mount = AdOverlayScreenMountCoordinator()

        XCTAssertTrue(mount.scheduleIfNeeded())
        XCTAssertTrue(mount.markDelivered())
        XCTAssertTrue(mount.isMounted)
        XCTAssertFalse(mount.scheduleIfNeeded(), "re-appearance and late didFinish must not duplicate")
    }

    func testUndeliveredFallbackMountRearmsForSameScreenReappearance() {
        var mount = AdOverlayScreenMountCoordinator()

        XCTAssertTrue(mount.scheduleIfNeeded())
        mount.cancelScheduled()
        XCTAssertFalse(mount.isMounted)
        XCTAssertTrue(mount.scheduleIfNeeded())
        XCTAssertTrue(mount.markDelivered())
        XCTAssertTrue(mount.isMounted)
    }

    func testFallbackMountedCallbackRejectsStaleScreenIndex() {
        XCTAssertTrue(canHandleFallbackScreenCallback(renderedIndex: 0, currentIndex: 0))
        XCTAssertFalse(canHandleFallbackScreenCallback(renderedIndex: 0, currentIndex: 1))
        XCTAssertTrue(canHandleFallbackScreenCallback(renderedIndex: 1, currentIndex: 1))
    }

    func testLoadingTimeoutProducesUnavailableOutcomeOnce() {
        var coordinator = FallbackPresentationCoordinator()
        let generation = coordinator.beginLoading()

        XCTAssertEqual(coordinator.loadingTimedOut(generation: generation), .loadingTimeout)
        XCTAssertNil(coordinator.loadingTimedOut(generation: generation))
        XCTAssertEqual(coordinator.phase, .terminal(.loadingTimeout))
        XCTAssertEqual(FallbackOutcome.loadingTimeout.unavailableReason, "loading_timeout")
    }

    func testPresentedFallbackCompletionIsDistinctAndExactlyOnce() {
        var coordinator = FallbackPresentationCoordinator()
        _ = coordinator.beginPresenting()

        XCTAssertEqual(coordinator.completedPresentedContent(), .completed)
        XCTAssertNil(coordinator.completedPresentedContent())
        XCTAssertNil(FallbackOutcome.completed.unavailableReason)
    }

    func testEmptyAndFailedFetchesRemainDistinguishable() {
        var emptyCoordinator = FallbackPresentationCoordinator()
        let emptyGeneration = emptyCoordinator.beginLoading()
        XCTAssertEqual(
            emptyCoordinator.resolveLoading(generation: emptyGeneration, status: .noContent),
            .finish(.noContent)
        )
        XCTAssertEqual(FallbackOutcome.noContent.unavailableReason, "no_content")

        var failedCoordinator = FallbackPresentationCoordinator()
        let failedGeneration = failedCoordinator.beginLoading()
        XCTAssertEqual(
            failedCoordinator.resolveLoading(generation: failedGeneration, status: .failure),
            .finish(.fetchFailure)
        )
        XCTAssertEqual(FallbackOutcome.fetchFailure.unavailableReason, "fetch_failure")
    }

    func testNoScenePresentationFailureIsUnavailableOnce() {
        var coordinator = FallbackPresentationCoordinator()
        _ = coordinator.beginPresenting()

        XCTAssertEqual(coordinator.presentationUnavailable(), .presentationUnavailable)
        XCTAssertNil(coordinator.presentationUnavailable())
        XCTAssertEqual(
            FallbackOutcome.presentationUnavailable.unavailableReason,
            "presentation_unavailable"
        )
    }

    func testCreativeFailureAdvancesUntilFinalScreenThenResolvesUnavailable() {
        XCTAssertEqual(
            fallbackCreativeFailureResolution(renderedIndex: 0, currentIndex: 0, screenCount: 2),
            .advance
        )
        XCTAssertEqual(
            fallbackCreativeFailureResolution(renderedIndex: 1, currentIndex: 1, screenCount: 2),
            .finishUnavailable
        )
        XCTAssertEqual(
            fallbackCreativeFailureResolution(renderedIndex: 0, currentIndex: 1, screenCount: 2),
            .ignore
        )
    }

    func testEndScreenOneVideoPreparationSkipAdvancesToEndScreenTwoOnce() {
        let generation = UUID()
        let surface = FallbackLoadingSurface.videoPreparation(index: 0, generation: generation)

        XCTAssertEqual(
            fallbackLoadingSkipResolution(
                surface: surface,
                activeInitialFetchGeneration: nil,
                currentIndex: 0,
                currentVideoPreparationGeneration: generation,
                screenCount: 2
            ),
            .resolveVideoPreparationFailure(.advance)
        )
        XCTAssertEqual(
            fallbackLoadingSkipResolution(
                surface: surface,
                activeInitialFetchGeneration: nil,
                currentIndex: 1,
                currentVideoPreparationGeneration: UUID(),
                screenCount: 2
            ),
            .stale,
            "a repeated ES1 Skip must not skip the newly preparing ES2"
        )
    }

    func testFinalVideoPreparationSkipUsesFinalCreativeFailurePolicy() {
        let generation = UUID()

        XCTAssertEqual(
            fallbackLoadingSkipResolution(
                surface: .videoPreparation(index: 1, generation: generation),
                activeInitialFetchGeneration: nil,
                currentIndex: 1,
                currentVideoPreparationGeneration: generation,
                screenCount: 2
            ),
            .resolveVideoPreparationFailure(.finishUnavailable)
        )
    }

    func testInitialFallbackFetchSkipEndsUnavailableExactlyOnce() {
        var coordinator = FallbackPresentationCoordinator()
        let generation = coordinator.beginLoading()
        let surface = FallbackLoadingSurface.initialFetch(generation: generation)

        XCTAssertEqual(
            fallbackLoadingSkipResolution(
                surface: surface,
                activeInitialFetchGeneration: generation,
                currentIndex: 0,
                currentVideoPreparationGeneration: nil,
                screenCount: 0
            ),
            .cancelInitialFetch
        )
        XCTAssertEqual(coordinator.presentationUnavailable(), .presentationUnavailable)
        XCTAssertNil(coordinator.presentationUnavailable())
        XCTAssertEqual(
            fallbackLoadingSkipResolution(
                surface: surface,
                activeInitialFetchGeneration: nil,
                currentIndex: 0,
                currentVideoPreparationGeneration: nil,
                screenCount: 0
            ),
            .stale
        )
    }

    @MainActor
    func testFailedFinalPlayableEarnsInternallyButSubmitsOnlyAtUnitClose() {
        var submissions = 0
        let claim = UnitEndRewardClaim()
        claim.primaryGateDidOpen()
        claim.fallbackDidResolve(renderableScreenCount: 2)
        claim.fallbackGateDidOpen(isFinal: false)

        claim.fallbackBecameUnavailable()
        claim.fallbackBecameUnavailable()
        claim.fallbackDeliveryDidFinish()

        XCTAssertTrue(claim.earned)
        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(claim.consumeAtUnitClose(
            onEarn: { submissions += 1 },
            enqueueVerification: { submissions += 1 }
        ))
        XCTAssertEqual(submissions, 2)
        XCTAssertFalse(claim.consumeAtUnitClose(
            onEarn: { submissions += 1 },
            enqueueVerification: { submissions += 1 }
        ))
        XCTAssertEqual(submissions, 2)
    }

    func testRewardedUnavailableOutcomesFailOpenOnlyForEarnedReward() {
        let unavailable: [FallbackOutcome] = [
            .noContent,
            .loadingTimeout,
            .fetchFailure,
            .presentationUnavailable,
            .hostUnavailable,
        ]

        for outcome in unavailable {
            XCTAssertTrue(outcome.shouldVerifyEarnedReward(true))
            XCTAssertFalse(outcome.shouldVerifyEarnedReward(false))
            XCTAssertNotNil(outcome.unavailableReason)
        }
    }

    @MainActor
    func testHostTeardownCannotPromoteOpenPrimaryGateWithUnresolvedOrRenderableFallback() {
        for configure in [
            { (claim: UnitEndRewardClaim) in claim.primaryGateDidOpen() },
            { (claim: UnitEndRewardClaim) in
                claim.primaryGateDidOpen()
                claim.fallbackDidResolve(renderableScreenCount: 2)
            },
        ] {
            let claim = UnitEndRewardClaim()
            configure(claim)
            var callbacks = 0

            XCTAssertFalse(consumeAlreadyAuthoritativeUnitEndRewardOnHostTeardown(
                claim,
                onEarn: { callbacks += 1 },
                enqueueVerification: { callbacks += 1 }
            ))
            XCTAssertFalse(claim.earned)
            XCTAssertEqual(callbacks, 0)
        }
    }

    @MainActor
    func testHostTeardownConsumesAlreadyAuthoritativeFinalFallbackRewardOnce() {
        let claim = UnitEndRewardClaim()
        claim.primaryGateDidOpen()
        claim.fallbackDidResolve(renderableScreenCount: 2)
        claim.fallbackGateDidOpen(isFinal: true)
        var events: [String] = []

        XCTAssertTrue(consumeAlreadyAuthoritativeUnitEndRewardOnHostTeardown(
            claim,
            onEarn: { events.append("earned") },
            enqueueVerification: { events.append("queue") }
        ))
        XCTAssertFalse(consumeAlreadyAuthoritativeUnitEndRewardOnHostTeardown(
            claim,
            onEarn: { events.append("duplicate") },
            enqueueVerification: { events.append("duplicate") }
        ))
        XCTAssertEqual(events, ["earned", "queue"])
    }

    func testFallbackFetchRetriesOnceAfterBoundedDelay() async {
        let recorder = FallbackRetryRecorder()
        do {
            _ = try await fetchFallbackAdsWithRetry(
                fetch: {
                    await recorder.recordAttempt()
                    throw URLError(.timedOut)
                },
                sleep: { delay in await recorder.recordDelay(delay) }
            )
            XCTFail("Expected final fetch failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let attemptCount = await recorder.attemptCount
        let delays = await recorder.delays
        XCTAssertEqual(attemptCount, fallbackFetchMaximumAttempts)
        XCTAssertEqual(delays, [fallbackFetchRetryDelay])
    }

    func testFallbackFetchCancellationStopsBeforeSecondAttempt() async {
        let recorder = FallbackRetryRecorder()
        let task = Task {
            try await fetchFallbackAdsWithRetry(
                fetch: {
                    await recorder.recordAttempt()
                    throw URLError(.timedOut)
                },
                sleep: { _ in try await Task.sleep(nanoseconds: 10_000_000_000) }
            )
        }
        while await recorder.attemptCount == 0 { await Task.yield() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let attemptCount = await recorder.attemptCount
        XCTAssertEqual(attemptCount, 1)
    }

    func testFallbackOutcomesUseCanonicalExpectedStepCloseReasons() {
        XCTAssertNil(FallbackOutcome.completed.videoPlanCloseReason)
        XCTAssertEqual(FallbackOutcome.noContent.videoPlanCloseReason, "no_next_step")
        XCTAssertEqual(FallbackOutcome.loadingTimeout.videoPlanCloseReason, "next_step_timeout")
        XCTAssertEqual(FallbackOutcome.fetchFailure.videoPlanCloseReason, "next_step_failed")
        XCTAssertEqual(FallbackOutcome.presentationUnavailable.videoPlanCloseReason, "next_step_failed")
        XCTAssertEqual(FallbackOutcome.hostUnavailable.videoPlanCloseReason, "next_step_failed")
    }

    func testFallbackTelemetryIdentifierContractMatchesEachAdFormat() {
        XCTAssertEqual(
            FallbackTelemetryIdentifiers.rewarded(impressionId: "rewarded-impression"),
            FallbackTelemetryIdentifiers(adId: "rewarded-impression", serveId: nil)
        )
        XCTAssertEqual(
            FallbackTelemetryIdentifiers.interstitial(impressionId: "interstitial-impression"),
            FallbackTelemetryIdentifiers(
                adId: "interstitial-impression",
                serveId: "interstitial-impression"
            )
        )
    }

    func testTimeoutMakesLateFetchAndStaleGenerationNoOps() {
        var coordinator = FallbackPresentationCoordinator()
        let staleGeneration = coordinator.beginLoading()
        XCTAssertEqual(coordinator.loadingTimedOut(generation: staleGeneration), .loadingTimeout)
        XCTAssertEqual(
            coordinator.resolveLoading(generation: staleGeneration, status: .content),
            .stale
        )

        let currentGeneration = coordinator.beginLoading()
        XCTAssertNil(coordinator.loadingTimedOut(generation: staleGeneration))
        XCTAssertEqual(
            coordinator.resolveLoading(generation: staleGeneration, status: .failure),
            .stale
        )
        XCTAssertEqual(
            coordinator.resolveLoading(generation: currentGeneration, status: .content),
            .presentContent
        )
    }
}

private actor FallbackRetryRecorder {
    private(set) var attemptCount = 0
    private(set) var delays: [TimeInterval] = []

    func recordAttempt() { attemptCount += 1 }
    func recordDelay(_ delay: TimeInterval) { delays.append(delay) }
}
