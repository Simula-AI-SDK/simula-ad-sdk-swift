import XCTest
@testable import SimulaAdSDK

/// Tier-1 tests for the durable impression/click beacon queue: delivery / permanent-drop / retain /
/// dedup / recovery, exercised with in-memory fake stores/senders and a controllable clock — no
/// network, simulator preferences daemon, or wall-clock timing.
final class AdBeaconManagerTests: XCTestCase {

    // Must mirror AdBeaconManager.userDefaultsKey (private there).
    private let queueKey = "simula_pending_beacons"

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "beacon-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func persistedQueue() -> [PendingBeacon] {
        guard let data = defaults.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([PendingBeacon].self, from: data)) ?? []
    }

    func test2xxDeliversAndRemoves() async {
        let sender = FakeBeaconSender()
        sender.setCode(200, for: "imp", "seen")
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        await waitUntil { sender.callCount("imp", "seen") == 1 && store.persisted.isEmpty }
        XCTAssertEqual(sender.callCount("imp", "seen"), 1)
    }

    func testPermanent4xxDropsWithoutRetry() async {
        let sender = FakeBeaconSender()
        sender.setCode(400, for: "imp", "click")
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "click")
        await waitUntil { sender.callCount("imp", "click") == 1 && store.persisted.isEmpty }
        XCTAssertEqual(sender.callCount("imp", "click"), 1)
    }

    func test5xxKeepsAndRecordsAttempt() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 1000 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        await waitUntil { store.persisted.first?.retryCount == 1 }
        let q = store.persisted
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.first?.lastAttemptTimestamp, 1000)
        XCTAssertEqual(sender.callCount("imp", "seen"), 1)
    }

    func testConnectivityFailureKeepsBeacon() async {
        let sender = FakeBeaconSender()
        sender.setError(URLError(.notConnectedToInternet), for: "imp", "seen")
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        await waitUntil { store.persisted.first?.retryCount == 1 }
        XCTAssertEqual(store.persisted.count, 1)
    }

    func testDuplicateBeaconEnqueuedOnce() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen") // keep it queued
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        mgr.enqueue(impressionId: "imp", action: "seen") // duplicate
        await waitUntil { store.persisted.first?.retryCount ?? 0 >= 1 }
        XCTAssertEqual(store.persisted.count, 1)
    }

    func testSeenMetadataIsPersistedAndForwarded() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 1000 })

        mgr.enqueue(
            impressionId: "imp",
            action: "seen",
            metadata: ["page_name": "Search", "surface": "chat"]
        )

        await waitUntil { store.persisted.first?.retryCount == 1 }
        XCTAssertEqual(store.persisted.first?.metadata, ["page_name": "Search", "surface": "chat"])
        XCTAssertEqual(sender.lastMetadata("imp", "seen"), ["page_name": "Search", "surface": "chat"])
    }

    func testDuplicateSeenMergesMetadataWithoutResettingRetry() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 1000 })

        mgr.enqueue(impressionId: "imp", action: "seen", metadata: ["page_name": "Search"])
        await waitUntil { store.persisted.first?.retryCount == 1 }
        mgr.enqueue(impressionId: "imp", action: "seen", metadata: ["surface": "chat"])

        await waitUntil { store.persisted.first?.metadata?["surface"] == "chat" }
        let queued = store.persisted.first
        XCTAssertEqual(queued?.metadata, ["page_name": "Search", "surface": "chat"])
        XCTAssertEqual(queued?.retryCount, 1)
    }

    func testDuplicateSeenMergeRemainsBounded() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 1000 })
        let first = Dictionary(uniqueKeysWithValues: (0..<6).map { ("a\($0)", "v") })
        let second = Dictionary(uniqueKeysWithValues: (0..<6).map { ("b\($0)", "v") })

        mgr.enqueue(impressionId: "imp", action: "seen", metadata: first)
        await waitUntil { store.persisted.first?.retryCount == 1 }
        mgr.enqueue(impressionId: "imp", action: "seen", metadata: second)

        await waitUntil { store.persisted.first?.metadata?["b0"] == "v" }
        let metadata = store.persisted.first?.metadata
        XCTAssertEqual(metadata?.count, 10)
        XCTAssertTrue(second.keys.allSatisfy { metadata?[$0] == "v" }, "newest keys must survive the cap")
    }

    func testMetadataMergedDuringSuccessfulSendIsDeliveredThenQueueDrains() async {
        let sender = BlockingBeaconSender()
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen", metadata: ["page_name": "Search"])
        await sender.waitForFirstCall()
        mgr.enqueue(impressionId: "imp", action: "seen", metadata: ["surface": "chat"])
        await waitUntil {
            store.persisted.first?.metadata == ["page_name": "Search", "surface": "chat"]
        }

        await sender.releaseFirstCall()
        await waitUntil { store.persisted.isEmpty }

        let metadata = await sender.metadataSnapshots()
        XCTAssertEqual(metadata.count, 2)
        XCTAssertEqual(metadata[0], ["page_name": "Search"])
        XCTAssertEqual(metadata[1], ["page_name": "Search", "surface": "chat"])
    }

    func testMetadataReplacementDuringFailedSendContinuesWithNewestSnapshot() async {
        let sender = BlockingBeaconSender(firstCode: 503)
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen", metadata: ["page_name": "Search"])
        await sender.waitForFirstCall()
        mgr.enqueue(impressionId: "imp", action: "seen", metadata: ["surface": "chat"])
        await sender.releaseFirstCall()
        await waitUntil { store.persisted.isEmpty }

        let metadata = await sender.metadataSnapshots()
        XCTAssertEqual(metadata.count, 2)
        XCTAssertEqual(metadata[1], ["page_name": "Search", "surface": "chat"])
    }

    func testDistinctActionsAreIndependent() async {
        let sender = FakeBeaconSender()
        sender.setCode(200, for: "imp", "seen")
        sender.setCode(200, for: "imp", "click")
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        mgr.enqueue(impressionId: "imp", action: "click")
        await waitUntil {
                sender.callCount("imp", "seen") == 1
                && sender.callCount("imp", "click") == 1
                && store.persisted.isEmpty
        }
        XCTAssertEqual(sender.callCount("imp", "seen"), 1)
        XCTAssertEqual(sender.callCount("imp", "click"), 1)
    }

    func testTriggerDrainsBeaconLeftByPriorSession() async {
        let seeded = [PendingBeacon(impressionId: "imp", action: "seen", retryCount: 0, lastAttemptTimestamp: 0)]
        let sender = FakeBeaconSender()
        sender.setCode(200, for: "imp", "seen")
        let store = ScriptedBeaconStore(initial: seeded)
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.triggerProcessQueue()
        await waitUntil { sender.callCount("imp", "seen") == 1 && store.persisted.isEmpty }
        XCTAssertEqual(sender.callCount("imp", "seen"), 1)
    }

    func testStableIdentityRemovesOnlyTheDeliveredPersistedRecord() async throws {
        let seeded = [
            PendingBeacon(id: "click-1", impressionId: "imp", action: "click"),
            PendingBeacon(id: "click-2", impressionId: "imp", action: "click"),
        ]
        let sender = FakeBeaconSender()
        sender.setCode(200, for: "imp", "click")
        let store = ScriptedBeaconStore(initial: seeded)
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.triggerProcessQueue()
        await waitUntil { sender.callCount("imp", "click") == 2 }

        XCTAssertTrue(store.persisted.isEmpty)
    }

    func testPendingBeaconIdentitySurvivesPersistence() throws {
        let beacon = PendingBeacon(id: "stable-id", impressionId: "imp", action: "seen")

        let decoded = try JSONDecoder().decode(PendingBeacon.self, from: JSONEncoder().encode(beacon))

        XCTAssertEqual(decoded.id, "stable-id")
    }

    func testLegacyPersistedBeaconWithoutMetadataDecodes() throws {
        let legacy = #"[{"impressionId":"imp","action":"seen","retryCount":0,"lastAttemptTimestamp":0}]"#
        defaults.set(Data(legacy.utf8), forKey: queueKey)

        let queue = persistedQueue()
        XCTAssertEqual(queue.count, 1)
        XCTAssertNil(queue.first?.id)
        XCTAssertNil(queue.first?.metadata)
    }

    func testBlankImpressionIdIgnored() async {
        let sender = FakeBeaconSender()
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.enqueue(impressionId: "", action: "seen")
        XCTAssertTrue(store.persisted.isEmpty)
        XCTAssertEqual(sender.totalCalls, 0)
    }

    func testEnqueueReturnsBeforeBlockedPersistenceAndPersistsBeforeSend() async {
        let sender = FakeBeaconSender()
        let store = BlockingBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })
        defer { store.release() }

        let started = ProcessInfo.processInfo.systemUptime
        mgr.enqueue(impressionId: "imp", action: "seen")
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(elapsed, 0.1, "enqueue must not wait for persistence")
        await waitUntil { store.saveStarted }
        XCTAssertEqual(sender.totalCalls, 0, "delivery starts only after the durable write attempt returns")

        store.release()
        await waitUntil { sender.callCount("imp", "seen") == 1 }
    }

    func testQueuePersistsDuringQuietWindowThenSendsAfterGate() async {
        let sender = FakeBeaconSender()
        let gate = ControllableLaunchSettledGate()
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 }, launchGate: gate)

        mgr.enqueue(impressionId: "imp", action: "seen")
        await waitUntil { store.persisted.count == 1 }
        XCTAssertEqual(sender.totalCalls, 0)

        await gate.open()
        await waitUntil { sender.callCount("imp", "seen") == 1 && store.persisted.isEmpty }
    }

    func testInitialSaveFailuresBlockSendAndRetainSubsequentEnqueues() async {
        let sender = FakeBeaconSender()
        let store = ScriptedBeaconStore(saveResults: [false, true])
        let persistenceSleep = ControllablePersistenceSleep()
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { 0 },
            persistenceSleep: { await persistenceSleep.sleep($0) }
        )

        mgr.enqueue(impressionId: "A", action: "seen")
        let initialDelay = await persistenceSleep.waitForRequest()
        XCTAssertEqual(initialDelay, 1)
        XCTAssertEqual(sender.totalCalls, 0)

        mgr.enqueue(impressionId: "B", action: "seen")
        await mgr.waitForExecutorForTests()
        XCTAssertEqual(store.saveCount, 1, "new enqueues must merge behind the one persistence retry")
        XCTAssertEqual(sender.totalCalls, 0)

        persistenceSleep.release()
        await waitUntil { sender.totalCalls == 2 && store.persisted.isEmpty }
        XCTAssertEqual(sender.callCount("A", "seen"), 1)
        XCTAssertEqual(sender.callCount("B", "seen"), 1)
    }

    func testRemovalSaveFailureDoesNotAdvanceOrResend() async {
        let sender = FakeBeaconSender()
        let store = ScriptedBeaconStore(saveResults: [true, false, true])
        let persistenceSleep = ControllablePersistenceSleep()
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { 0 },
            persistenceSleep: { await persistenceSleep.sleep($0) }
        )

        mgr.enqueue(impressionId: "A", action: "seen")
        let removalDelay = await persistenceSleep.waitForRequest()
        XCTAssertEqual(removalDelay, 1)
        XCTAssertEqual(sender.callCount("A", "seen"), 1)
        XCTAssertEqual(store.persisted.map(\.impressionId), ["A"], "failed removal must leave durable state intact")

        mgr.enqueue(impressionId: "A", action: "seen")
        await mgr.waitForExecutorForTests()
        XCTAssertEqual(sender.callCount("A", "seen"), 1)
        XCTAssertEqual(store.saveCount, 2, "duplicate enqueue must wait for the pending removal commit")
        persistenceSleep.release()
        await waitUntil { store.persisted.isEmpty }
        XCTAssertEqual(sender.callCount("A", "seen"), 1)
    }

    func testMalformedStoreBlocksManagerAndIsNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalformedBeaconManager-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("beacons.json")
        let malformed = Data("malformed".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try malformed.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = FakeBeaconSender()
        let loadSleep = ControllablePersistenceSleep()
        let mgr = AdBeaconManager(
            sender: sender,
            store: FileAdBeaconStore(fileURL: fileURL, legacyDefaults: defaults),
            now: { 0 },
            loadSleep: { await loadSleep.sleep($0) }
        )

        mgr.enqueue(impressionId: "new", action: "seen")
        _ = await loadSleep.waitForRequest()

        XCTAssertEqual(sender.totalCalls, 0)
        XCTAssertEqual(try Data(contentsOf: fileURL), malformed)
        await mgr.cancelPendingWorkForTests()
        loadSleep.release()
    }

    func testTransientLoadRecoveryCoalescesPendingAndPersistsBeforeSending() async {
        let sender = FakeBeaconSender()
        let recovered = PendingBeacon(impressionId: "recovered", action: "seen")
        let store = RecoveringBeaconStore(recovered: [recovered])
        let loadSleep = ControllablePersistenceSleep()
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { 0 },
            loadSleep: { await loadSleep.sleep($0) }
        )

        mgr.enqueue(impressionId: "A", action: "seen")
        mgr.enqueue(impressionId: "B", action: "click")
        let delay = await loadSleep.waitForRequest()
        XCTAssertEqual(delay, 1)
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(sender.totalCalls, 0)

        store.allowRecovery()
        loadSleep.release()
        await waitUntil { sender.totalCalls == 3 && store.persisted.isEmpty }

        XCTAssertEqual(store.firstSaved.map(\.impressionId), ["recovered", "A", "B"])
    }

    func testPersistentLoadFailureKeepsOneRetryTaskAndDedupedPendingState() async {
        let sender = FakeBeaconSender()
        let store = RecoveringBeaconStore(recovered: [])
        let loadSleep = ControllablePersistenceSleep()
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { 0 },
            loadSleep: { await loadSleep.sleep($0) }
        )

        for _ in 0..<20 { mgr.enqueue(impressionId: "same", action: "seen") }
        _ = await loadSleep.waitForRequest()
        await waitUntil { store.loadCount == 1 }
        XCTAssertEqual(sender.totalCalls, 0)

        loadSleep.release()
        _ = await loadSleep.waitForRequest()
        await waitUntil { store.loadCount == 2 }
        for _ in 0..<20 { mgr.enqueue(impressionId: "same", action: "seen") }
        await mgr.waitForExecutorForTests()
        XCTAssertEqual(store.loadCount, 2, "events must share the one scheduled load retry")

        store.allowRecovery()
        loadSleep.release()
        await waitUntil { sender.callCount("same", "seen") == 1 && store.persisted.isEmpty }
        XCTAssertEqual(store.firstSaved.map(\.impressionId), ["same"])
    }
}

