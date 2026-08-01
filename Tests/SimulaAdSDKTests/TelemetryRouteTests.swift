import XCTest
@testable import SimulaAdSDK

final class TelemetryRouteTests: XCTestCase {
    func testStaticFirstPartyRoutesPassThrough() {
        // The full registered static allowlist — keep in sync with TelemetryURLSessionDelegate
        // and the Kotlin SimulaHttp route registry (contract: same templates and tests).
        let staticRoutes = [
            "/session/create",
            "/frequency-cap/status",
            "/minigames/catalog",
            "/character-selector",
            "/load/interstitial",
            "/load/native",
            "/load/rewarded",
            "/minigames/verify-reward",
            "/minigames/init",
            "/minigames/menu/track/click",
        ]
        for route in staticRoutes {
            XCTAssertEqual(normalizedTelemetryRoute(route), route)
        }
    }

    func testDynamicIdentifiersAreNormalized() {
        XCTAssertEqual(normalizedTelemetryRoute("/impressions/secret-id/shown"), "/impressions/:id/shown")
        XCTAssertEqual(normalizedTelemetryRoute("/impressions/secret-id/seen"), "/impressions/:id/seen")
        XCTAssertEqual(normalizedTelemetryRoute("/impressions/secret-id/click"), "/impressions/:id/click")
        XCTAssertEqual(normalizedTelemetryRoute("/impressions/secret-id/interest"), "/impressions/:id/interest")
        XCTAssertEqual(normalizedTelemetryRoute("/impressions/secret-id/report"), "/impressions/:id/report")
        XCTAssertEqual(normalizedTelemetryRoute("/load/fallbacks/secret-id"), "/load/fallbacks/:id")
    }

    func testSensitiveAndRecursiveRoutesAreDropped() {
        XCTAssertNil(normalizedTelemetryRoute("/telemetry/events"))
        XCTAssertNil(normalizedTelemetryRoute("/v1/telemetry/events"))
        XCTAssertNil(normalizedTelemetryRoute("/session/session-id/ppid/user-id"))
        XCTAssertNil(normalizedTelemetryRoute("/future/ppid/user-id"))
    }

    func testUnknownRoutesFailClosed() {
        XCTAssertEqual(normalizedTelemetryRoute("/new/path/private-value"), "/unknown")
        XCTAssertEqual(normalizedTelemetryRoute("/impressions/id/unbounded-action"), "/unknown")
        XCTAssertEqual(normalizedTelemetryRoute("/"), "/unknown")
    }
}
