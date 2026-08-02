import XCTest
@testable import SimulaAdSDK

/// Tier-1 tests for `TelemetryManager` — the batching / dedup / backoff engine behind in-house
/// SDK telemetry. Exercised with an in-memory store, a fake sender, an injected clock, and zero
/// retry backoff so flush triggering, error aggregation, durability, retry, sampling, the
/// kill-switch, and consent-gated PII are validated without the network or wall-clock timing.
final class TelemetryManagerTests: XCTestCase {

    // MARK: - Test doubles

    private final class FakeStore: TelemetryStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var data: [TelemetryEvent] = []
        init(_ initial: [TelemetryEvent] = []) { data = initial }
        func load() -> [TelemetryEvent] { lock.lock(); defer { lock.unlock() }; return data }
        func save(_ events: [TelemetryEvent]) { lock.lock(); data = events; lock.unlock() }
    }

    private final class BlockingRecoveryStore: TelemetryStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var data: [TelemetryEvent]
        private var saves = 0
        private let loadStarted: @Sendable () -> Void
        private let releaseLoad = DispatchSemaphore(value: 0)

        init(_ initial: [TelemetryEvent], loadStarted: @escaping @Sendable () -> Void) {
            data = initial
            self.loadStarted = loadStarted
        }

        func load() -> [TelemetryEvent] {
            loadStarted()
            releaseLoad.wait()
            lock.lock(); defer { lock.unlock() }
            return data
        }

        func save(_ events: [TelemetryEvent]) {
            lock.lock(); data = events; saves += 1; lock.unlock()
        }

        func release() { releaseLoad.signal() }
        var saveCount: Int { lock.lock(); defer { lock.unlock() }; return saves }
    }

    /// Records decoded batches; replays queued acks then falls back to `defaultAck`. Optional
    /// one-shot gate so a test can hold the first send in flight while it enqueues more work.
    private final class FakeSender: TelemetrySending, @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [TelemetryEnvelope] = []
        private var acks: [TelemetryAck] = []
        var defaultAck: TelemetryAck = .accepted
        private var gateCont: CheckedContinuation<Void, Never>?
        private var gated = false
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?

        var batches: [TelemetryEnvelope] { lock.lock(); defer { lock.unlock() }; return _batches }
        func enqueueAcks(_ a: [TelemetryAck]) { lock.lock(); acks = a; lock.unlock() }
        func gateFirst() { lock.lock(); gated = true; lock.unlock() }
        func release() {
            lock.lock(); let c = gateCont; gateCont = nil; gated = false; lock.unlock()
            c?.resume()
        }

        func send(_ body: Data) async -> TelemetryAck {
            let (shouldGate, waiter) = beginSend()
            waiter?.resume()
            if shouldGate {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    // Re-check under the lock: if release() ran between beginSend() and here,
                    // parking now would leak the continuation and deadlock the flush.
                    lock.lock()
                    if gated { gateCont = cont; lock.unlock() }
                    else { lock.unlock(); cont.resume() }
                }
            }
            return finishSend(body)
        }

        private func beginSend() -> (Bool, CheckedContinuation<Void, Never>?) {
            lock.lock()
            let shouldGate = gated
            entered = true
            let waiter = enteredWaiter
            enteredWaiter = nil
            lock.unlock()
            return (shouldGate, waiter)
        }

        private func finishSend(_ body: Data) -> TelemetryAck {
            lock.lock()
            if let env = try? JSONDecoder().decode(TelemetryEnvelope.self, from: body) { _batches.append(env) }
            let ack = acks.isEmpty ? defaultAck : acks.removeFirst()
            lock.unlock()
            return ack
        }

        func waitUntilEntered() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if entered {
                    lock.unlock()
                    continuation.resume()
                } else {
                    enteredWaiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    // MARK: - Builder

    private func build(
        store: TelemetryStoring,
        sender: TelemetrySending,
        enabled: Bool = true,
        sampleRate: Double = 1.0,
        random: @escaping @Sendable () -> Double = { 0.0 },
        ppid: String? = nil,
        gaid: String? = nil,
        debugLog: (@Sendable (String) -> Void)? = nil
    ) -> TelemetryManager {
        TelemetryManager(
            ctx: TelemetryContext(sdkVersion: "9.9", osVersion: "14", deviceModel: "TestPhone", hostAppId: "com.test", devMode: true),
            store: store,
            sender: sender,
            primaryUserIdProvider: { ppid },
            advertisingIdProvider: { gaid },
            enabled: enabled,
            sampleRate: sampleRate,
            now: { 1_000 },
            random: random,
            backoff: { _ in 0 }, // instant retries — keep tests fast
            debugLog: debugLog,
            flushThreshold: 20,
            flushInterval: 0.05 // sub-threshold perf flushes promptly via the timer
        )
    }

    /// Thread-safe line collector for the debug-log tests.
    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private final class BackgroundRequestHarness: @unchecked Sendable {
        private let lock = NSLock()
        private var request: BackgroundFlushRequest?
        private var expiration: (@Sendable () -> Void)?
        private var ends = 0

        func capture(request: BackgroundFlushRequest) {
            lock.lock(); self.request = request; lock.unlock()
        }

        func capture(expiration: @escaping @Sendable () -> Void) {
            lock.lock(); self.expiration = expiration; lock.unlock()
        }

        func expire() {
            lock.lock(); let expiration = expiration; lock.unlock()
            expiration?()
        }

        func end() { lock.lock(); ends += 1; lock.unlock() }
        var endCount: Int { lock.lock(); defer { lock.unlock() }; return ends }
        var isFinished: Bool {
            lock.lock(); let request = request; lock.unlock()
            return request?.isFinished ?? false
        }
    }

    private final class InstallationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var returned = false

        func markReturned() { lock.lock(); returned = true; lock.unlock() }
        var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
    }

    private func allEvents(_ s: [TelemetryEnvelope]) -> [TelemetryEvent] { s.flatMap { $0.events } }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    private func completeOffMain(_ facade: Telemetry, manager: TelemetryManager) -> InstallationProbe {
        let probe = InstallationProbe()
        DispatchQueue.global(qos: .utility).async {
            facade.completeInstallation(with: manager)
            probe.markReturned()
        }
        return probe
    }

    // MARK: - Batching + flush

    func testSubThresholdPerfFlushesOnTimerAndClears() async {
        let store = FakeStore(); let sender = FakeSender()
        let mgr = build(store: store, sender: sender)

        for _ in 0..<3 {
            mgr.recordNetwork(path: "/load/interstitial", method: "POST", statusCode: 200, durationMs: 12, requestBytes: 0, responseBytes: 100, failureClass: nil)
        }
        await waitUntil { !sender.batches.isEmpty }

        let net = allEvents(sender.batches).filter { $0.type == TelemetryType.network }
        XCTAssertEqual(net.count, 3)
        XCTAssertTrue(net.allSatisfy { $0.name == "POST /load/interstitial" && $0.durationMs == 12 })
        await waitUntil { store.load().isEmpty }
    }

    func testEnvelopeCarriesContextAndSessionId() async {
        let sender = FakeSender()
        let mgr = build(store: FakeStore(), sender: sender)
        mgr.setSessionId("sess-42")
        mgr.recordError(signature: "api:boom", errorCode: "boom", message: "msg")
        await waitUntil { !sender.batches.isEmpty }

        let env = sender.batches.first!
        XCTAssertEqual(env.sdkVersion, "9.9")
        XCTAssertEqual(env.platform, "ios")
        XCTAssertEqual(env.hostAppId, "com.test")
        XCTAssertEqual(env.sessionId, "sess-42")
    }

    // MARK: - Error dedup + eager flush

    func testIdenticalErrorsAggregateWithNoOccurrenceLost() async {
        let store = FakeStore()
        let sender = FakeSender(); sender.gateFirst() // hold the first send so #2/#3 pile up
        let mgr = build(store: store, sender: sender)

        for _ in 0..<3 { mgr.recordError(signature: "api:decode", errorCode: "decode", message: "bad json") }
        // Give the eager flushes time to enqueue + park on the gate.
        try? await Task.sleep(nanoseconds: 50_000_000)
        sender.release()
        // Wait on the observable OUTCOME (all 3 occurrences delivered + buffer reconciled empty).
        // "store empty" alone is satisfied by the initial state: the persist/flush pipeline is
        // async, so on a slow CI simulator the assertions could run before anything was sent.
        await waitUntil {
            let delivered = self.allEvents(sender.batches)
                .filter { $0.type == TelemetryType.error }
                .reduce(0) { $0 + ($1.count ?? 0) }
            return delivered == 3 && store.load().isEmpty
        }

        let errors = allEvents(sender.batches).filter { $0.type == TelemetryType.error }
        XCTAssertTrue(errors.allSatisfy { $0.name == "api:decode" }, "only one distinct error signature")
        XCTAssertEqual(errors.reduce(0) { $0 + ($1.count ?? 0) }, 3, "all 3 occurrences accounted for")
    }

    func testErrorTriggersEagerFlush() async {
        let sender = FakeSender()
        let mgr = build(store: FakeStore(), sender: sender)
        mgr.recordError(signature: "api:fatal", errorCode: "fatal", message: "x")
        await waitUntil { !sender.batches.isEmpty }
        XCTAssertTrue(allEvents(sender.batches).contains { $0.type == TelemetryType.error && $0.name == "api:fatal" })
    }

    func testFacadeReplaysNonErrorEventsRecordedBeforeManagerInstall() async {
        let sender = FakeSender()
        let mgr = build(store: FakeStore(), sender: sender)
        let facade = Telemetry(installBackgroundObserver: false)
        facade.beginInstallationForTesting()

        facade.recordNetwork(
            path: "/session/create", method: "POST", statusCode: 200, durationMs: 4,
            requestBytes: 10, responseBytes: 20, failureClass: nil
        )
        facade.recordOperation(name: "preinstall_operation", durationMs: 2, success: true)
        facade.recordLifecycle(stage: "preinstall_lifecycle", adFormat: "native")
        facade.completeInstallation(with: mgr)
        let flushed = expectation(description: "facade flush completed")
        facade.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 2)

        await waitUntil {
            let names = Set(self.allEvents(sender.batches).map(\.name))
            return names.isSuperset(of: ["POST /session/create", "preinstall_operation", "preinstall_lifecycle"])
        }
    }

    func testFacadePreinstallEventBufferIsBounded() async {
        let sender = FakeSender()
        let mgr = build(store: FakeStore(), sender: sender)
        let facade = Telemetry(installBackgroundObserver: false)
        facade.beginInstallationForTesting()

        for index in 0..<25 {
            facade.recordOperation(name: "preinstall_\(index)", durationMs: 0, success: true)
        }
        facade.completeInstallation(with: mgr)
        let flushed = expectation(description: "facade flush completed")
        facade.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 2)

        await waitUntil {
            self.allEvents(sender.batches).filter { $0.name.hasPrefix("preinstall_") }.count == 20
        }
        let names = Set(allEvents(sender.batches).map(\.name))
        XCTAssertTrue(names.contains("preinstall_0"))
        XCTAssertTrue(names.contains("preinstall_19"))
        XCTAssertFalse(names.contains("preinstall_20"))
    }

    // MARK: - Durability + recovery

    func testRecoveryCompletesBeforePreinstallReplayCanPersistOrFlush() async {
        var recovered = TelemetryEvent(type: TelemetryType.network, name: "GET /recovered", eventId: "recovered", timestamp: 1)
        recovered.durationMs = 7
        let loadStarted = expectation(description: "recovery load started")
        let store = BlockingRecoveryStore([recovered], loadStarted: { loadStarted.fulfill() })
        let sender = FakeSender()
        let mgr = build(store: store, sender: sender)
        let facade = Telemetry(installBackgroundObserver: false)
        facade.beginInstallationForTesting()
        facade.recordOperation(name: "before_load", durationMs: 1, success: true)

        let installation = completeOffMain(facade, manager: mgr)
        await fulfillment(of: [loadStarted], timeout: 2)
        facade.recordOperation(name: "during_load", durationMs: 1, success: true)

        XCTAssertFalse(installation.hasReturned, "installation must remain blocked on persisted recovery")
        XCTAssertEqual(store.saveCount, 0, "replay must not persist before recovery returns")
        XCTAssertTrue(sender.batches.isEmpty, "replay must not flush before recovery returns")

        store.release()
        await waitUntil { installation.hasReturned }
        await waitUntil {
            let names = Set(self.allEvents(sender.batches).map(\.name))
            return names.isSuperset(of: ["GET /recovered", "before_load", "during_load"])
        }
    }

    func testCompleteInstallationPublishesManagerBeforeReturning() async {
        let sender = FakeSender()
        let mgr = build(store: FakeStore(), sender: sender)
        let facade = Telemetry(installBackgroundObserver: false)
        facade.beginInstallationForTesting()

        let installation = completeOffMain(facade, manager: mgr)
        await waitUntil { installation.hasReturned }

        facade.setSessionId("session-after-install")
        facade.recordError(signature: "after_install")
        await waitUntil { !sender.batches.isEmpty }

        XCTAssertEqual(sender.batches.last?.sessionId, "session-after-install")
        XCTAssertTrue(allEvents(sender.batches).contains { $0.name == "after_install" })
    }

    func testBackgroundFlushWaitsForActiveSendAndDrainsLeftovers() async {
        let sender = FakeSender()
        sender.gateFirst()
        let mgr = build(store: FakeStore(), sender: sender)
        mgr.recordOperation(name: "first", durationMs: 1, success: true)
        mgr.flushNow()
        await sender.waitUntilEntered()

        mgr.recordOperation(name: "second", durationMs: 1, success: true)
        let completed = expectation(description: "background flush completed")
        mgr.flushNow { completed.fulfill() }
        await waitUntil { mgr.pendingFlushWaiterCount == 1 }

        sender.release()
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(sender.batches.count, 2)
        XCTAssertTrue(sender.batches[0].events.contains { $0.name == "first" })
        XCTAssertTrue(sender.batches[1].events.contains { $0.name == "second" })
    }

    func testBackgroundDuringRecoveryIsRetainedUntilPublicationAndFlush() async {
        let loadStarted = expectation(description: "recovery load started")
        let store = BlockingRecoveryStore([], loadStarted: { loadStarted.fulfill() })
        let sender = FakeSender()
        let mgr = build(store: store, sender: sender)
        let facade = Telemetry(installBackgroundObserver: false)
        facade.beginInstallationForTesting()
        facade.recordOperation(name: "buffered", durationMs: 1, success: true)
        let installation = completeOffMain(facade, manager: mgr)
        await fulfillment(of: [loadStarted], timeout: 2)

        let center = NotificationCenter()
        let harness = BackgroundRequestHarness()
        let hook = TelemetryBackgroundFlush()
        hook.install(
            center: center,
            name: .init("test.background"),
            beginBackgroundTask: { expiration in
                harness.capture(expiration: expiration)
                return { harness.end() }
            },
            flush: { request in
                harness.capture(request: request)
                facade.requestBackgroundFlush(request)
            }
        )
        center.post(name: .init("test.background"), object: nil)
        XCTAssertFalse(harness.isFinished)
        XCTAssertEqual(harness.endCount, 0)

        store.release()
        await waitUntil { installation.hasReturned }
        await waitUntil { harness.endCount == 1 }
        XCTAssertTrue(harness.isFinished)
        XCTAssertTrue(allEvents(sender.batches).contains { $0.name == "buffered" })
    }

    func testBackgroundDuringRecoveryExpiresWithoutDoubleCompletionAfterPublication() async {
        let loadStarted = expectation(description: "recovery load started")
        let store = BlockingRecoveryStore([], loadStarted: { loadStarted.fulfill() })
        let sender = FakeSender()
        let mgr = build(store: store, sender: sender)
        let facade = Telemetry(installBackgroundObserver: false)
        facade.beginInstallationForTesting()
        facade.recordOperation(name: "startup", durationMs: 1, success: true)
        let installation = completeOffMain(facade, manager: mgr)
        await fulfillment(of: [loadStarted], timeout: 2)

        let center = NotificationCenter()
        let harness = BackgroundRequestHarness()
        let hook = TelemetryBackgroundFlush()
        hook.install(
            center: center,
            name: .init("test.background"),
            beginBackgroundTask: { expiration in
                harness.capture(expiration: expiration)
                return { harness.end() }
            },
            flush: { request in
                harness.capture(request: request)
                facade.requestBackgroundFlush(request)
            }
        )
        center.post(name: .init("test.background"), object: nil)
        harness.expire()
        XCTAssertTrue(harness.isFinished)
        XCTAssertEqual(harness.endCount, 1)

        store.release()
        await waitUntil { installation.hasReturned }
        await waitUntil { !sender.batches.isEmpty }
        XCTAssertEqual(harness.endCount, 1)
    }

    func testStartRecoversBufferLeftByPriorProcess() async {
        var seeded = TelemetryEvent(type: TelemetryType.network, name: "GET /catalog", eventId: "id-prev", timestamp: 1)
        seeded.durationMs = 7
        let store = FakeStore([seeded]); let sender = FakeSender()
        let mgr = build(store: store, sender: sender)

        mgr.start()
        await waitUntil { !sender.batches.isEmpty }

        XCTAssertTrue(allEvents(sender.batches).contains { $0.eventId == "id-prev" })
        await waitUntil { store.load().isEmpty }
    }

    // MARK: - Retry + drop

    func testFailedBatchRetriesUntilAccepted() async {
        let store = FakeStore()
        let sender = FakeSender(); sender.enqueueAcks([.retry, .retry, .accepted])
        let mgr = build(store: store, sender: sender)

        mgr.recordError(signature: "api:net", errorCode: "net", message: "timeout")
        // Error persistence is async (off the caller's thread), so wait on the observable
        // outcome — all sends done + the buffer reconciled empty — not the initial write.
        await waitUntil { sender.batches.count == 3 && store.load().isEmpty }

        XCTAssertEqual(sender.batches.count, 3, "1 initial attempt + 2 retries")
        XCTAssertTrue(sender.batches.allSatisfy { env in env.events.contains { $0.name == "api:net" } })
    }

    func testPermanent4xxDropsWithoutRetry() async {
        let store = FakeStore()
        let sender = FakeSender(); sender.defaultAck = .drop
        let mgr = build(store: store, sender: sender)

        mgr.recordError(signature: "api:bad", errorCode: "bad", message: "x")
        // Async error persistence → wait on the send + reconcile, not the initial write.
        await waitUntil { sender.batches.count == 1 && store.load().isEmpty }
        // Settle a beat to ensure no spurious retry was scheduled.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sender.batches.count, 1, "no retry on a permanent error")
    }

    // MARK: - Sampling + kill-switch

    func testSamplingDropsPerfButNotErrors() async {
        let sender = FakeSender()
        // random 0.9 >= sampleRate 0.5 → this session is NOT sampled in for perf.
        let mgr = build(store: FakeStore(), sender: sender, sampleRate: 0.5, random: { 0.9 })

        mgr.recordNetwork(path: "/load", method: "POST", statusCode: 200, durationMs: 5, requestBytes: 0, responseBytes: 10, failureClass: nil)
        mgr.recordError(signature: "api:err", errorCode: "err", message: "x")
        await waitUntil { !sender.batches.isEmpty }

        let events = allEvents(sender.batches)
        XCTAssertFalse(events.contains { $0.type == TelemetryType.network }, "perf suppressed by sampling")
        XCTAssertTrue(events.contains { $0.type == TelemetryType.error }, "errors always sent")
    }

    // MARK: - Dev-mode console log + redaction

    func testDebugLogReceivesALinePerRecordedEvent() async {
        let sink = LogSink()
        let mgr = build(store: FakeStore(), sender: FakeSender(), debugLog: { sink.append($0) })

        mgr.recordNetwork(path: "/load/interstitial", method: "POST", statusCode: 200, durationMs: 12, requestBytes: 0, responseBytes: 100, failureClass: nil)
        mgr.recordError(signature: "api:x", errorCode: "x", message: "boom")
        await waitUntil { sink.all.count >= 2 }

        XCTAssertTrue(sink.all.contains { $0.hasPrefix("network POST /load/interstitial") })
        XCTAssertTrue(sink.all.contains { $0.hasPrefix("error api:x") })
    }

    func testErrorMessagesAreSanitizedOfSecretsBeforeSendAndLog() async {
        let sink = LogSink()
        let sender = FakeSender()
        let mgr = build(store: FakeStore(), sender: sender, debugLog: { sink.append($0) })

        mgr.recordError(signature: "api:net", errorCode: "net", message: "GET https://x.com/cb?token=abc123&u=9 failed; Authorization: Bearer xyz789 apiKey=SEKRIT")
        await waitUntil { !sender.batches.isEmpty && !sink.all.isEmpty }

        let sent = allEvents(sender.batches).first { $0.type == TelemetryType.error }?.message ?? ""
        let logged = sink.all.first { $0.hasPrefix("error api:net") } ?? ""
        for haystack in [sent, logged] {
            XCTAssertFalse(haystack.contains("abc123"), "query/token stripped")
            XCTAssertFalse(haystack.contains("xyz789"), "bearer token stripped")
            XCTAssertFalse(haystack.contains("SEKRIT"), "key value stripped")
            XCTAssertFalse(haystack.contains("?token"), "query string stripped")
        }
    }

    func testServerKillSwitchMakesRecordingNoOp() async {
        let store = FakeStore(); let sender = FakeSender()
        let mgr = build(store: store, sender: sender)
        mgr.applyServerConfig(enabled: false, sampleRate: 1.0)

        mgr.recordNetwork(path: "/load", method: "POST", statusCode: 200, durationMs: 5, requestBytes: 0, responseBytes: 10, failureClass: nil)
        mgr.recordError(signature: "api:err", errorCode: "err", message: "x")
        try? await Task.sleep(nanoseconds: 100_000_000) // can't poll for absence; settle then assert

        XCTAssertTrue(sender.batches.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - Consent-gated PII

    func testPiiIncludedWhenProvidedAndOmittedWhenNot() async {
        let withPii = FakeSender()
        // Retain the manager: its eager-flush Task captures `self` weakly (in production the
        // manager is retained by Telemetry.shared), so a temporary would be freed before flush.
        let mgrWith = build(store: FakeStore(), sender: withPii, ppid: "user-1", gaid: "gaid-1")
        mgrWith.recordError(signature: "e", errorCode: "c", message: "m")
        await waitUntil { !withPii.batches.isEmpty }
        XCTAssertEqual(withPii.batches.first?.primaryUserId, "user-1")
        XCTAssertEqual(withPii.batches.first?.advertisingId, "gaid-1")

        let noPii = FakeSender()
        let mgrWithout = build(store: FakeStore(), sender: noPii, ppid: nil, gaid: nil)
        mgrWithout.recordError(signature: "e", errorCode: "c", message: "m")
        await waitUntil { !noPii.batches.isEmpty }
        XCTAssertNil(noPii.batches.first?.primaryUserId)
        XCTAssertNil(noPii.batches.first?.advertisingId)
    }
}
