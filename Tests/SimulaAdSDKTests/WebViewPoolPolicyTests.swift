import XCTest
@testable import SimulaAdSDK

final class WebViewPoolPolicyTests: XCTestCase {
    func testRetainsOnlyWhenActiveWithinCapacityAndOutsideCooldown() {
        XCTAssertTrue(
            SimulaWebViewPolicy.canRetain(
                maxIdle: 1,
                idleCount: 0,
                applicationActive: true,
                now: 10,
                blockedUntil: 10
            )
        )
        XCTAssertFalse(
            SimulaWebViewPolicy.canRetain(
                maxIdle: 1,
                idleCount: 1,
                applicationActive: true,
                now: 10,
                blockedUntil: 0
            )
        )
        XCTAssertFalse(
            SimulaWebViewPolicy.canRetain(
                maxIdle: 1,
                idleCount: 0,
                applicationActive: false,
                now: 10,
                blockedUntil: 0
            )
        )
        XCTAssertFalse(
            SimulaWebViewPolicy.canRetain(
                maxIdle: 1,
                idleCount: 0,
                applicationActive: true,
                now: 9,
                blockedUntil: 10
            )
        )
    }

    func testConstrainedMemoryPolicyMatchesRetentionCaps() {
        let gib: UInt64 = 1024 * 1024 * 1024
        XCTAssertTrue(SimulaWebViewPolicy.isMemoryConstrained(totalRamBytes: 2 * gib))
        XCTAssertFalse(SimulaWebViewPolicy.isMemoryConstrained(totalRamBytes: 3 * gib))
        XCTAssertEqual(SimulaWebViewPolicy.idleCap(totalRamBytes: 2 * gib), 0)
        XCTAssertEqual(SimulaWebViewPolicy.retainedCap(totalRamBytes: 2 * gib), 1)
        XCTAssertEqual(SimulaWebViewPolicy.idleCap(totalRamBytes: 3 * gib), 1)
        XCTAssertEqual(SimulaWebViewPolicy.retainedCap(totalRamBytes: 3 * gib), 3)
    }

    func testCooldownMatchesAndroidBusinessPolicy() {
        XCTAssertEqual(SimulaWebViewPolicy.cooldown, 300)
    }

    func testPrewarmDecisionsStayCanonical() {
        XCTAssertEqual(
            SimulaWebViewPolicy.prewarmDecision(
                maxIdle: 0, idleCount: 0, applicationActive: true, now: 10, blockedUntil: 0
            ),
            .constrained
        )
        XCTAssertEqual(
            SimulaWebViewPolicy.prewarmDecision(
                maxIdle: 1, idleCount: 1, applicationActive: true, now: 10, blockedUntil: 0
            ),
            .full
        )
        XCTAssertEqual(
            SimulaWebViewPolicy.prewarmDecision(
                maxIdle: 1, idleCount: 0, applicationActive: false, now: 10, blockedUntil: 0
            ),
            .inactive
        )
        XCTAssertEqual(
            SimulaWebViewPolicy.prewarmDecision(
                maxIdle: 1, idleCount: 0, applicationActive: true, now: 9, blockedUntil: 10
            ),
            .cooldown
        )
    }

    func testSkipDiagnosticsAreBoundedToOnePerReason() {
        var gate = SimulaWebViewPrewarmSkipGate()

        for decision in [
            SimulaWebViewPrewarmDecision.constrained,
            .full,
            .inactive,
            .cooldown,
        ] {
            XCTAssertTrue(gate.shouldRecord(decision))
            XCTAssertFalse(gate.shouldRecord(decision))
        }
        XCTAssertFalse(gate.shouldRecord(.warm))
    }
}
