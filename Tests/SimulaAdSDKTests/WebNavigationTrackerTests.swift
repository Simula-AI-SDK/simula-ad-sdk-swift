import XCTest
@testable import SimulaAdSDK

final class WebNavigationTrackerTests: XCTestCase {
    func testRebindThenNilReturningLoadAcceptsNewNavigationAndRejectsOldCompletion() {
        var tracker = WebNavigationTracker<ObjectIdentifier>()
        let old = NSObject()
        let fresh = NSObject()
        let oldToken = ObjectIdentifier(old)
        let freshToken = ObjectIdentifier(fresh)

        tracker.trackRequested(oldToken)
        XCTAssertTrue(tracker.didStart(oldToken))

        tracker.resetForRebind()
        tracker.trackRequested(nil)

        XCTAssertFalse(tracker.didStart(oldToken))
        XCTAssertTrue(tracker.didStart(freshToken))
        XCTAssertFalse(tracker.didFinish(oldToken))
        XCTAssertTrue(tracker.didFinish(freshToken))
    }

    func testNilRequestedNavigationClearsStaleTokens() {
        var tracker = WebNavigationTracker<Int>()
        tracker.trackRequested(1)

        tracker.trackRequested(nil)

        XCTAssertNil(tracker.active)
        XCTAssertNil(tracker.requested)
        XCTAssertFalse(tracker.didStart(1))
        XCTAssertTrue(tracker.didStart(2))
    }

    func testStaleFailureAfterRebindCannotFailFreshNavigation() {
        var tracker = WebNavigationTracker<Int>()
        tracker.trackRequested(10)
        XCTAssertTrue(tracker.didStart(10))
        tracker.resetForRebind()
        tracker.trackRequested(nil)
        XCTAssertTrue(tracker.didStart(20))

        XCTAssertFalse(tracker.didFail(10))
        XCTAssertTrue(tracker.isActive(20))
        XCTAssertTrue(tracker.didFinish(20))
    }

    func testFreshRequestRehabilitatesARejectedReusedToken() {
        var tracker = WebNavigationTracker<Int>()
        tracker.trackRequested(1)
        XCTAssertTrue(tracker.didStart(1))
        tracker.resetForRebind()
        XCTAssertFalse(tracker.didStart(1))

        tracker.trackRequested(1)

        XCTAssertTrue(tracker.didStart(1))
        XCTAssertTrue(tracker.isActive(1))
        XCTAssertTrue(tracker.didFinish(1))
    }
}
