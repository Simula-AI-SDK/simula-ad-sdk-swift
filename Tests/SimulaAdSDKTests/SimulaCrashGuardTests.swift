import Foundation
import XCTest
@testable import SimulaAdSDK

final class SimulaCrashGuardTests: XCTestCase {
    func testFingerprintMatchesCrossPlatformVectors() {
        XCTAssertEqual(SimulaMetricKitParser.fingerprint(for: ["foo", "bar"]), "5863d9458c1038de")
    }

    func testAttributedNestedSDKFrameIsAcceptedWithStableFingerprint() {
        let data = Data(
            """
            {
              "callStacks": [{
                "threadAttributed": true,
                "callStackRootFrames": [{
                  "binaryName": "HostApp",
                  "subFrames": [{
                    "binaryName": "SimulaAdSDK",
                    "binaryUUID": "ABC",
                    "offsetIntoBinaryTextSegment": 42
                  }]
                }]
              }]
            }
            """.utf8
        )

        let result = SimulaMetricKitParser.attribution(from: data)

        XCTAssertEqual(result?.frames, ["SimulaAdSDK uuid=ABC offset=42"])
        XCTAssertEqual(result?.fingerprint, "d54efbff7f17ef15")
    }

    func testSDKFrameOnNonAttributedThreadIsRejected() {
        let data = Data(
            """
            {
              "callStackTree": {
                "callStacks": [{
                  "threadAttributed": false,
                  "callStackRootFrames": [{
                    "binaryName": "SimulaAdSDK",
                    "binaryUUID": "ABC",
                    "offsetIntoBinaryTextSegment": 42
                  }]
                }]
              }
            }
            """.utf8
        )

        XCTAssertNil(SimulaMetricKitParser.attribution(from: data))
    }

    func testMissingThreadAttributionIsRejected() {
        let data = Data(
            """
            {
              "callStacks": [{
                "callStackRootFrames": [{
                  "binaryName": "SimulaAdSDK",
                  "offsetIntoBinaryTextSegment": 42
                }]
              }]
            }
            """.utf8
        )

        XCTAssertNil(SimulaMetricKitParser.attribution(from: data))
    }

    func testMalformedAndOversizedTreesFailClosed() {
        XCTAssertNil(SimulaMetricKitParser.attribution(from: Data("{".utf8)))
        XCTAssertNil(
            SimulaMetricKitParser.attribution(
                from: Data(repeating: 0, count: 1024 * 1024 + 1)
            )
        )
    }

    func testWatchdogClassificationIsLowCardinality() {
        let processExit = SimulaMetricKitParser.watchdogContext(
            from: "0x8BADF00D WatchdogEvent: process-exit WatchdogVisibility: Background"
        )
        XCTAssertEqual(processExit?.event, "process_exit")
        XCTAssertEqual(processExit?.visibility, "background")

        let sceneUpdate = SimulaMetricKitParser.watchdogContext(
            from: "scene-update watchdog transgression ProcessVisibility: Foreground"
        )
        XCTAssertEqual(sceneUpdate?.event, "scene_update")
        XCTAssertEqual(sceneUpdate?.visibility, "foreground")

        XCTAssertNil(SimulaMetricKitParser.watchdogContext(from: "ordinary SIGKILL"))
    }

    func testIncidentBreadcrumbUsesExistingBoundedFields() {
        let attribution = SimulaMetricKitAttribution(
            frames: ["SimulaAdSDK uuid=ABC offset=42"],
            fingerprint: "d54efbff7f17ef15"
        )
        let result = SimulaMetricKitParser.incidentBreadcrumb(
            fatal: "watchdog",
            watchdog: (event: "scene_update", visibility: "foreground"),
            attribution: attribution,
            applicationVersion: "1.2.3",
            applicationBuild: "456",
            windowStart: Date(timeIntervalSince1970: 1),
            windowEnd: Date(timeIntervalSince1970: 2)
        )

        XCTAssertLessThanOrEqual(result.breadcrumb.count, 300)
        XCTAssertTrue(result.breadcrumb.contains("event=scene_update"))
        XCTAssertTrue(result.breadcrumb.contains("visibility=foreground"))
        XCTAssertTrue(result.breadcrumb.contains("fp=d54efbff7f17ef15"))
        XCTAssertTrue(result.breadcrumb.contains("appVersion=1.2.3"))
        XCTAssertTrue(result.breadcrumb.contains("appBuild=456"))
        XCTAssertTrue(result.breadcrumb.contains("windowStartMs=1000"))
        XCTAssertTrue(result.breadcrumb.contains("windowEndMs=2000"))
        XCTAssertEqual(result.dedupe, attribution.fingerprint)
    }
}
