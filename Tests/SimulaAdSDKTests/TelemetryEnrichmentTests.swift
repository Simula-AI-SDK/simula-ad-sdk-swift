import XCTest
@testable import SimulaAdSDK

/// Tests for the telemetry enrichment added in "Better Telemetry Tracking": per-event `event_age_ms`,
/// envelope `connection_type` / `experiment_id` / `variant_id`, the new recorder fields, plus the
/// derived funnel summary, time-to-first-ad, and diagnostics sample.
final class TelemetryEnrichmentTests: XCTestCase {

    private final class FakeStore: TelemetryStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var data: [TelemetryEvent] = []
        func load() -> [TelemetryEvent] { lock.lock(); defer { lock.unlock() }; return data }
        func save(_ events: [TelemetryEvent]) { lock.lock(); data = events; lock.unlock() }
    }

    private final class FakeSender: TelemetrySending, @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [TelemetryEnvelope] = []
        var batches: [TelemetryEnvelope] { lock.lock(); defer { lock.unlock() }; return _batches }
        func send(_ body: Data) async -> TelemetryAck {
            lock.lock()
            if let env = try? JSONDecoder().decode(TelemetryEnvelope.self, from: body) { _batches.append(env) }
            lock.unlock()
            return .accepted
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval
        init(_ t: TimeInterval) { self.t = t }
        var now: TimeInterval {
            get { lock.lock(); defer { lock.unlock() }; return t }
            set { lock.lock(); t = newValue; lock.unlock() }
        }
    }

    private func build(
        store: TelemetryStoring,
        sender: TelemetrySending,
        clock: Clock,
        connectionType: @escaping @Sendable () -> String? = { nil },
        diagnostics: @escaping @Sendable () -> String? = { nil },
        battery: @escaping @Sendable () -> BatteryInfo? = { nil },
        carrier: @escaping @Sendable () -> CarrierInfo? = { nil },
        ctx: TelemetryContext = TelemetryContext(sdkVersion: "9.9", osVersion: "14", deviceModel: "Test", hostAppId: "com.test", devMode: true),
        flushThreshold: Int = 20
    ) -> TelemetryManager {
        TelemetryManager(
            ctx: ctx,
            store: store,
            sender: sender,
            primaryUserIdProvider: { nil },
            advertisingIdProvider: { nil },
            connectionTypeProvider: connectionType,
            diagnosticsProvider: diagnostics,
            batteryProvider: battery,
            carrierProvider: carrier,
            enabled: true,
            sampleRate: 1.0,
            now: { clock.now },
            random: { 0.0 },
            backoff: { _ in 0 },
            flushThreshold: flushThreshold,
            flushInterval: 0.05
        )
    }

    private func allEvents(_ s: [TelemetryEnvelope]) -> [TelemetryEvent] { s.flatMap { $0.events } }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testEventAgeStampedAtFlush() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock)

        m.recordNetwork(path: "/load", method: "POST", statusCode: 200, durationMs: 5, requestBytes: 0, responseBytes: 0, failureClass: nil)
        clock.now = 5_000 // time passes before the timed flush fires
        await waitUntil { !sender.batches.isEmpty }

        let e = allEvents(sender.batches).first { $0.type == TelemetryType.network }
        XCTAssertEqual(e?.eventAgeMs, 4_000)
    }

    func testConnectionTypeAndExperimentOnEnvelope() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock, connectionType: { "wifi" })

        m.setExperiment(experimentId: "exp_7", variantId: "variant_b")
        m.recordError(signature: "api:boom", errorCode: "boom")
        await waitUntil { !sender.batches.isEmpty }

        let env = sender.batches.first
        XCTAssertEqual(env?.connectionType, "wifi")
        XCTAssertEqual(env?.experimentId, "exp_7")
        XCTAssertEqual(env?.variantId, "variant_b")
    }

    func testRecorderNewFields() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock)

        m.recordOperation(name: "session_failed", durationMs: 12, success: false, failureClass: "no_session", breadcrumb: "ctx=true")
        m.recordLifecycle(stage: "store_opened", adFormat: "interstitial", adUnitId: nil, adId: "a1", serveId: nil, durationMs: 1500, errorCode: nil, trigger: "cta")
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "store_opened" } }

        let op = allEvents(sender.batches).first { $0.name == "session_failed" }
        XCTAssertEqual(op?.failureClass, "no_session")
        XCTAssertEqual(op?.breadcrumb, "ctx=true")
        let life = allEvents(sender.batches).first { $0.name == "store_opened" }
        XCTAssertEqual(life?.trigger, "cta")
        XCTAssertEqual(life?.durationMs, 1500)
    }

    func testTimeToFirstAdEmittedOnce() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock)

        clock.now = 1_250
        m.recordLifecycle(stage: "load_success", adFormat: "interstitial", adUnitId: "u", adId: "a1", serveId: nil, durationMs: 10, errorCode: nil, cacheSource: "network")
        m.recordLifecycle(stage: "load_success", adFormat: "interstitial", adUnitId: "u", adId: "a2", serveId: nil, durationMs: 10, errorCode: nil, cacheSource: "network")
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "time_to_first_ad" } }

        let ttfa = allEvents(sender.batches).filter { $0.name == "time_to_first_ad" }
        XCTAssertEqual(ttfa.count, 1)
        XCTAssertEqual(ttfa.first?.durationMs, 250) // 1250 - createdAt(1000)
    }

    func testFunnelSummaryOnFlush() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock)

        m.recordLifecycle(stage: "load_success", adFormat: "interstitial", adUnitId: "u", adId: "a1", serveId: nil, durationMs: 1, errorCode: nil, cacheSource: "network")
        m.recordLifecycle(stage: "load_success", adFormat: "interstitial", adUnitId: "u", adId: "a2", serveId: nil, durationMs: 1, errorCode: nil, cacheSource: "cache") // excluded
        m.recordLifecycle(stage: "load_fail", adFormat: "interstitial", adUnitId: "u", adId: nil, serveId: nil, durationMs: nil, errorCode: "no_fill")
        m.recordLifecycle(stage: "displayed", adFormat: "interstitial", adUnitId: "u", adId: "a1", serveId: nil, durationMs: nil, errorCode: nil)
        m.recordLifecycle(stage: "click", adFormat: "interstitial", adUnitId: "u", adId: "a1", serveId: nil, durationMs: nil, errorCode: nil)
        m.flushNow()
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "funnel_summary" } }

        let summary = allEvents(sender.batches).first { $0.name == "funnel_summary" }
        XCTAssertEqual(summary?.breadcrumb, "fmt=interstitial;req=2;fill=1;nofill=1;fail=0;imp=1;clk=1")
    }

    func testPeriodicFlushSendsFunnelWhenLifecycleBatchAlreadyDrained() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock, flushThreshold: 1)

        m.recordLifecycle(stage: "displayed", adFormat: "rewarded", adUnitId: "u", adId: "a1", serveId: nil, durationMs: nil, errorCode: nil)
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "funnel_summary" } }

        let summaryBatches = sender.batches.filter { envelope in
            envelope.events.contains { $0.name == "funnel_summary" }
        }
        XCTAssertEqual(summaryBatches.count, 1)
        XCTAssertEqual(summaryBatches.first?.events.map(\.name), ["funnel_summary"])
        XCTAssertEqual(summaryBatches.first?.events.first?.breadcrumb, "fmt=rewarded;req=0;fill=0;nofill=0;fail=0;imp=1;clk=0")
    }

    func testPeriodicFunnelIsNotCountedAgainByLaterExplicitFlush() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(
            store: FakeStore(), sender: sender, clock: clock,
            diagnostics: { "mem_used_mb=42" }
        )

        m.recordLifecycle(stage: "click", adFormat: "native", adUnitId: "u", adId: "a1", serveId: nil, durationMs: nil, errorCode: nil)
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "funnel_summary" } }
        m.flushNow()
        await waitUntil { self.allEvents(sender.batches).filter { $0.name == "diagnostics" }.count == 2 }

        let summaries = allEvents(sender.batches).filter { $0.name == "funnel_summary" }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.breadcrumb, "fmt=native;req=0;fill=0;nofill=0;fail=0;imp=0;clk=1")
    }

    func testDiagnosticsSampleOnFlush() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock, diagnostics: { "mem_used_mb=42" })

        m.recordError(signature: "api:boom", errorCode: "boom")
        m.flushNow()
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "diagnostics" } }

        XCTAssertEqual(allEvents(sender.batches).first { $0.name == "diagnostics" }?.breadcrumb, "mem_used_mb=42")
    }

    func testPeriodicDiagnosticsDoesNotScheduleAnotherTimer() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock, diagnostics: { "mem_used_mb=7" })

        m.recordNetwork(path: "/load", method: "POST", statusCode: 200, durationMs: 1, requestBytes: 0, responseBytes: 0, failureClass: nil)
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "diagnostics" } }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let diagnostics = allEvents(sender.batches).filter { $0.name == "diagnostics" }
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.breadcrumb, "mem_used_mb=7")
    }

    func testDeviceDiagnosticsOnEnvelope() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let ctx = TelemetryContext(
            sdkVersion: "9.9", osVersion: "14", deviceModel: "Test", hostAppId: "com.test",
            devMode: true, manufacturer: "Apple", locale: "en-US", deviceRamMb: 8192, buildType: "release"
        )
        let m = build(
            store: FakeStore(), sender: sender, clock: clock,
            battery: { BatteryInfo(level: 0.5, charging: true) },
            carrier: { CarrierInfo(carrier: nil, radio: "5G") },
            ctx: ctx
        )

        m.recordError(signature: "api:boom", errorCode: "boom")
        await waitUntil { !sender.batches.isEmpty }

        let env = sender.batches.first
        XCTAssertEqual(env?.manufacturer, "Apple")
        XCTAssertEqual(env?.locale, "en-US")
        XCTAssertEqual(env?.deviceRamMb, 8192)
        XCTAssertEqual(env?.batteryLevel, 0.5)
        XCTAssertEqual(env?.batteryCharging, true)
        XCTAssertNil(env?.carrier ?? nil)
        XCTAssertEqual(env?.radio, "5G")
        XCTAssertEqual(env?.buildType, "release")
    }

    func testRecordErrorCarriesStack() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock)

        m.recordError(signature: "crash:Foo.bar", errorCode: "code", stack: ["Foo.bar(Foo.swift:1)", "Baz.qux(Baz.swift:2)"])
        await waitUntil { self.allEvents(sender.batches).contains { $0.type == TelemetryType.error } }

        let e = allEvents(sender.batches).first { $0.type == TelemetryType.error }
        XCTAssertEqual(e?.stack, ["Foo.bar(Foo.swift:1)", "Baz.qux(Baz.swift:2)"])
    }

    func testErrorDedupeSeparatesCrashContextsWithoutChangingWireName() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock)

        m.recordError(
            signature: "crash:exc_10_sig_9",
            breadcrumb: "fatal=watchdog;fp=site_a",
            stack: ["SimulaAdSDK uuid=A offset=1"],
            dedupeDiscriminator: "site_a"
        )
        m.recordError(
            signature: "crash:exc_10_sig_9",
            breadcrumb: "fatal=watchdog;fp=site_b",
            stack: ["SimulaAdSDK uuid=B offset=2"],
            dedupeDiscriminator: "site_b"
        )

        await waitUntil {
            self.allEvents(sender.batches).filter { $0.name == "crash:exc_10_sig_9" }.count == 2
        }
        let events = allEvents(sender.batches).filter { $0.name == "crash:exc_10_sig_9" }
        XCTAssertEqual(events.map(\.name), ["crash:exc_10_sig_9", "crash:exc_10_sig_9"])
        XCTAssertEqual(Set(events.compactMap { $0.stack?.first }), Set([
            "SimulaAdSDK uuid=A offset=1",
            "SimulaAdSDK uuid=B offset=2",
        ]))
    }
}
