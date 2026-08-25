import XCTest
@testable import SimulaAdSDK

final class FallbackOutcomeTests: XCTestCase {
    func testFallbackAdvanceRequiresCurrentScreenWithoutPendingClickRoute() {
        XCTAssertTrue(canAdvanceFallback(renderedIndex: 0, currentIndex: 0, clickHandoffIndex: nil))
        XCTAssertFalse(canAdvanceFallback(renderedIndex: 0, currentIndex: 0, clickHandoffIndex: 0))
        XCTAssertFalse(canAdvanceFallback(renderedIndex: 0, currentIndex: 1, clickHandoffIndex: nil))
        XCTAssertTrue(canAdvanceFallback(renderedIndex: 1, currentIndex: 1, clickHandoffIndex: 0))
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
        coordinator.beginPresenting()

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
        coordinator.beginPresenting()

        XCTAssertEqual(coordinator.presentationUnavailable(), .presentationUnavailable)
        XCTAssertNil(coordinator.presentationUnavailable())
        XCTAssertEqual(
            FallbackOutcome.presentationUnavailable.unavailableReason,
            "presentation_unavailable"
        )
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
