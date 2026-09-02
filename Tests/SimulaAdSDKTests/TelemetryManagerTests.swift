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

    /// Holds the first persistence write so tests can verify that network reconciliation does not
    /// wait for storage while preserving the order of all queued snapshots.
    private final class SlowStore: TelemetryStoring, @unchecked Sendable {
        private let lock = NSLock()
        private let firstSaveGate = DispatchSemaphore(value: 0)
        private var data: [TelemetryEvent] = []
        private var shouldBlockFirstSave = true
        private var _saveStarted = false
        private var _saveCount = 0
        private var _savedNames: [[String]] = []
        private let startedSignal = TestSignal()

        var saveStarted: Bool { lock.lock(); defer { lock.unlock() }; return _saveStarted }
        var saveCount: Int { lock.lock(); defer { lock.unlock() }; return _saveCount }
        var savedNames: [[String]] { lock.lock(); defer { lock.unlock() }; return _savedNames }

        func load() -> [TelemetryEvent] { lock.lock(); defer { lock.unlock() }; return data }

        func save(_ events: [TelemetryEvent]) {
            lock.lock()
            _saveStarted = true
            let shouldBlock = shouldBlockFirstSave
            lock.unlock()
            startedSignal.signal()
            if shouldBlock { firstSaveGate.wait() }
            lock.lock()
            data = events
            _saveCount += 1
            _savedNames.append(events.map(\.name))
            lock.unlock()
        }

        func release() {
            lock.lock()
            let shouldSignal = shouldBlockFirstSave
            shouldBlockFirstSave = false
            lock.unlock()
            if shouldSignal { firstSaveGate.signal() }
        }


        func waitForSaveStarted() async { await startedSignal.wait() }
    }

    /// Records decoded batches; replays queued acks then falls back to `defaultAck`. Optional
    /// one-shot gate so a test can hold the first send in flight while it enqueues more work.
    private final class FakeSender: TelemetrySending, @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [TelemetryEnvelope] = []
        private var acks: [TelemetryAck] = []
        private var defaultAck: TelemetryAck = .accepted
        private var gateCont: CheckedContinuation<Void, Never>?
        private var gated = false
        private var _attemptCount = 0

        var batches: [TelemetryEnvelope] { lock.lock(); defer { lock.unlock() }; return _batches }
        var attemptCount: Int { lock.lock(); defer { lock.unlock() }; return _attemptCount }
        func enqueueAcks(_ a: [TelemetryAck]) { lock.lock(); acks = a; lock.unlock() }
        func setDefaultAck(_ ack: TelemetryAck) { lock.lock(); defaultAck = ack; lock.unlock() }
        func gateFirst() { lock.lock(); gated = true; lock.unlock() }
        func release() {
            lock.lock(); let c = gateCont; gateCont = nil; gated = false; lock.unlock()
            c?.resume()
        }

        func send(_ body: Data) async -> TelemetryAck {
            lock.lock()
            _attemptCount += 1
            let shouldGate = gated
            lock.unlock()
            if shouldGate {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    // Re-check under the lock: if release() ran between the gated read above and
                    // here, parking now would leak the continuation and deadlock the flush.
                    lock.lock()
                    if gated { gateCont = cont; lock.unlock() }
                    else { lock.unlock(); cont.resume() }
                }
            }
            lock.lock()
            if let env = try? JSONDecoder().decode(TelemetryEnvelope.self, from: body) { _batches.append(env) }
            let ack = acks.isEmpty ? defaultAck : acks.removeFirst()
            lock.unlock()
            return ack
        }
    }

    private final class BlockingProvider: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var shouldBlock = true
        private var _started = false
        private let startedSignal = TestSignal()

        var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }

        func value() -> TelemetryIdentity {
            lock.lock()
            _started = true
            let block = shouldBlock
            lock.unlock()
            startedSignal.signal()
            if block { gate.wait() }
            return TelemetryIdentity(sessionId: nil, primaryUserId: nil)
        }

        func release() {
            lock.lock()
            let signal = shouldBlock
            shouldBlock = false
            lock.unlock()
            if signal { gate.signal() }
        }

        func waitUntilStarted() async { await startedSignal.wait() }
    }

    private final class ReentrantProvider: @unchecked Sendable {
        private let lock = NSLock()
        weak var manager: TelemetryManager?
        private var didRecord = false

        func value() -> TelemetryIdentity {
            lock.lock()
            let shouldRecord = !didRecord
            didRecord = true
            lock.unlock()
            if shouldRecord {
                manager?.recordOperation(name: "provider_reentrant", durationMs: 0, success: true)
            }
            return TelemetryIdentity(sessionId: nil, primaryUserId: nil)
        }
    }

    private final class CountingIdentityProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

        func value() -> TelemetryIdentity {
            lock.lock()
            _callCount += 1
            let suffix = _callCount
            lock.unlock()
            return TelemetryIdentity(sessionId: "session-\(suffix)", primaryUserId: "user-\(suffix)")
        }
    }

    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TelemetryInitialization?

        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
        var initialization: TelemetryInitialization? {
            lock.lock(); defer { lock.unlock() }; return value
        }
        func set(_ initialization: TelemetryInitialization) {
            lock.lock(); value = initialization; lock.unlock()
        }
    }

    private final class ManualTimeoutScheduler: TelemetryTimeoutScheduling, @unchecked Sendable {
        private struct Scheduled {
            let timeout: TimeInterval
            let completion: @Sendable () -> Void
        }

        private let lock = NSLock()
        private var scheduled: [Scheduled] = []

        var requestedTimeouts: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return scheduled.map(\.timeout)
        }

        func schedule(after timeout: TimeInterval, completion: @escaping @Sendable () -> Void) {
            lock.lock()
            scheduled.append(Scheduled(timeout: timeout, completion: completion))
            lock.unlock()
        }

        func fireNext() {
            lock.lock()
            let next = scheduled.isEmpty ? nil : scheduled.removeFirst()
            lock.unlock()
            next?.completion()
        }
    }

    private final class BlockingManagerFactory: @unchecked Sendable {
        private let lock = NSLock()
        private let gate: LaunchSettling
        private let manager: TelemetryManager
        private var calls: [(String, Bool)] = []
        private let callSignal = TestSignal()

        init(gate: LaunchSettling, manager: TelemetryManager) {
            self.gate = gate
            self.manager = manager
        }

        var recordedCalls: [(String, Bool)] { lock.lock(); defer { lock.unlock() }; return calls }

        func make(apiKey: String, devMode: Bool) async -> TelemetryManager {
            record(apiKey: apiKey, devMode: devMode)
            await gate.waitUntilSettled()
            return manager
        }

        private func record(apiKey: String, devMode: Bool) {
            lock.lock(); calls.append((apiKey, devMode)); lock.unlock()
            callSignal.signal()
        }

        func waitForCall() async { await callSignal.wait() }
    }

    // MARK: - Builder

    private func build(
        store: TelemetryStoring,
        sender: TelemetrySending,
        enabled: Bool = true,
        sampleRate: Double = 1.0,
        random: @escaping @Sendable () -> Double = { 0.0 },
        sessionId: String? = nil,
        ppid: String? = nil,
        gaid: String? = nil,
        identityProvider: (@Sendable () -> TelemetryIdentity)? = nil,
        debugLog: (@Sendable (String) -> Void)? = nil,
        persistenceWaitTimeout: TimeInterval = 0.1,
        launchGate: LaunchSettling = ImmediateLaunchSettledGate.shared,
        now: @escaping @Sendable () -> TimeInterval = { 1_000 },
        backoff: @escaping @Sendable (Int) -> TimeInterval = { _ in 0 },
        timedFlushSleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        retrySleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        timeoutScheduler: any TelemetryTimeoutScheduling = DispatchTelemetryTimeoutScheduler()
    ) -> TelemetryManager {
        let manager = TelemetryManager(
            ctx: TelemetryContext(sdkVersion: "9.9", osVersion: "14", deviceModel: "TestPhone", hostAppId: "com.test", devMode: true),
            store: store,
            sender: sender,
            identityProvider: identityProvider ?? {
                TelemetryIdentity(sessionId: sessionId, primaryUserId: ppid, advertisingId: gaid)
            },
            enabled: enabled,
            sampleRate: sampleRate,
            now: now,
            random: random,
            backoff: backoff,
            timedFlushSleep: timedFlushSleep,
            retrySleep: retrySleep,
            timeoutScheduler: timeoutScheduler,
            launchGate: launchGate,
            debugLog: debugLog,
            flushThreshold: 20,
            flushInterval: 0.05, // sub-threshold perf flushes promptly via the timer
            persistenceWaitTimeout: persistenceWaitTimeout
        )
        manager.start()
        return manager
    }

    /// Thread-safe line collector for the debug-log tests.
    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private func allEvents(_ s: [TelemetryEnvelope]) -> [TelemetryEvent] { s.flatMap { $0.events } }

    // MARK: - Batching + flush

    func testSubThresholdPerfFlushesOnTimerAndClears() async {
        let store = FakeStore(); let sender = FakeSender()
        let sleep = ControllablePersistenceSleep()
        let mgr = build(store: store, sender: sender, timedFlushSleep: { await sleep.sleep($0) })
        // Recovery intentionally requests an immediate flush for recovered or concurrently recorded
        // work. Settle it before exercising the independent periodic-flush path.
        await mgr.waitForRecoveryForTests()
        await mgr.waitForImmediateFlushIdleForTests()

        for _ in 0..<3 {
            mgr.recordNetwork(path: "/load/interstitial", method: "POST", statusCode: 200, durationMs: 12, requestBytes: 0, responseBytes: 100, failureClass: nil)
        }
        let delay = await sleep.waitForRequest()
        XCTAssertEqual(delay, 0.05)
        XCTAssertTrue(sender.batches.isEmpty)
        sleep.release()
        await waitUntil {
            self.allEvents(sender.batches).filter { $0.type == TelemetryType.network }.count == 3
        }

        let net = allEvents(sender.batches).filter { $0.type == TelemetryType.network }
        XCTAssertEqual(net.count, 3)
        XCTAssertTrue(net.allSatisfy { $0.name == "POST /load/interstitial" && $0.durationMs == 12 })
        await waitUntil { store.load().isEmpty }
    }

    func testPostSendPersistenceDoesNotDelayRedrainOrLoseInflightEvents() async {
        let store = SlowStore()
        let sender = FakeSender(); sender.gateFirst()
        let mgr = build(store: store, sender: sender)
        defer { store.release() }

        mgr.recordError(signature: "api:first")
        await waitUntil { store.saveStarted && sender.attemptCount == 1 }

        mgr.recordError(signature: "api:inflight")
        sender.release()

        // The first disk write remains blocked. Reconciliation must still immediately re-drain
        // the event recorded during the first network send instead of synchronously waiting here.
        await waitUntil { sender.batches.count == 2 }
        XCTAssertEqual(sender.batches.map { $0.events.filter { $0.type == TelemetryType.error }.map(\.name) }, [["api:first"], ["api:inflight"]])
        XCTAssertEqual(store.saveCount, 0, "both sends completed while persistence was blocked")

        store.release()
        await waitUntil { store.saveCount >= 4 && store.load().isEmpty }
        let savedNames = store.savedNames
        XCTAssertTrue(savedNames.contains { Set($0) == ["api:first"] })
        XCTAssertTrue(savedNames.contains { Set($0) == ["api:first", "api:inflight"] })
        XCTAssertTrue(savedNames.contains { Set($0) == ["api:inflight"] })
        XCTAssertTrue(savedNames.last?.isEmpty == true)
    }

    func testCriticalClickRedrainsWhenImmediateRequestCollidesWithPeriodicFlush() async {
        for iteration in 0..<10 {
            let sender = FakeSender()
            sender.gateFirst()
            let sleep = ControllablePersistenceSleep()
            let mgr = build(
                store: FakeStore(),
                sender: sender,
                timedFlushSleep: { await sleep.sleep($0) }
            )
            await mgr.waitForRecoveryForTests()
            await mgr.waitForImmediateFlushIdleForTests()

            mgr.recordNetwork(
                path: "/load/interstitial",
                method: "POST",
                statusCode: 200,
                durationMs: 1,
                requestBytes: 0,
                responseBytes: 1,
                failureClass: nil
            )
            _ = await sleep.waitForRequest()
            sleep.release()
            await waitUntil { sender.attemptCount == 1 }

            let interactionId = "critical-inflight-\(iteration)"
            mgr.recordLifecycle(
                stage: "click_fired",
                adFormat: "interstitial",
                adUnitId: "unit",
                adId: "serve",
                serveId: "serve",
                durationMs: nil,
                errorCode: nil,
                interactionId: interactionId,
                clickSource: "primary_cta"
            )

            let settled = TestSignal()
            Task { await mgr.waitForImmediateFlushIdleForTests(); settled.signal() }
            await Task.yield()
            XCTAssertFalse(
                settled.isSignaled,
                "in-flight send must not report reconciliation at iteration \(iteration)"
            )

            sender.release()
            await settled.wait()

            XCTAssertEqual(sender.attemptCount, 2, "iteration \(iteration)")
            XCTAssertEqual(
                allEvents(sender.batches).filter { $0.interactionId == interactionId }.count,
                1,
                "iteration \(iteration)"
            )
        }
    }

    func testFlushNowDoesNotWaitIndefinitelyForBlockedPersistence() async {
        let store = SlowStore()
        let mgr = build(
            store: store,
            sender: FakeSender(),
            persistenceWaitTimeout: 0.01
        )
        defer { store.release() }
        mgr.recordError(signature: "api:blocked_persistence")
        await store.waitForSaveStarted()

        let completion = TestSignal()
        let queue = DispatchQueue(label: "telemetry-flush-now-probe")
        queue.async {
            mgr.flushNow()
            completion.signal()
        }
        await completion.wait()

        XCTAssertEqual(store.saveCount, 0, "flush returns while the first persistence write remains blocked")
    }

    func testHandoffPersistenceBarrierFallsBackWhenStoreStalls() async {
        let store = SlowStore()
        let sender = FakeSender()
        let timeoutScheduler = ManualTimeoutScheduler()
        let mgr = build(store: store, sender: sender, timeoutScheduler: timeoutScheduler)
        defer { store.release() }
        await store.waitForSaveStarted()
        let released = TestSignal()

        mgr.afterPendingPersistence(timeout: 0.02) { released.signal() }
        XCTAssertEqual(timeoutScheduler.requestedTimeouts, [0.02])
        XCTAssertFalse(released.isSignaled)

        timeoutScheduler.fireNext()
        XCTAssertTrue(released.isSignaled)
    }

    func testEnvelopeCarriesContextAndSessionId() async {
        let sender = FakeSender()
        let mgr = build(store: FakeStore(), sender: sender, sessionId: "sess-42")
        mgr.recordError(signature: "api:boom", errorCode: "boom", message: "msg")
        await waitUntil { !sender.batches.isEmpty }

        let env = sender.batches.first!
        XCTAssertEqual(env.sdkVersion, "9.9")
        XCTAssertEqual(env.platform, "ios")
        XCTAssertEqual(env.hostAppId, "com.test")
        XCTAssertEqual(env.sessionId, "sess-42")
    }

    func testEnvelopeReadsOneCoherentIdentitySnapshot() async {
        let provider = CountingIdentityProvider()
        let sender = FakeSender()
        let mgr = build(
            store: FakeStore(), sender: sender,
            identityProvider: { provider.value() }
        )

        mgr.recordError(signature: "api:coherent_identity")
        await waitUntil { !sender.batches.isEmpty }

        XCTAssertEqual(sender.batches.first?.sessionId, "session-1")
        XCTAssertEqual(sender.batches.first?.primaryUserId, "user-1")
        XCTAssertEqual(provider.callCount, 1)
    }

    func testBlockingFlushProviderDoesNotBlockConcurrentRecording() async {
        let provider = BlockingProvider()
        let sender = FakeSender()
        let mgr = build(
            store: FakeStore(),
            sender: sender,
            identityProvider: { provider.value() }
        )
        defer { provider.release() }

        mgr.recordError(signature: "api:flush_provider")
        await provider.waitUntilStarted()

        let recorded = TestSignal()
        DispatchQueue(label: "telemetry-provider-record-probe").async {
            mgr.recordOperation(name: "while_provider_blocked", durationMs: 0, success: true)
            recorded.signal()
        }
        await recorded.wait()

        provider.release()
        await waitUntil { !sender.batches.isEmpty }
    }

    func testReentrantFlushProviderDoesNotDeadlock() async {
        let provider = ReentrantProvider()
        let sender = FakeSender()
        let mgr = build(
            store: FakeStore(),
            sender: sender,
            identityProvider: { provider.value() }
        )
        provider.manager = mgr

        mgr.recordError(signature: "api:reentrant_provider")
        await waitUntil {
            self.allEvents(sender.batches).contains { $0.name == "provider_reentrant" }
        }

        XCTAssertTrue(allEvents(sender.batches).contains { $0.name == "api:reentrant_provider" })
    }

    func testDuplicateInitializeMetaCountsAggregateIntoOneEvent() async {
        let sender = FakeSender()
        let sleep = ControllablePersistenceSleep()
        let mgr = build(
            store: FakeStore(), sender: sender,
            timedFlushSleep: { await sleep.sleep($0) }
        )
        await mgr.waitForRecoveryForTests()
        await mgr.waitForImmediateFlushIdleForTests()

        mgr.recordMeta(name: "duplicate_initialize", count: 2)
        mgr.recordMeta(name: "duplicate_initialize", count: 3)
        _ = await sleep.waitForRequest()
        mgr.recordError(signature: "api:flush_meta")
        await waitUntil {
            self.allEvents(sender.batches).contains { $0.name == "duplicate_initialize" }
        }

        let duplicates = allEvents(sender.batches).filter { $0.name == "duplicate_initialize" }
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.type, TelemetryType.meta)
        XCTAssertEqual(duplicates.first?.count, 5)
        sleep.release()
        await sleep.waitForCompletion()
    }

    func testDuplicateMetaRemainderAfterAcceptedInflightClaimGetsNewEventId() async {
        let sender = FakeSender()
        sender.gateFirst()
        let sleep = ControllablePersistenceSleep()
        let mgr = build(
            store: FakeStore(), sender: sender,
            timedFlushSleep: { await sleep.sleep($0) }
        )

        mgr.recordMeta(name: "duplicate_initialize", count: 2)
        _ = await sleep.waitForRequest()
        mgr.recordError(signature: "api:flush_meta")
        await waitUntil { sender.attemptCount == 1 }
        mgr.recordMeta(name: "duplicate_initialize", count: 3)
        sender.release()
        await waitUntil {
            self.allEvents(sender.batches).filter { $0.name == "duplicate_initialize" }.count == 2
        }

        let duplicates = allEvents(sender.batches).filter { $0.name == "duplicate_initialize" }
        XCTAssertEqual(duplicates.map { $0.count ?? 0 }, [2, 3])
        XCTAssertEqual(Set(duplicates.map(\.eventId)).count, 2)
        XCTAssertEqual(duplicates.compactMap(\.sampleRate), [1, 1])
        sleep.release()
        await sleep.waitForCompletion()
    }

    func testDuplicateMetaUpdateIsPersistedPromptlyWhileSendIsLaunchGated() async {
        let store = FakeStore()
        let gate = ControllableLaunchSettledGate()
        let mgr = build(store: store, sender: FakeSender(), launchGate: gate)
        await mgr.waitForRecoveryForTests()

        mgr.recordMeta(name: "duplicate_initialize", count: 4)
        await waitUntil {
            store.load().contains { $0.name == "duplicate_initialize" && $0.count == 4 }
        }
        await gate.open()
    }

    func testDuplicateInitializePendingCountIsBoundedAndDrainsOnce() {
        var buffer = DuplicateInitializeCountBuffer(limit: 3)
        for _ in 0..<10 { buffer.increment() }

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.drain(), 3)
        XCTAssertEqual(buffer.drain(), 0)
    }

    func testLaterInitializeWaitsForWinningManagerPublicationAndCallerCancellationDoesNotAbandonIt() async {
        let sender = FakeSender()
        let manager = build(store: FakeStore(), sender: sender)
        await manager.waitForRecoveryForTests()
        await manager.waitForImmediateFlushIdleForTests()
        let gate = ControllableLaunchSettledGate()
        let factory = BlockingManagerFactory(gate: gate, manager: manager)
        let telemetry = Telemetry(managerFactory: { apiKey, devMode in
            await factory.make(apiKey: apiKey, devMode: devMode)
        })
        let winnerCompleted = CompletionFlag()
        let laterCompleted = CompletionFlag()
        let laterStarted = TestSignal()

        let winner = Task {
            await Self.runInitialize(
                telemetry, apiKey: "winning-key", devMode: true, enabled: true,
                completion: winnerCompleted
            )
        }
        await factory.waitForCall()
        winner.cancel()
        telemetry.recordDuplicateInitialize()
        let later = Task {
            laterStarted.signal()
            await Self.runInitialize(
                telemetry, apiKey: "losing-key", devMode: false, enabled: false,
                completion: laterCompleted
            )
        }
        await laterStarted.wait()

        XCTAssertFalse(winnerCompleted.isSet)
        XCTAssertFalse(laterCompleted.isSet)
        XCTAssertEqual(factory.recordedCalls.count, 1)

        await gate.open()
        await winner.value
        await later.value
        XCTAssertTrue(winnerCompleted.isSet)
        XCTAssertTrue(laterCompleted.isSet)
        XCTAssertEqual(factory.recordedCalls.first?.0, "winning-key")
        XCTAssertEqual(factory.recordedCalls.first?.1, true)
        XCTAssertEqual(winnerCompleted.initialization?.enabled, true)
        XCTAssertEqual(laterCompleted.initialization, winnerCompleted.initialization)

        telemetry.recordError(signature: "api:published")
        await waitUntil {
            let events = self.allEvents(sender.batches)
            return events.contains { $0.name == "api:published" }
                && events.contains { $0.name == "duplicate_initialize" && $0.count == 1 }
        }
    }

    private static func runInitialize(
        _ telemetry: Telemetry,
        apiKey: String,
        devMode: Bool,
        enabled: Bool,
        completion: CompletionFlag
    ) async {
        let effective = await telemetry.initialize(apiKey: apiKey, devMode: devMode, enabled: enabled)
        completion.set(effective)
    }

    func testLogHostDebugPrintsOnlyInDevMode() async {
        let productionSink = LogSink()
        let productionTelemetry = Telemetry(
            managerFactory: { _, _ in
                XCTFail("logHostDebug must not create a manager")
                return self.build(store: FakeStore(), sender: FakeSender())
            },
            hostDebugPrint: { productionSink.append($0) }
        )
        productionTelemetry.logHostDebug("before initialization")
        _ = await productionTelemetry.initialize(apiKey: "production", devMode: false, enabled: false)
        productionTelemetry.logHostDebug("production")
        XCTAssertTrue(productionSink.all.isEmpty)

        let developmentSink = LogSink()
        let developmentTelemetry = Telemetry(
            managerFactory: { _, _ in
                XCTFail("logHostDebug must not create a manager")
                return self.build(store: FakeStore(), sender: FakeSender())
            },
            hostDebugPrint: { developmentSink.append($0) }
        )
        _ = await developmentTelemetry.initialize(apiKey: "development", devMode: true, enabled: false)
        developmentTelemetry.logHostDebug("AUDIO_STATE_CHANGED muted=false volume=50")
        XCTAssertEqual(developmentSink.all, ["[SimulaAdSDK] AUDIO_STATE_CHANGED muted=false volume=50"])
    }

    func testDisabledFirstEnabledSecondReturnsDisabledWinningStateToBothCallers() async {
        let factoryCalled = CompletionFlag()
        let unexpectedManager = build(store: FakeStore(), sender: FakeSender())
        let telemetry = Telemetry(managerFactory: { _, _ in
            factoryCalled.set(TelemetryInitialization(apiKey: "unexpected", devMode: false, enabled: true))
            return unexpectedManager
        })

        let first = await telemetry.initialize(apiKey: "disabled-key", devMode: true, enabled: false)
        let second = await telemetry.initialize(apiKey: "enabled-key", devMode: false, enabled: true)

        XCTAssertEqual(first, TelemetryInitialization(apiKey: "disabled-key", devMode: true, enabled: false))
        XCTAssertEqual(second, first)
        XCTAssertFalse(factoryCalled.isSet)
    }

    func testEnabledFirstDisabledSecondReturnsEnabledWinningStateToBothCallers() async {
        let manager = build(store: FakeStore(), sender: FakeSender())
        let factory = BlockingManagerFactory(gate: ImmediateLaunchSettledGate.shared, manager: manager)
        let telemetry = Telemetry(managerFactory: { apiKey, devMode in
            await factory.make(apiKey: apiKey, devMode: devMode)
        })

        let first = await telemetry.initialize(apiKey: "enabled-key", devMode: true, enabled: true)
        let second = await telemetry.initialize(apiKey: "disabled-key", devMode: false, enabled: false)

        XCTAssertEqual(first, TelemetryInitialization(apiKey: "enabled-key", devMode: true, enabled: true))
        XCTAssertEqual(second, first)
        XCTAssertEqual(factory.recordedCalls.count, 1)
    }

    // MARK: - Error dedup + eager flush

    func testIdenticalErrorsAggregateWithNoOccurrenceLost() async {
        let store = FakeStore()
        let sender = FakeSender(); sender.gateFirst() // hold the first send so #2/#3 pile up
        let mgr = build(store: store, sender: sender)

        for _ in 0..<3 { mgr.recordError(signature: "api:decode", errorCode: "decode", message: "bad json") }
        await waitUntil { sender.attemptCount == 1 }
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

    // MARK: - Durability + recovery

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

    func testRecoveredTelemetryDoesNotSendUntilLaunchSettles() async {
        let seeded = TelemetryEvent(type: TelemetryType.error, name: "recovered", eventId: "old", timestamp: 1)
        let store = FakeStore([seeded])
        let sender = FakeSender()
        let gate = ControllableLaunchSettledGate()
        let mgr = build(store: store, sender: sender, launchGate: gate)

        mgr.start()
        await waitForGateWaiters(gate, count: 1)
        XCTAssertEqual(sender.attemptCount, 0)
        XCTAssertEqual(store.load().map(\.eventId), ["old"], "recovery may load promptly but cannot send early")

        await gate.open()
        await waitUntil { sender.attemptCount == 1 && store.load().isEmpty }
    }

    func testErrorBurstCreatesOneLaunchGateWaiter() async {
        let sender = FakeSender()
        let gate = ControllableLaunchSettledGate()
        let mgr = build(store: FakeStore(), sender: sender, launchGate: gate)

        for _ in 0..<100 { mgr.recordError(signature: "launch:error") }
        await waitForGateWaiters(gate, count: 1)
        let waiterCount = await gate.waitCount
        XCTAssertEqual(waiterCount, 1)
        XCTAssertEqual(sender.attemptCount, 0)

        await gate.open()
        await waitUntil {
            self.allEvents(sender.batches).contains { $0.name == "launch:error" && $0.count == 100 }
        }
        let error = allEvents(sender.batches).first { $0.name == "launch:error" }
        XCTAssertEqual(error?.count, 100)
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

    func testRetryBackoffCannotBeBypassedByImmediateFlush() async {
        let sender = FakeSender()
        sender.enqueueAcks([.retry, .accepted])
        let sleep = ControllablePersistenceSleep()
        let mgr = build(
            store: FakeStore(), sender: sender, backoff: { _ in 0.1 },
            retrySleep: { await sleep.sleep($0) }
        )

        mgr.recordError(signature: "api:backoff")
        await waitUntil { sender.attemptCount == 1 }
        let delay = await sleep.waitForRequest()
        XCTAssertEqual(delay, 0.1)
        XCTAssertEqual(sender.attemptCount, 1)

        sleep.release()
        await waitUntil { sender.attemptCount == 2 }
    }

    func testPermanent4xxDropsWithoutRetry() async {
        let store = FakeStore()
        let sender = FakeSender(); sender.setDefaultAck(.drop)
        let mgr = build(store: store, sender: sender)

        mgr.recordError(signature: "api:bad", errorCode: "bad", message: "x")
        await waitUntil { sender.attemptCount == 1 }
        await mgr.waitForImmediateFlushIdleForTests()
        XCTAssertEqual(sender.batches.count, 1, "no retry on a permanent error")
    }

    // MARK: - Sampling + kill-switch

    func testSamplingDropsPerfButNotErrors() async {
        let sender = FakeSender()
        // random 0.9 >= sampleRate 0.5 → this session is NOT sampled in for perf.
        let mgr = build(store: FakeStore(), sender: sender, sampleRate: 0.5, random: { 0.9 })

        mgr.recordNetwork(path: "/load", method: "POST", statusCode: 200, durationMs: 5, requestBytes: 0, responseBytes: 10, failureClass: nil)
        mgr.recordOperation(name: "expected_condition", durationMs: 0, success: false)
        mgr.recordError(signature: "api:err", errorCode: "err", message: "x")
        await waitUntil { !sender.batches.isEmpty }

        let events = allEvents(sender.batches)
        XCTAssertFalse(events.contains { $0.type == TelemetryType.network }, "perf suppressed by sampling")
        XCTAssertFalse(events.contains { $0.type == TelemetryType.operation }, "operations suppressed by sampling")
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
        await mgr.waitForRecoveryForTests()
        await mgr.waitForImmediateFlushIdleForTests()

        XCTAssertTrue(sender.batches.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testServerKillSwitchDropsEventsWaitingForLaunchGate() async {
        let store = FakeStore()
        let sender = FakeSender()
        let gate = ControllableLaunchSettledGate()
        let mgr = build(store: store, sender: sender, launchGate: gate)

        mgr.recordError(signature: "queued-before-disable")
        await waitForGateWaiters(gate, count: 1)
        mgr.applyServerConfig(enabled: false, sampleRate: 1)
        await gate.open()
        await mgr.waitForImmediateFlushIdleForTests()

        XCTAssertEqual(sender.attemptCount, 0)
    }

    func testRecoveredExtremeValuesCannotOverflowFlush() async {
        var countExtreme = TelemetryEvent(type: TelemetryType.error, name: "count-extreme", eventId: "count-old", timestamp: 1_000)
        countExtreme.count = Int.max
        let ageExtreme = TelemetryEvent(type: TelemetryType.error, name: "age-extreme", eventId: "age-old", timestamp: -1e100)
        let store = FakeStore([countExtreme, ageExtreme])
        let sender = FakeSender()
        let gate = ControllableLaunchSettledGate()
        let mgr = build(store: store, sender: sender, launchGate: gate)

        mgr.start()
        mgr.recordError(signature: "count-extreme")
        await waitForGateWaiters(gate, count: 1)
        await gate.open()
        await waitUntil {
            let names = self.allEvents(sender.batches).map(\.name)
            return names.contains("count-extreme") && names.contains("age-extreme")
        }

        let events = allEvents(sender.batches)
        XCTAssertEqual(events.first { $0.name == "count-extreme" }?.count, Int.max)
        XCTAssertEqual(events.first { $0.name == "age-extreme" }?.eventAgeMs, Int.max)
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

    private func waitForGateWaiters(_ gate: ControllableLaunchSettledGate, count: Int) async {
        await waitUntil { await gate.waitCount >= count }
    }
}

private final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool {
        lock.lock(); defer { lock.unlock() }
        return signaled
    }

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
