#if os(iOS)
import XCTest
@testable import SimulaAdSDK

/// Pure-logic tests for the native error taxonomy: telemetry codes + the internal mapping from the
/// shared `SimulaAdError` (what the load path throws) to the scoped `NativeAdError` surface. Mirrors
/// the Kotlin SDK's `NativeAdErrorTest`.
final class NativeAdErrorTests: XCTestCase {

    func testTelemetryCodesMatchSharedTaxonomy() {
        XCTAssertEqual(NativeAdError.notInitialized.telemetryCode, "not_initialized")
        XCTAssertEqual(NativeAdError.noSession.telemetryCode, "no_session")
        XCTAssertEqual(NativeAdError.noFill.telemetryCode, "no_fill")
        XCTAssertEqual(NativeAdError.network.telemetryCode, "network")
    }

    func testMapsTheFourNativeLoadPathCases() {
        XCTAssertEqual(NativeAdError(SimulaAdError.notInitialized), .notInitialized)
        XCTAssertEqual(NativeAdError(SimulaAdError.noSession), .noSession)
        XCTAssertEqual(NativeAdError(SimulaAdError.noFill), .noFill)
        XCTAssertEqual(NativeAdError(SimulaAdError.network(.invalidResponse)), .network)
    }

    func testMapsNonNativeCasesDefensivelyToNetwork() {
        XCTAssertEqual(NativeAdError(SimulaAdError.notReady), .network)
        XCTAssertEqual(NativeAdError(SimulaAdError.stale), .network)
        XCTAssertEqual(NativeAdError(SimulaAdError.alreadyShowing), .network)
        XCTAssertEqual(NativeAdError(SimulaAdError.noPresentationContext), .network)
    }
}
#endif
