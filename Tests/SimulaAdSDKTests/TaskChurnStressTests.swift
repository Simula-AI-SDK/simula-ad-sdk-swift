import XCTest
@testable import SimulaAdSDK

/// Task-churn stress for the RELEASE (optimized) CI lane.
///
/// The Swift 6.1–6.3 optimizer task-teardown miscompilation ("freed pointer was not the last
/// allocation", see .cursor/skills/swift-concurrency-task-shape/SKILL.md) only manifests in
/// optimized builds — plain `swift test` (debug, -Onone) can never catch it. This suite churns
/// tens of thousands of task create/teardown cycles through the same shapes the SDK uses
/// (single-call closures into named methods, do/catch sleeps, awaited value handoffs, and the
/// telemetry flush pipeline). It also validates the release toolchain before an XCFramework
/// ships (scripts/build-xcframework.sh builds with that same toolchain).
///
/// The failure mode of a regression is the test process ABORTING at task teardown — not an
/// assertion failure — so a green run is the signal, and the assertions are sanity checks.
final class TaskChurnStressTests: XCTestCase {

    // MARK: - Minimal fakes (mirrors TelemetryManagerTests' harness)

    private final class FakeStore: TelemetryStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var data: [TelemetryEvent] = []
        func load() -> [TelemetryEvent] { lock.lock(); defer { lock.unlock() }; return data }
        func save(_ events: [TelemetryEvent]) { lock.lock(); data = events; lock.unlock() }
    }

    private final class CountingSender: TelemetrySending, @unchecked Sendable {
        private let lock = NSLock()
        private var _sends = 0
        var sends: Int { lock.lock(); defer { lock.unlock() }; return _sends }
        func send(_ body: Data) async -> TelemetryAck {
            lock.lock(); _sends += 1; lock.unlock()
            return .accepted
        }
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Generic task create/teardown churn

    /// The single-call named-method task body used across the SDK (do/catch sleep, then work).
    private static func tick(_ i: Int) async -> Int {
        do { try await Task.sleep(nanoseconds: 1) } catch { return -1 }
        return i
    }

    /// Batched spawn + `.value` await of value-returning tasks — the `sessionTask` /
    /// `fallbackPrefetch` handoff shape — at volume.
    func testValueTaskChurn() async {
        var total = 0
        for batch in 0..<200 {
            var tasks: [Task<Int, Never>] = []
            for i in 0..<100 {
                tasks.append(Task { await Self.tick(batch * 100 + i) })
            }
            for t in tasks { total += await t.value }
        }
        XCTAssertEqual(total, (0..<20_000).reduce(0, +))
    }

    /// Task-group churn — the `CoverImageCache.preload` shape — at volume.
    func testTaskGroupChurn() async {
        var total = 0
        for _ in 0..<100 {
            let sum = await withTaskGroup(of: Int.self, returning: Int.self) { group in
                for i in 0..<100 {
                    group.addTask { await Self.tick(i) }
                }
                var acc = 0
                for await v in group { acc += v }
                return acc
            }
            total += sum
        }
        XCTAssertEqual(total, 100 * (0..<100).reduce(0, +))
    }

    // MARK: - Telemetry pipeline churn (the subsystem that crashed in production)

    /// Hammers record → eager-flush / timed-flush / persist through the real TelemetryManager
    /// engine with fakes: every error record schedules a flush Task, every flush tears one down.
    func testTelemetryFlushChurn() async {
        let store = FakeStore()
        let sender = CountingSender()
        let manager = TelemetryManager(
            ctx: TelemetryContext(sdkVersion: "9.9", osVersion: "14", deviceModel: "TestPhone", hostAppId: "com.test", devMode: true),
            store: store,
            sender: sender,
            primaryUserIdProvider: { nil },
            advertisingIdProvider: { nil },
            enabled: true,
            sampleRate: 1.0,
            now: { Date().timeIntervalSince1970 },
            random: { 0.0 },
            backoff: { _ in 0 },
            debugLog: nil,
            flushThreshold: 10, // small threshold: many flush tasks over the run
            flushInterval: 0.01
        )
        manager.start()

        for i in 0..<2_000 {
            // Distinct signatures defeat error aggregation so the buffer actually grows and
            // crosses the flush threshold repeatedly.
            manager.recordError(signature: "stress:sig_\(i)", errorCode: nil, message: "m", breadcrumb: nil, stack: nil)
            manager.recordOperation(name: "stress_op", durationMs: 1, success: true)
        }
        manager.flushNow()

        await waitUntil { sender.sends > 0 }
        XCTAssertGreaterThan(sender.sends, 0, "flush pipeline never delivered under churn")
    }
}
