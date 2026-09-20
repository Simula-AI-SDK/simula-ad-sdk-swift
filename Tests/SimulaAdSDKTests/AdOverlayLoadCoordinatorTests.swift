import XCTest
@testable import SimulaAdSDK

final class AdOverlayLoadCoordinatorTests: XCTestCase {
    func testHungCurrentLoadTimesOutAndLateFinishCannotPresent() {
        var coordinator = AdOverlayLoadCoordinator()
        let generation = coordinator.beginLoad()

        XCTAssertTrue(coordinator.timeout(generation: generation))
        XCTAssertEqual(coordinator.phase, .timedOut(generation))
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertTrue(coordinator.isTimedOut)
        XCTAssertFalse(coordinator.finishCurrentLoad())
        XCTAssertEqual(coordinator.phase, .timedOut(generation))
    }

    func testMountFiresOnceBeforeTimeoutAndLateFinishCannotDuplicateIt() {
        var mount = AdOverlayScreenMountCoordinator()
        var load = AdOverlayLoadCoordinator()
        let generation = load.beginLoad()

        XCTAssertTrue(mount.scheduleIfNeeded())
        XCTAssertTrue(mount.markDelivered())
        XCTAssertTrue(load.timeout(generation: generation))
        XCTAssertFalse(load.finishCurrentLoad())
        XCTAssertFalse(mount.scheduleIfNeeded())
    }

    func testStaleTimeoutCannotFailReplacementLoad() {
        var coordinator = AdOverlayLoadCoordinator()
        let staleGeneration = coordinator.beginLoad()
        let currentGeneration = coordinator.beginLoad()

        XCTAssertFalse(coordinator.timeout(generation: staleGeneration))
        XCTAssertEqual(coordinator.phase, .loading(currentGeneration))
        XCTAssertTrue(coordinator.timeout(generation: currentGeneration))
    }

    func testFinishCancelsTimeoutOwnership() {
        var coordinator = AdOverlayLoadCoordinator()
        let generation = coordinator.beginLoad()

        XCTAssertTrue(coordinator.finishCurrentLoad())
        XCTAssertEqual(coordinator.phase, .finished(generation))
        XCTAssertFalse(coordinator.timeout(generation: generation))
    }

    func testFailureAndDisappearanceInvalidateWatchdog() {
        var coordinator = AdOverlayLoadCoordinator()
        let failedGeneration = coordinator.beginLoad()
        XCTAssertTrue(coordinator.failCurrentLoad())
        XCTAssertFalse(coordinator.timeout(generation: failedGeneration))

        let disappearedGeneration = coordinator.beginLoad()
        coordinator.cancel()
        XCTAssertTrue(coordinator.isIdle)
        XCTAssertFalse(coordinator.timeout(generation: disappearedGeneration))
    }

    func testFirstFrameBeforeParentAppearReplaysExactlyOnce() {
        var handoff = PendingFirstFrameHandoff<String>()

        XCTAssertFalse(handoff.receive("video-a", parentAppeared: false))
        XCTAssertEqual(handoff.active, "video-a")
        XCTAssertEqual(handoff.pending, "video-a")
        XCTAssertTrue(handoff.replay("video-a"))
        XCTAssertFalse(handoff.replay("video-a"))
        XCTAssertEqual(handoff.admitted, "video-a")
    }

    func testParentAppearBeforeFirstFrameAdmitsImmediateFrameOnce() {
        var handoff = PendingFirstFrameHandoff<String>()
        handoff.activate("video-a")

        XCTAssertFalse(handoff.replay("video-a"))
        XCTAssertTrue(handoff.receive("video-a", parentAppeared: true))
        XCTAssertFalse(handoff.receive("video-a", parentAppeared: true))
    }

    func testFailureBeforePendingFrameReplayPreventsAdmission() {
        var handoff = PendingFirstFrameHandoff<String>()
        handoff.activate("video-a")
        XCTAssertFalse(handoff.receive("video-a", parentAppeared: false))

        XCTAssertTrue(handoff.fail("video-a"))

        XCTAssertNil(handoff.pending)
        XCTAssertTrue(handoff.isTerminal("video-a"))
        XCTAssertFalse(handoff.replay("video-a"))
        XCTAssertFalse(handoff.receive("video-a", parentAppeared: true))
    }

    func testReplacementBeforePendingFrameReplayRejectsStaleSurface() {
        var handoff = PendingFirstFrameHandoff<String>()
        handoff.activate("video-a")
        XCTAssertFalse(handoff.receive("video-a", parentAppeared: false))

        handoff.activate("video-b")

        XCTAssertNil(handoff.pending)
        XCTAssertFalse(handoff.replay("video-a"))
        XCTAssertFalse(handoff.fail("video-a"))
        XCTAssertTrue(handoff.receive("video-b", parentAppeared: true))
    }

    func testReplacementPlayerStaleEscapeCannotClaimCurrentSurface() {
        var handoff = PendingFirstFrameHandoff<String>()
        handoff.activate("player-a")
        handoff.activate("player-b")

        XCTAssertFalse(handoff.claimPreFirstFrameFailure("player-a"))
        XCTAssertTrue(handoff.claimPreFirstFrameFailure("player-b"))
        XCTAssertFalse(handoff.claimPreFirstFrameFailure("player-b"))
        XCTAssertTrue(handoff.isTerminal("player-b"))
    }

    func testDuplicatePendingFrameDoesNotDuplicateReplay() {
        var handoff = PendingFirstFrameHandoff<String>()
        handoff.activate("video-a")

        XCTAssertFalse(handoff.receive("video-a", parentAppeared: false))
        XCTAssertFalse(handoff.receive("video-a", parentAppeared: false))
        XCTAssertTrue(handoff.replay("video-a"))
        XCTAssertFalse(handoff.receive("video-a", parentAppeared: true))
    }

    func testFirstFrameTeardownClearsPendingAndRejectsLateCallbacks() {
        var handoff = PendingFirstFrameHandoff<String>()
        handoff.activate("video-a")
        XCTAssertFalse(handoff.receive("video-a", parentAppeared: false))

        handoff.invalidate()

        XCTAssertFalse(handoff.accepting)
        XCTAssertNil(handoff.active)
        XCTAssertNil(handoff.pending)
        XCTAssertFalse(handoff.replay("video-a"))
        XCTAssertFalse(handoff.receive("video-a", parentAppeared: true))
    }
}