// MARK: - Test double

private final class FakeBeaconSender: BeaconSending, @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String: Int] = [:]
    private var errors: [String: Error] = [:]
    private var counts: [String: Int] = [:]
    private var metadataByKey: [String: [String: String]] = [:]

    private func key(_ id: String, _ action: String) -> String { "\(id):\(action)" }

    func setCode(_ code: Int, for id: String, _ action: String) { lock.lock(); codes[key(id, action)] = code; lock.unlock() }
    func setError(_ error: Error, for id: String, _ action: String) { lock.lock(); errors[key(id, action)] = error; lock.unlock() }
    func callCount(_ id: String, _ action: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key(id, action)] ?? 0 }
    var totalCalls: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }
    func lastMetadata(_ id: String, _ action: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }; return metadataByKey[key(id, action)]
    }

    func sendImpressionBeacon(
        adId: String,
        action: String,
        apiKey: String,
        metadata: [String: String]?
    ) async throws -> Int {
        lock.lock()
        let k = key(adId, action)
        counts[k, default: 0] += 1
        metadataByKey[k] = metadata
        let error = errors[k]
        let code = codes[k] ?? 200
        lock.unlock()
        if let error { throw error }
        return code
    }
}

private actor BlockingBeaconSender: BeaconSending {
    private var metadata: [[String: String]?] = []
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private let firstCode: Int

    init(firstCode: Int = 200) {
        self.firstCode = firstCode
    }

    func sendImpressionBeacon(
        adId: String,
        action: String,
        apiKey: String,
        metadata: [String: String]?
    ) async throws -> Int {
        self.metadata.append(metadata)
        guard self.metadata.count == 1 else { return 200 }
        firstCallWaiters.forEach { $0.resume() }
        firstCallWaiters.removeAll()
        await withCheckedContinuation { firstCallContinuation = $0 }
        return firstCode
    }

    func waitForFirstCall() async {
        if !metadata.isEmpty { return }
        await withCheckedContinuation { firstCallWaiters.append($0) }
    }

    func releaseFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }

    func metadataSnapshots() -> [[String: String]?] { metadata }
}

