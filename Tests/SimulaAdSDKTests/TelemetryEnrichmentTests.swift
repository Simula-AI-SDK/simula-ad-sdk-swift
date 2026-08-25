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
        private var ack: TelemetryAck = .accepted
        var batches: [TelemetryEnvelope] { lock.lock(); defer { lock.unlock() }; return _batches }
        func setAck(_ ack: TelemetryAck) { lock.lock(); self.ack = ack; lock.unlock() }
        func send(_ body: Data) async -> TelemetryAck {
            lock.lock()
            if let env = try? JSONDecoder().decode(TelemetryEnvelope.self, from: body) { _batches.append(env) }
            let result = ack
            lock.unlock()
            return result
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

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
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
        flushThreshold: Int = 20,
        maxBuffer: Int = 200,
        launchGate: LaunchSettling = ImmediateLaunchSettledGate.shared,
        timedFlushSleep: (@Sendable (TimeInterval) async -> Void)? = nil
    ) -> TelemetryManager {
        let manager = TelemetryManager(
            ctx: ctx,
            store: store,
            sender: sender,
            identityProvider: { TelemetryIdentity(sessionId: nil, primaryUserId: nil) },
            connectionTypeProvider: connectionType,
            diagnosticsProvider: diagnostics,
            batteryProvider: battery,
            carrierProvider: carrier,
            enabled: true,
            sampleRate: 1.0,
            now: { clock.now },
            random: { 0.0 },
            backoff: { _ in 0 },
            timedFlushSleep: timedFlushSleep,
            launchGate: launchGate,
            flushThreshold: flushThreshold,
            maxBuffer: maxBuffer,
            flushInterval: 0.05
        )
        manager.start()
        return manager
    }

    private func allEvents(_ s: [TelemetryEnvelope]) -> [TelemetryEvent] { s.flatMap { $0.events } }

    func testEventAgeStampedAtFlush() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let sleep = ControllablePersistenceSleep()
        let m = build(
            store: FakeStore(), sender: sender, clock: clock,
            timedFlushSleep: { await sleep.sleep($0) }
        )
        await m.waitForRecoveryForTests()
        await m.waitForImmediateFlushIdleForTests()

        m.recordNetwork(path: "/load", method: "POST", statusCode: 200, durationMs: 5, requestBytes: 0, responseBytes: 0, failureClass: nil)
        _ = await sleep.waitForRequest()
        clock.now = 5_000 // time passes before the timed flush fires
        sleep.release()
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

        m.recordOperation(
            name: "session_failed",
            durationMs: 12,
            success: false,
            failureClass: "no_session",
            breadcrumb: "ctx=true",
            timeSinceInitMs: -4
        )
        m.recordLifecycle(stage: "store_opened", adFormat: "interstitial", adUnitId: nil, adId: "a1", serveId: nil, durationMs: 1500, errorCode: nil, trigger: "cta")
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "store_opened" } }

        let op = allEvents(sender.batches).first { $0.name == "session_failed" }
        XCTAssertEqual(op?.failureClass, "no_session")
        XCTAssertEqual(op?.breadcrumb, "ctx=true")
        XCTAssertEqual(op?.timeSinceInitMs, 0)
        let life = allEvents(sender.batches).first { $0.name == "store_opened" }
        XCTAssertEqual(life?.trigger, "cta")
        XCTAssertEqual(life?.durationMs, 1500)
    }

    func testClickSerializationCarriesInteractionSourceServeAndSampleRate() async throws {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let m = build(store: FakeStore(), sender: sender, clock: clock)

        m.recordLifecycle(
            stage: "click",
            adFormat: "interstitial",
            adUnitId: "unit",
            adId: "impression",
            serveId: "impression",
            durationMs: nil,
            errorCode: nil,
            interactionId: "interaction",
            clickSource: ClickSource.fallbackCTA.rawValue
        )
        await waitUntil { !sender.batches.isEmpty }

        let envelope = sender.batches.first
        let click = envelope?.events.first { $0.name == "click" }
        XCTAssertEqual(envelope?.sampleRate, 1)
        XCTAssertEqual(click?.adId, "impression")
        XCTAssertEqual(click?.serveId, "impression")
        XCTAssertEqual(click?.interactionId, "interaction")
        XCTAssertEqual(click?.clickSource, "fallback_cta")
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let wireClick = try XCTUnwrap(events.first { ($0["name"] as? String) == "click" })
        XCTAssertEqual(json["sample_rate"] as? Double, 1)
        XCTAssertEqual(wireClick["interaction_id"] as? String, "interaction")
        XCTAssertEqual(wireClick["click_source"] as? String, "fallback_cta")
        XCTAssertEqual(wireClick["serve_id"] as? String, "impression")
        XCTAssertEqual(wireClick["sample_rate"] as? Double, 1)
    }

    func testSampleRateIsStampedAtAdmissionAcrossServerConfigChange() async {
        let clock = Clock(1_000)
        let store = FakeStore()
        let sender = FakeSender()
        let gate = ControllableLaunchSettledGate()
        let timedSleep = ControllablePersistenceSleep()
        let m = build(
            store: store,
            sender: sender,
            clock: clock,
            launchGate: gate,
            timedFlushSleep: { await timedSleep.sleep($0) }
        )
        await m.waitForRecoveryForTests()

        m.recordLifecycle(
            stage: "click", adFormat: "interstitial", adUnitId: "unit", adId: "imp",
            serveId: "imp", durationMs: nil, errorCode: nil,
            interactionId: "before", clickSource: "primary_cta"
        )
        m.applyServerConfig(enabled: true, sampleRate: 0.25)
        m.recordLifecycle(
            stage: "click", adFormat: "interstitial", adUnitId: "unit", adId: "imp",
            serveId: "imp", durationMs: nil, errorCode: nil,
            interactionId: "after", clickSource: "store_prompt"
        )

        await waitUntil { store.load().filter { $0.name == "click" }.count == 2 }
        let persisted = store.load().filter { $0.name == "click" }
        XCTAssertEqual(persisted.first { $0.interactionId == "before" }?.sampleRate, 1)
        XCTAssertEqual(persisted.first { $0.interactionId == "after" }?.sampleRate, 1)

        _ = await timedSleep.waitForRequest()
        await waitUntil { await gate.waitCount > 0 }
        await gate.open()
        let expectedIds: Set<String> = ["before", "after"]
        await waitUntil {
            Set(self.allEvents(sender.batches).compactMap(\.interactionId)).isSuperset(of: expectedIds)
        }
        let envelope = sender.batches.first { batch in
            Set(batch.events.compactMap(\.interactionId)) == expectedIds
        }
        XCTAssertEqual(envelope?.sampleRate, 1)
        XCTAssertEqual(
            Set(envelope?.events.filter { $0.name == "click" }.compactMap(\.sampleRate) ?? []),
            Set([1.0])
        )

        timedSleep.release()
        await timedSleep.waitForCompletion()
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "funnel_summary" } }
    }

    func testCriticalClickSurvivesOrdinaryBufferPressure() async {
        let store = FakeStore()
        let gate = ControllableLaunchSettledGate()
        let m = build(
            store: store,
            sender: FakeSender(),
            clock: Clock(1_000),
            flushThreshold: 100,
            maxBuffer: 3,
            launchGate: gate
        )
        await m.waitForRecoveryForTests()

        m.recordLifecycle(
            stage: "click", adFormat: "interstitial", adUnitId: "unit", adId: "imp",
            serveId: "imp", durationMs: nil, errorCode: nil,
            interactionId: "critical", clickSource: "primary_cta"
        )
        for index in 0..<4 {
            m.recordOperation(name: "ordinary_\(index)", durationMs: 1, success: true)
        }
        m.flushNow()

        await waitUntil { store.load().count == 3 }
        XCTAssertTrue(store.load().contains { $0.interactionId == "critical" })
    }

    func testBackgroundObserverPersistsBeforeFlushAttempt() async {
        let clock = Clock(1_000)
        let store = FakeStore()
        let sender = FakeSender()
        let sleep = ControllablePersistenceSleep()
        let m = build(
            store: store,
            sender: sender,
            clock: clock,
            timedFlushSleep: { await sleep.sleep($0) }
        )
        await m.waitForRecoveryForTests()
        await m.waitForImmediateFlushIdleForTests()
        sender.setAck(.retry)
        let center = NotificationCenter()
        let name = Notification.Name("telemetry-background-test")
        let observer = TelemetryBackgroundFlushObserver(center: center, name: name) { m.flushNow() }
        _ = observer

        m.recordOperation(name: "pending_before_background", durationMs: 1, success: true)
        center.post(name: name, object: nil)

        await waitUntil { store.load().contains { $0.name == "pending_before_background" } }
        XCTAssertTrue(store.load().contains { $0.name == "pending_before_background" })
    }

    func testBackgroundObserverDoesNotFlushInlineOnPostingThread() async {
        let center = NotificationCenter()
        let name = Notification.Name("telemetry-background-async-test")
        let queue = DispatchQueue(label: "telemetry-background-async-test")
        queue.suspend()
        let flushed = LockedFlag()
        let observer = TelemetryBackgroundFlushObserver(center: center, name: name, queue: queue) {
            flushed.set()
        }
        _ = observer

        center.post(name: name, object: nil)
        XCTAssertFalse(flushed.isSet)
        queue.resume()

        await waitUntil { flushed.isSet }
    }

    func testOldPersistedEventDecodesWithoutTimeSinceInit() throws {
        let data = Data(#"{"type":"operation","name":"old","event_id":"e1","timestamp":1}"#.utf8)
        let event = try JSONDecoder().decode(TelemetryEvent.self, from: data)
        XCTAssertNil(event.timeSinceInitMs)
    }

    func testInitializationOriginIsFirstWinsMonotonicAndClamped() {
        let origin = SDKInitializationOrigin()
        XCTAssertNil(origin.timeSinceInitMs(nowNanos: 9_000_000))
        XCTAssertEqual(origin.markEntry(nowNanos: 10_000_000), 10_000_000)
        XCTAssertEqual(origin.markEntry(nowNanos: 20_000_000), 10_000_000)
        XCTAssertEqual(origin.timeSinceInitMs(nowNanos: 9_000_000), 0)
        XCTAssertEqual(origin.timeSinceInitMs(nowNanos: 12_500_000), 2)
    }

    func testTimeToFirstAdEmittedOnce() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let sleep = ControllablePersistenceSleep()
        let m = build(
            store: FakeStore(), sender: sender, clock: clock,
            timedFlushSleep: { await sleep.sleep($0) }
        )

        clock.now = 1_250
        m.recordLifecycle(stage: "load_success", adFormat: "interstitial", adUnitId: "u", adId: "a1", serveId: nil, durationMs: 10, errorCode: nil, cacheSource: "network")
        m.recordLifecycle(stage: "load_success", adFormat: "interstitial", adUnitId: "u", adId: "a2", serveId: nil, durationMs: 10, errorCode: nil, cacheSource: "network")
        _ = await sleep.waitForRequest()
        sleep.release()
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
        let sleep = ControllablePersistenceSleep()
        let m = build(
            store: FakeStore(), sender: sender, clock: clock, flushThreshold: 1,
            timedFlushSleep: { await sleep.sleep($0) }
        )

        m.recordLifecycle(stage: "displayed", adFormat: "rewarded", adUnitId: "u", adId: "a1", serveId: nil, durationMs: nil, errorCode: nil)
        _ = await sleep.waitForRequest()
        sleep.release()
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "funnel_summary" } }

        let summaries = allEvents(sender.batches).filter { $0.name == "funnel_summary" }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.breadcrumb, "fmt=rewarded;req=0;fill=0;nofill=0;fail=0;imp=1;clk=0")
    }

    func testPeriodicFunnelIsNotCountedAgainByLaterExplicitFlush() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let sleep = ControllablePersistenceSleep()
        let m = build(
            store: FakeStore(), sender: sender, clock: clock,
            diagnostics: { "mem_used_mb=42" },
            timedFlushSleep: { await sleep.sleep($0) }
        )

        m.recordLifecycle(stage: "click", adFormat: "native", adUnitId: "u", adId: "a1", serveId: nil, durationMs: nil, errorCode: nil)
        _ = await sleep.waitForRequest()
        sleep.release()
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

        await m.waitForRecoveryForTests()
        m.flushNow()
        await m.waitForImmediateFlushIdleForTests()

        XCTAssertEqual(allEvents(sender.batches).first { $0.name == "diagnostics" }?.breadcrumb, "mem_used_mb=42")
    }

    func testPeriodicDiagnosticsDoesNotScheduleAnotherTimer() async {
        let clock = Clock(1_000)
        let sender = FakeSender()
        let sleep = ControllablePersistenceSleep()
        let m = build(
            store: FakeStore(), sender: sender, clock: clock, diagnostics: { "mem_used_mb=7" },
            timedFlushSleep: { await sleep.sleep($0) }
        )

        m.recordNetwork(path: "/load", method: "POST", statusCode: 200, durationMs: 1, requestBytes: 0, responseBytes: 0, failureClass: nil)
        _ = await sleep.waitForRequest()
        sleep.release()
        await waitUntil { self.allEvents(sender.batches).contains { $0.name == "diagnostics" } }

        let diagnostics = allEvents(sender.batches).filter { $0.name == "diagnostics" }
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.breadcrumb, "mem_used_mb=7")
        XCTAssertEqual(sleep.requestCount, 1, "periodic diagnostics must not arm another timer")
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
