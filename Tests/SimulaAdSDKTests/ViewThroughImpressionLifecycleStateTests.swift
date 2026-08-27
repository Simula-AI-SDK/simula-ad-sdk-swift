import XCTest
@testable import SimulaAdSDK

final class ViewThroughImpressionLifecycleStateTests: XCTestCase {
    func testStartsAndEndsOnceWithSameImpression() {
        var state = ViewThroughImpressionLifecycleState<NSObject>()
        let impression = NSObject()
        var started: NSObject?
        var ended: NSObject?

        state.markCreativeReady()
        state.start(makeImpression: { impression }) { started = $0 }
        state.start(makeImpression: { NSObject() }) { _ in XCTFail("started twice") }
        state.end { ended = $0 }
        state.end { _ in XCTFail("ended twice") }

        XCTAssertTrue(started === impression)
        XCTAssertTrue(ended === impression)
        XCTAssertTrue(state.didAttemptStart)
        XCTAssertTrue(state.didEnd)
        XCTAssertNil(state.impression)
    }

    func testEndBeforeStartPreventsLateStart() {
        var state = ViewThroughImpressionLifecycleState<NSObject>()

        state.markCreativeReady()
        state.end { _ in XCTFail("ended an impression that never started") }
        state.start(makeImpression: { NSObject() }) { _ in XCTFail("started after visibility ended") }

        XCTAssertFalse(state.didAttemptStart)
        XCTAssertTrue(state.didEnd)
        XCTAssertNil(state.impression)
    }

    func testTemporaryInterruptionBeforeStartDoesNotPreventLaterStart() {
        var state = ViewThroughImpressionLifecycleState<NSObject>()
        let impression = NSObject()
        var started: NSObject?

        state.endIfStarted { _ in XCTFail("ended an impression that never started") }
        state.markCreativeReady()
        state.start(makeImpression: { impression }) { started = $0 }

        XCTAssertTrue(started === impression)
        XCTAssertTrue(state.didAttemptStart)
        XCTAssertFalse(state.didEnd)
    }

    func testReadyCreativeRetriesStartAfterTemporaryIneligibility() {
        var state = ViewThroughImpressionLifecycleState<NSObject>()
        let impression = NSObject()
        var started: NSObject?

        state.markCreativeReady()
        state.endIfStarted { _ in XCTFail("ended an impression that never started") }
        state.start(makeImpression: { impression }) { started = $0 }

        XCTAssertTrue(state.isCreativeReady)
        XCTAssertTrue(started === impression)
    }

    func testStartWaitsForCreativeReadiness() {
        var state = ViewThroughImpressionLifecycleState<NSObject>()
        let impression = NSObject()
        var starts = 0

        state.start(makeImpression: { impression }) { _ in starts += 1 }
        state.markCreativeReady()
        state.start(makeImpression: { impression }) { _ in starts += 1 }

        XCTAssertEqual(starts, 1)
    }

    func testFailedConstructionIsAttemptedOnlyOnce() {
        var state = ViewThroughImpressionLifecycleState<NSObject>()
        var constructions = 0

        state.markCreativeReady()
        state.start(makeImpression: {
            constructions += 1
            return nil
        }) { _ in XCTFail("started without an impression") }
        state.start(makeImpression: {
            constructions += 1
            return NSObject()
        }) { _ in XCTFail("retried a rejected payload") }

        XCTAssertEqual(constructions, 1)
        XCTAssertTrue(state.didAttemptStart)
        XCTAssertNil(state.impression)
    }
}
