import XCTest
@testable import SimulaAdSDK

final class StoreDwellTelemetryTests: XCTestCase {
    func testStoreDwellWireKeysAreFlatSnakeCase() throws {
        var event = TelemetryEvent(
            type: TelemetryType.lifecycle,
            name: "store_returned",
            eventId: "event",
            timestamp: 1
        )
        event.endEvent = "app_foreground"
        event.opens = 2
        event.contaminated = true
        event.freeSpaceDeltaBytes = -512

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        XCTAssertEqual(object["end_event"] as? String, "app_foreground")
        XCTAssertEqual(object["opens"] as? Int, 2)
        XCTAssertEqual(object["contaminated"] as? Bool, true)
        XCTAssertEqual(object["free_space_delta_bytes"] as? Int, -512)
        XCTAssertNil(object["endEvent"])
        XCTAssertNil(object["freeSpaceDeltaBytes"])
    }

    func testSwiftStoreDwellLeavesContaminationAndFreeSpaceAbsent() throws {
        var event = TelemetryEvent(
            type: TelemetryType.lifecycle,
            name: "store_opened",
            eventId: "event",
            timestamp: 1
        )
        event.opens = 1

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        XCTAssertEqual(object["opens"] as? Int, 1)
        XCTAssertNil(object["contaminated"])
        XCTAssertNil(object["free_space_delta_bytes"])
    }

    @MainActor
    func testOnlyAppStoreURLsClassifyAsExternalStoreDwell() throws {
        let store = try XCTUnwrap(URL(string: "itms-apps://apps.apple.com/app/id375380948"))
        let browser = try XCTUnwrap(URL(string: "https://example.com/landing"))
        let custom = try XCTUnwrap(URL(string: "advertiser-app://offer/42"))

        XCTAssertEqual(externalStoreDwellRoute(for: store), .externalAppStore)
        XCTAssertNil(externalStoreDwellRoute(for: browser))
        XCTAssertNil(externalStoreDwellRoute(for: custom))
    }

    func testStoreDwellTriggerPreservesFallbackSource() {
        XCTAssertEqual(ClickSource.primaryCTA.storeDwellTrigger, "cta")
        XCTAssertEqual(ClickSource.fallbackCTA.storeDwellTrigger, "fallback_cta")
        XCTAssertEqual(ClickSource.storePrompt.storeDwellTrigger, "store_prompt")
        XCTAssertEqual(ClickSource.autoRedirect.storeDwellTrigger, "auto_redirect")
    }

    @MainActor
    func testSuccessfulRouteCarriesOnlyExplicitStoreClassification() {
        var outcomes: [AttributionRouteOutcome] = []
        let safari = AttributionRouteExecution(isActive: { true }) { outcomes.append($0) }
        XCTAssertTrue(safari.begin(path: .web))
        safari.complete { true }

        let store = AttributionRouteExecution(isActive: { true }) { outcomes.append($0) }
        XCTAssertTrue(store.begin(path: .directStore, storeDwellRoute: .storeProductSheet))
        store.complete { true }

        let failedStore = AttributionRouteExecution(isActive: { true }) { outcomes.append($0) }
        XCTAssertTrue(failedStore.begin(path: .directStore, storeDwellRoute: .storeProductSheet))
        failedStore.complete { false }

        XCTAssertNil(outcomes[0].storeDwellRoute)
        XCTAssertEqual(outcomes[1].storeDwellRoute, .storeProductSheet)
        XCTAssertNil(outcomes[2].storeDwellRoute)
    }

    @MainActor
    func testExternalStoreClassificationRequiresAcceptedSystemOpen() async {
        var outcomes: [AttributionRouteOutcome] = []
        var rejectedCompletion: ((Bool) -> Void)?
        let rejected = AttributionRouteExecution(isActive: { true }) { outcomes.append($0) }
        XCTAssertTrue(rejected.begin(path: .directStore, storeDwellRoute: .externalAppStore))
        rejected.completeExternalOpen { rejectedCompletion = $0 }
        rejectedCompletion?(false)
        await Task.yield()

        var acceptedCompletion: ((Bool) -> Void)?
        let accepted = AttributionRouteExecution(isActive: { true }) { outcomes.append($0) }
        XCTAssertTrue(accepted.begin(path: .directStore, storeDwellRoute: .externalAppStore))
        accepted.completeExternalOpen { acceptedCompletion = $0 }
        acceptedCompletion?(true)
        await Task.yield()

        XCTAssertEqual(outcomes.count, 2)
        XCTAssertFalse(outcomes[0].success)
        XCTAssertNil(outcomes[0].storeDwellRoute)
        XCTAssertTrue(outcomes[1].success)
        XCTAssertEqual(outcomes[1].storeDwellRoute, .externalAppStore)
    }

    @MainActor
    func testDeferredAutomaticExternalOpenStopsAfterPresentationTeardown() {
        var active = true
        var routeCalls = 0
        var outcomes: [AttributionRouteOutcome] = []
        let execution = AttributionRouteExecution(
            isActive: { active },
            onOutcome: { outcomes.append($0) }
        )
        XCTAssertTrue(execution.begin(path: .mmpRedirect))
        active = false

        execution.completeExternalOpen(storeDwellRoute: .externalAppStore) { _ in
            routeCalls += 1
        }

        XCTAssertEqual(routeCalls, 0)
        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .mmpRedirect,
            success: false,
            failureClass: "inactive_presentation"
        )])
    }

    @MainActor
    func testCommittedExternalOpenCanFinishAfterTeardownWhenTerminalContextIsSafe() async {
        var active = true
        var completion: ((Bool) -> Void)?
        var outcomes: [AttributionRouteOutcome] = []
        let execution = AttributionRouteExecution(
            isActive: { active },
            survivesPresentationTeardownAfterBegin: true,
            canCompleteAfterPresentationTeardown: { true },
            onOutcome: { outcomes.append($0) }
        )
        XCTAssertTrue(execution.begin(path: .mmpRedirect))
        active = false

        execution.completeExternalOpen(storeDwellRoute: .externalAppStore) {
            completion = $0
        }
        completion?(true)
        await Task.yield()

        XCTAssertEqual(outcomes, [AttributionRouteOutcome(
            path: .mmpRedirect,
            success: true,
            failureClass: nil,
            storeDwellRoute: .externalAppStore
        )])
    }
}
