import XCTest
@testable import SimulaAdSDK

final class FullscreenGateClockTests: XCTestCase {
    func testPauseCapturesFractionalTimeInsteadOfRewindingToLastTick() {
        var clock = FullscreenGateClock()
        clock.resume(at: 10)
        clock.update(at: 14, total: 10)

        clock.pause(at: 14.7, total: 10)

        XCTAssertEqual(clock.elapsed, 4.7, accuracy: 0.000_001)
        XCTAssertEqual(clock.progress(total: 10), 0.47, accuracy: 0.000_001)
        XCTAssertEqual(clock.secondsRemaining(total: 10), 6)
    }

    func testResumeExcludesStoreSheetTimeAndContinuesFromFractionalProgress() {
        var clock = FullscreenGateClock()
        clock.resume(at: 10)
        clock.pause(at: 14.7, total: 10)

        clock.resume(at: 30)
        XCTAssertEqual(clock.timeUntilNextTick(total: 10), 0.3, accuracy: 0.000_001)
        clock.update(at: 31.3, total: 10)

        XCTAssertEqual(clock.elapsed, 6, accuracy: 0.000_001)
        XCTAssertEqual(clock.progress(total: 10), 0.6, accuracy: 0.000_001)
        XCTAssertEqual(clock.secondsRemaining(total: 10), 4)
    }

    func testElapsedTimeIsMonotonicAndClampedToGateDuration() {
        var clock = FullscreenGateClock()
        clock.resume(at: 10)
        clock.update(at: 9, total: 5)
        XCTAssertEqual(clock.elapsed, 0)

        clock.update(at: 20, total: 5)
        XCTAssertEqual(clock.elapsed, 5)
        XCTAssertEqual(clock.progress(total: 5), 1)
        XCTAssertEqual(clock.secondsRemaining(total: 5), 0)
    }

    func testRepeatedPauseDoesNotAccrueTimeWhileAlreadyPaused() {
        var clock = FullscreenGateClock()
        clock.resume(at: 10)
        clock.pause(at: 14.7, total: 10)

        clock.pause(at: 25, total: 10)

        XCTAssertEqual(clock.elapsed, 4.7, accuracy: 0.000_001)
        XCTAssertEqual(clock.progress(total: 10), 0.47, accuracy: 0.000_001)
        XCTAssertEqual(clock.secondsRemaining(total: 10), 6)
    }
}
