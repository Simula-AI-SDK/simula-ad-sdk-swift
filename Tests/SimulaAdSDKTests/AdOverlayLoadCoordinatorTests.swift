import XCTest
@testable import SimulaAdSDK

final class AdOverlayLoadCoordinatorTests: XCTestCase {
    func testHungCurrentLoadTimesOutButLateFinishCanRecover() {
        var coordinator = AdOverlayLoadCoordinator()
        let generation = coordinator.beginLoad()

        XCTAssertTrue(coordinator.timeout(generation: generation))
        XCTAssertEqual(coordinator.phase, .timedOut(generation))
        XCTAssertFalse(coordinator.isLoading)
        XCTAssertTrue(coordinator.isTimedOut)
        XCTAssertTrue(coordinator.finishCurrentLoad())
        XCTAssertEqual(coordinator.phase, .finished(generation))
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
}
