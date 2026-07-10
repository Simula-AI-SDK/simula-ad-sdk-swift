import XCTest
import SimulaCanaryZooA
import SimulaCanaryZooB
@testable import SimulaAdSDK

/// Release-mode concurrency canary — CI's replacement for source greps that cannot see
/// toolchain-level failures. Run at `-O` ("Release concurrency canary" CI job): with three
/// Swift modules (the SDK + two byte-identical zoo modules) linked into one binary, this
/// exercises the task-teardown and GCD-flush paths that abort on affected toolchains
/// ("freed pointer was not the last allocation" in `swift_task_dealloc`). NOT SIGABRTing is
/// the real pass condition; the count assertions just prove the work actually ran. In Debug
/// runs it's a fast smoke test. See .cursor/skills/swift-concurrency-task-shape/SKILL.md.
final class ReleaseConcurrencyCanaryTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
        }
    }

    /// Interleave two foreign-shaped modules' task teardowns with each other (and with
    /// whatever the SDK module linked in). 400 tasks across 4 shapes × 2 modules.
    func testMultiModuleTaskTeardownDoesNotAbort() async {
        let perModule = 200
        SimulaCanaryZooA.shared.exercise(count: perModule)
        SimulaCanaryZooB.shared.exercise(count: perModule)

        await waitUntil {
            SimulaCanaryZooA.shared.completedCount >= perModule
                && SimulaCanaryZooB.shared.completedCount >= perModule
        }
        XCTAssertGreaterThanOrEqual(SimulaCanaryZooA.shared.completedCount, perModule)
        XCTAssertGreaterThanOrEqual(SimulaCanaryZooB.shared.completedCount, perModule)
    }

    /// Drive the SDK's launch-path telemetry engine (GCD by design — this must stay
    /// abort-proof at -O) concurrently with zoo task churn: the exact mixed workload of a
    /// real host launch (SDK init + other vendors' tasks completing).
    func testTelemetryEngineUnderTaskChurnDoesNotAbort() async {
        final class NullStore: TelemetryStoring, @unchecked Sendable {
            private let lock = NSLock()
            private var data: [TelemetryEvent] = []
            func load() -> [TelemetryEvent] { lock.lock(); defer { lock.unlock() }; return data }
            func save(_ events: [TelemetryEvent]) { lock.lock(); data = events; lock.unlock() }
        }
        final class CountingSender: TelemetrySending, @unchecked Sendable {
            private let lock = NSLock()
            private var _sends = 0
            var sends: Int { lock.lock(); defer { lock.unlock() }; return _sends }
            func send(_ body: Data, completion: @escaping @Sendable (TelemetryAck) -> Void) {
                lock.lock(); _sends += 1; lock.unlock()
                completion(.accepted)
            }
        }

        let sender = CountingSender()
        let mgr = TelemetryManager(
            ctx: TelemetryContext(sdkVersion: "canary", osVersion: "0", deviceModel: "ci", hostAppId: "ci", devMode: false),
            store: NullStore(),
            sender: sender,
            primaryUserIdProvider: { nil },
            advertisingIdProvider: { nil },
            backoff: { _ in 0 },
            flushInterval: 0.05
        )

        SimulaCanaryZooA.shared.exercise(count: 100)
        mgr.start()
        for i in 0..<50 {
            mgr.recordError(signature: "canary:\(i % 5)", errorCode: "canary", message: "m")
        }
        SimulaCanaryZooB.shared.exercise(count: 100)
        mgr.flushNow()

        await waitUntil { sender.sends > 0 }
        XCTAssertGreaterThan(sender.sends, 0)
    }
}
