import XCTest
@testable import SimulaAdSDK

@MainActor
final class StoreExitTrackerTests: XCTestCase {
    @MainActor
    private final class Harness {
        var now: Double = 1_000
        var events: [StoreDwellLifecycleEvent] = []
        var launchTimeouts = 0
        var scheduled: [() -> Void] = []

        func makeTracker() -> StoreExitTracker {
            StoreExitTracker(
                adId: "ad",
                adFormat: "interstitial",
                adUnitId: "unit",
                now: { self.now },
                recorder: { self.events.append($0) },
                recordLaunchWithoutAway: { self.launchTimeouts += 1 },
                schedule: { _, action in
                    self.scheduled.append(action)
                    // Deliberately do not suppress cancelled callbacks. Generation checks must make
                    // stale timer delivery harmless even when a scheduler races cancellation.
                    return StoreDwellScheduledAction(cancellation: {})
                }
            )
        }
    }

    func testExternalOpenRequiresAwayThenReturnsOnForeground() {
        let harness = Harness()
        let tracker = harness.makeTracker()

        harness.now = 1_100
        tracker.recordStoreOpen("cta", route: .externalAppStore)
        XCTAssertTrue(harness.events.isEmpty)

        harness.now = 1_150
        tracker.onAppAway()
        XCTAssertEqual(harness.events, [StoreDwellLifecycleEvent(
            stage: "store_opened",
            durationMs: 150,
            trigger: "cta",
            endEvent: nil,
            opens: 1
        )])

        harness.now = 3_650
        tracker.onAppForeground()
        XCTAssertEqual(harness.events.last, StoreDwellLifecycleEvent(
            stage: "store_returned",
            durationMs: 2_500,
            trigger: "cta",
            endEvent: .appForeground,
            opens: 1
        ))
    }

    func testExternalOpenWithoutAwayTimesOutWithoutFalseAbandonment() throws {
        let harness = Harness()
        let tracker = harness.makeTracker()

        tracker.recordStoreOpen("cta", route: .externalAppStore)
        let timeout = try XCTUnwrap(harness.scheduled.first)
        timeout()
        tracker.onAdClosed()

        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertEqual(harness.launchTimeouts, 1)
    }

    func testSheetAndAppReasonsCannotResolveEachOther() {
        let harness = Harness()
        let tracker = harness.makeTracker()

        harness.now = 1_100
        tracker.onSheetPresented()
        tracker.recordStoreOpen("store_prompt", route: .storeProductSheet)
        tracker.onAppAway()
        harness.now = 1_500
        tracker.onAppForeground()
        XCTAssertEqual(harness.events.map(\.stage), ["store_opened"])

        harness.now = 2_100
        tracker.onSheetDismissed()
        XCTAssertEqual(harness.events.last?.endEvent, .sheetDismissed)
        XCTAssertEqual(harness.events.last?.durationMs, 1_000)

        harness.now = 2_200
        tracker.recordStoreOpen("cta", route: .externalAppStore)
        tracker.onAppAway()
        tracker.onSheetPresented()
        harness.now = 2_400
        tracker.onSheetDismissed()
        XCTAssertEqual(harness.events.filter { $0.stage == "store_returned" }.count, 1)
        harness.now = 2_700
        tracker.onAppForeground()
        XCTAssertEqual(harness.events.last?.endEvent, .appForeground)
    }

    func testOpenOrdinalContinuesAcrossPrimaryAndFallbackAndAbandonUsesAdClosed() {
        let harness = Harness()
        let tracker = harness.makeTracker()

        tracker.onSheetPresented()
        tracker.recordStoreOpen("cta", route: .storeProductSheet)
        harness.now = 1_200
        tracker.onSheetDismissed()

        harness.now = 1_300
        tracker.onSheetPresented()
        tracker.recordStoreOpen("auto_redirect", route: .storeProductSheet)
        harness.now = 1_400
        tracker.onAdClosed()

        XCTAssertEqual(harness.events.map(\.opens), [1, 1, 2, 2])
        XCTAssertEqual(harness.events.last, StoreDwellLifecycleEvent(
            stage: "store_abandoned",
            durationMs: nil,
            trigger: "auto_redirect",
            endEvent: .adClosed,
            opens: 2
        ))
    }

    func testCancelledLaunchTimerCannotClearANewerVisit() throws {
        let harness = Harness()
        let tracker = harness.makeTracker()

        tracker.recordStoreOpen("cta", route: .externalAppStore)
        let staleTimeout = try XCTUnwrap(harness.scheduled.first)
        tracker.onAppAway()
        tracker.onAppForeground()

        tracker.recordStoreOpen("store_prompt", route: .externalAppStore)
        staleTimeout()
        tracker.onAppAway()

        XCTAssertEqual(harness.launchTimeouts, 0)
        XCTAssertEqual(harness.events.filter { $0.stage == "store_opened" }.map(\.opens), [1, 2])
    }

    func testAdCloseIsTerminalAndLateAcceptedRouteCannotCreateAVisit() {
        let harness = Harness()
        let tracker = harness.makeTracker()

        tracker.onAdClosed()
        tracker.recordStoreOpen("cta", route: .externalAppStore)
        tracker.onAppAway()
        tracker.onAppForeground()
        tracker.onSheetPresented()
        tracker.recordStoreOpen("store_prompt", route: .storeProductSheet)
        tracker.onSheetDismissed()
        tracker.onAdClosed()

        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertTrue(harness.scheduled.isEmpty)
        XCTAssertEqual(harness.launchTimeouts, 0)
    }

    func testOpenOrdinalSaturatesAtBackendLimit() {
        let harness = Harness()
        let tracker = harness.makeTracker()

        for _ in 0..<1_001 {
            tracker.onSheetPresented()
            tracker.recordStoreOpen("fallback_cta", route: .storeProductSheet)
            tracker.onSheetDismissed()
        }

        let opened = harness.events.filter { $0.stage == "store_opened" }
        XCTAssertEqual(opened.count, 1_001)
        XCTAssertEqual(opened[999].opens, 1_000)
        XCTAssertEqual(opened[1_000].opens, 1_000)
        XCTAssertEqual(harness.events.last?.opens, 1_000)
    }
}
