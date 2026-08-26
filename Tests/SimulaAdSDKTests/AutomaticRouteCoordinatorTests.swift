import XCTest
@testable import SimulaAdSDK

final class AutomaticRouteCoordinatorTests: XCTestCase {
    func testAutomaticRouteStartsOnceWithoutUserHandoff() {
        let coordinator = AutomaticRouteCoordinator()
        let scope = AnyHashable("primary")
        coordinator.activate(scope: scope)
        var starts = 0

        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: scope) { starts += 1 }, .started)
        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: scope) { starts += 1 }, .suppressed)
        XCTAssertEqual(starts, 1)
    }

    func testPendingUserHandoffDefersAndCommitSuppressesAutomaticRoute() throws {
        let coordinator = AutomaticRouteCoordinator()
        let scope = AnyHashable("primary")
        coordinator.activate(scope: scope)
        let handoff = try XCTUnwrap(coordinator.beginUserHandoff(scope: scope))
        var starts = 0

        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: scope) { starts += 1 }, .deferred)
        XCTAssertTrue(coordinator.commitUserHandoff(handoff, scope: scope))
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: scope) { starts += 1 }, .suppressed)
    }

    func testPreCommitCancellationRunsDeferredAutomaticRouteOnce() throws {
        let coordinator = AutomaticRouteCoordinator()
        let scope = AnyHashable("primary")
        coordinator.activate(scope: scope)
        let handoff = try XCTUnwrap(coordinator.beginUserHandoff(scope: scope))
        var starts = 0

        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: scope) { starts += 1 }, .deferred)
        XCTAssertTrue(coordinator.cancelUserHandoff(handoff, scope: scope))
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(coordinator.cancelUserHandoff(handoff, scope: scope))
        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: scope) { starts += 1 }, .suppressed)
    }

    func testCommittedUserRouteBeforeTriggerSuppressesLaterAutomaticRoute() throws {
        let coordinator = AutomaticRouteCoordinator()
        let scope = AnyHashable("primary")
        coordinator.activate(scope: scope)
        let handoff = try XCTUnwrap(coordinator.beginUserHandoff(scope: scope))

        XCTAssertTrue(coordinator.commitUserHandoff(handoff, scope: scope))
        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: scope) {}, .suppressed)
    }

    func testFallbackScopeChangeDropsDeferredAndRejectsStaleCallbacks() throws {
        let coordinator = AutomaticRouteCoordinator()
        let first = AnyHashable("fallback-1")
        let second = AnyHashable("fallback-2")
        coordinator.activate(scope: first)
        let handoff = try XCTUnwrap(coordinator.beginUserHandoff(scope: first))
        var staleStarts = 0

        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: first) { staleStarts += 1 }, .deferred)
        coordinator.activate(scope: second)
        XCTAssertFalse(coordinator.cancelUserHandoff(handoff, scope: first))
        XCTAssertEqual(staleStarts, 0)
        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: first) {}, .stale)

        var currentStarts = 0
        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: second) { currentStarts += 1 }, .started)
        XCTAssertEqual(currentStarts, 1)
    }

    func testCommittedUserRouteSuppressesAutomaticRoutesAcrossFallbackScopes() throws {
        let coordinator = AutomaticRouteCoordinator()
        let first = AnyHashable("fallback-1")
        let second = AnyHashable("fallback-2")
        coordinator.activate(scope: first)
        let handoff = try XCTUnwrap(coordinator.beginUserHandoff(scope: first))
        XCTAssertTrue(coordinator.commitUserHandoff(handoff, scope: first))

        coordinator.activate(scope: second)
        XCTAssertEqual(coordinator.requestAutomaticRoute(scope: second) {}, .suppressed)
    }
}