private final class BlockingBeaconStore: AdBeaconStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var didRelease = false
    private var _saveStarted = false

    var saveStarted: Bool { lock.lock(); defer { lock.unlock() }; return _saveStarted }
    func load() -> DurableQueueLoad<PendingBeacon> { .missing }
    func save(_ records: [PendingBeacon]) -> Bool {
        lock.lock()
        _saveStarted = true
        let shouldWait = !didRelease
        lock.unlock()
        if shouldWait { gate.wait() }
        return true
    }
    func release() {
        lock.lock()
        let shouldSignal = !didRelease
        didRelease = true
        lock.unlock()
        if shouldSignal { gate.signal() }
    }
}

private final class ScriptedBeaconStore: AdBeaconStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    private var candidates: [[PendingBeacon]] = []
    private var durable: [PendingBeacon] = []

    init(saveResults: [Bool] = [], initial: [PendingBeacon] = []) {
        results = saveResults
        durable = initial
    }
    func load() -> DurableQueueLoad<PendingBeacon> {
        lock.lock(); defer { lock.unlock() }
        return .loaded(durable)
    }
    func save(_ records: [PendingBeacon]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        candidates.append(records)
        let succeeds = results.isEmpty ? true : results.removeFirst()
        if succeeds { durable = records }
        return succeeds
    }
    var saveCount: Int { lock.lock(); defer { lock.unlock() }; return candidates.count }
    var lastCandidate: [PendingBeacon] { lock.lock(); defer { lock.unlock() }; return candidates.last ?? [] }
    var persisted: [PendingBeacon] { lock.lock(); defer { lock.unlock() }; return durable }
}

private final class RecoveringBeaconStore: AdBeaconStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let recovered: [PendingBeacon]
    private var recoveryAllowed = false
    private var loads = 0
    private var saves: [[PendingBeacon]] = []
    private var durable: [PendingBeacon] = []

    init(recovered: [PendingBeacon]) { self.recovered = recovered }
    func load() -> DurableQueueLoad<PendingBeacon> {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        return recoveryAllowed ? .loaded(recovered) : .failed
    }
    func save(_ records: [PendingBeacon]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        saves.append(records)
        durable = records
        return true
    }
    func allowRecovery() { lock.lock(); recoveryAllowed = true; lock.unlock() }
    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return loads }
    var saveCount: Int { lock.lock(); defer { lock.unlock() }; return saves.count }
    var firstSaved: [PendingBeacon] { lock.lock(); defer { lock.unlock() }; return saves.first ?? [] }
    var persisted: [PendingBeacon] { lock.lock(); defer { lock.unlock() }; return durable }
}
