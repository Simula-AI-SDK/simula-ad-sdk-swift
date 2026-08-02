import XCTest
@testable import SimulaAdSDK

/// Tier-1 tests for the durable impression/click beacon queue: delivery / permanent-drop / retain /
/// dedup / recovery, exercised with a fake sender, an isolated `UserDefaults`, and a controllable
/// clock — no network, no wall-clock timing.
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

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func test2xxDeliversAndRemoves() async {
        let sender = FakeBeaconSender()
        sender.setCode(200, for: "imp", "seen")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        await waitUntil(timeout: 2) { self.persistedQueue().isEmpty }
        XCTAssertEqual(sender.callCount("imp", "seen"), 1)
    }

    func testPermanent4xxDropsWithoutRetry() async {
        let sender = FakeBeaconSender()
        sender.setCode(400, for: "imp", "click")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "click")
        await waitUntil(timeout: 2) { self.persistedQueue().isEmpty }
        XCTAssertEqual(sender.callCount("imp", "click"), 1)
    }

    func test5xxKeepsAndRecordsAttempt() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 1000 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        await waitUntil(timeout: 2) { self.persistedQueue().first?.retryCount == 1 }
        let q = persistedQueue()
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.first?.lastAttemptTimestamp, 1000)
        XCTAssertEqual(sender.callCount("imp", "seen"), 1)
    }

    func testConnectivityFailureKeepsBeacon() async {
        let sender = FakeBeaconSender()
        sender.setError(URLError(.notConnectedToInternet), for: "imp", "seen")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        await waitUntil(timeout: 2) { self.persistedQueue().count == 1 }
        XCTAssertEqual(persistedQueue().count, 1)
    }

    func testDuplicateBeaconEnqueuedOnce() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen") // keep it queued
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        mgr.enqueue(impressionId: "imp", action: "seen") // duplicate
        await waitUntil(timeout: 2) { self.persistedQueue().first?.retryCount ?? 0 >= 1 }
        XCTAssertEqual(persistedQueue().count, 1)
    }

    func testDistinctActionsAreIndependent() async {
        let sender = FakeBeaconSender()
        sender.setCode(200, for: "imp", "seen")
        sender.setCode(200, for: "imp", "click")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        mgr.enqueue(impressionId: "imp", action: "click")
        await waitUntil(timeout: 2) { self.persistedQueue().isEmpty }
        XCTAssertEqual(sender.callCount("imp", "seen"), 1)
        XCTAssertEqual(sender.callCount("imp", "click"), 1)
    }

    func testTriggerDrainsBeaconLeftByPriorSession() async {
        let seeded = [PendingBeacon(impressionId: "imp", action: "seen", retryCount: 0, lastAttemptTimestamp: 0)]
        defaults.set(try! JSONEncoder().encode(seeded), forKey: queueKey)

        let sender = FakeBeaconSender()
        sender.setCode(200, for: "imp", "seen")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 0 })

        mgr.triggerProcessQueue()
        await waitUntil(timeout: 2) { self.persistedQueue().isEmpty }
        XCTAssertEqual(sender.callCount("imp", "seen"), 1)
    }

    func testBlankImpressionIdIgnored() async {
        let sender = FakeBeaconSender()
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 0 })

        mgr.enqueue(impressionId: "", action: "seen")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(persistedQueue().isEmpty)
        XCTAssertEqual(sender.totalCalls, 0)
    }

    // MARK: - iOS-4: cap / TTL / batched persistence

    func testQueueIsCappedAndDropsOldestOnOverflow() async {
        let sender = FakeBeaconSender()
        // 503 for everything so entries stay queued and accumulate to the cap.
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 0 })
        for i in 0..<maxPendingBeacons { sender.setCode(503, for: "imp_\(i)", "seen") }
        for i in 0..<maxPendingBeacons { mgr.enqueue(impressionId: "imp_\(i)", action: "seen") }
        await waitUntil(timeout: 2) { self.persistedQueue().count == maxPendingBeacons }

        sender.setCode(503, for: "newest", "seen")
        mgr.enqueue(impressionId: "newest", action: "seen")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let queue = persistedQueue()
        XCTAssertEqual(queue.count, maxPendingBeacons, "cap holds")
        XCTAssertTrue(queue.contains { $0.impressionId == "newest" }, "the newest is never dropped")
        XCTAssertFalse(queue.contains { $0.impressionId == "imp_0" }, "the oldest was dropped")
    }

    func testExpiredBeaconsArePrunedAtLoad() async {
        // Seed at now = 10_000_000: one entry past the 24h TTL (expired) + one 100s old (fresh).
        let nowTs: TimeInterval = 10_000_000
        let stale = PendingBeacon(impressionId: "stale", action: "seen", createdAt: nowTs - durableQueueMaxAgeSeconds - 1)
        let fresh = PendingBeacon(impressionId: "fresh", action: "seen", createdAt: nowTs - 100)
        defaults.set(try! JSONEncoder().encode([stale, fresh]), forKey: queueKey)

        let sender = FakeBeaconSender()
        sender.setCode(503, for: "fresh", "seen") // keep the fresh one queued
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { nowTs })
        mgr.triggerProcessQueue()
        await waitUntil(timeout: 2) { self.persistedQueue().count == 1 }

        XCTAssertEqual(persistedQueue().first?.impressionId, "fresh", "the expired row is pruned at load, never retried")
        XCTAssertEqual(sender.callCount("stale", "seen"), 0)
    }

    func testLegacyRowsWithoutCreatedAtAreStampedAndKept() async {
        // A pre-TTL blob has no createdAt key — it must decode (optional field), be stamped
        // with a TTL baseline, and survive the load instead of being dropped.
        let legacyJson = #"[{"impressionId":"old","action":"seen","retryCount":0,"lastAttemptTimestamp":0}]"#.data(using: .utf8)!
        defaults.set(legacyJson, forKey: queueKey)

        let sender = FakeBeaconSender()
        sender.setCode(503, for: "old", "seen")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 42 })
        mgr.triggerProcessQueue()
        await waitUntil(timeout: 2) { !self.persistedQueue().isEmpty && self.persistedQueue()[0].createdAt != nil }

        XCTAssertEqual(persistedQueue()[0].createdAt, 42, "never-attempted legacy rows get 'now' as the TTL baseline")
    }

    func testADrainPassPersistsOnceNotPerDeliveredBeacon() async {
        let counting = CountingDefaults(suiteName: "beacon-count-\(UUID().uuidString)")!
        defer { counting.removePersistentDomain(forName: counting.suiteNameForTests) }
        // Seed 5 beacons WITH createdAt (so the load isn't dirty and doesn't write).
        let nowTs: TimeInterval = 1_000
        let seeded = (0..<5).map { PendingBeacon(impressionId: "imp_\($0)", action: "seen", createdAt: nowTs) }
        counting.set(try! JSONEncoder().encode(seeded), forKey: queueKey)
        let baseline = counting.setCount

        let sender = FakeBeaconSender() // default 200 → everything delivers
        let mgr = AdBeaconManager(sender: sender, defaults: counting, now: { nowTs })
        mgr.triggerProcessQueue()
        await waitUntil(timeout: 2) { counting.setCount > baseline }

        XCTAssertEqual(counting.setCount - baseline, 1, "one batched write for a 5-beacon drain pass (was one per removal)")
        XCTAssertEqual(sender.totalCalls, 5)
    }

    func testPersistNowSyncFlushesInMemoryOnlyQueue() {
        // The app-background durability hook: with the async utility write swallowed (as if
        // the process were killed before it landed), an enqueued beacon exists only in
        // memory — persistNowSync (the didEnterBackground path) must still make it durable.
        let sender = FakeBeaconSender()
        let deferred = DeferredPersistenceSubmissions()
        let persistence = OrderedPersistenceExecutor(
            label: "beacon-persist-deferred", deferAsyncSubmission: { deferred.hold($0) }
        )
        let mgr = AdBeaconManager(
            sender: sender,
            defaults: defaults,
            now: { 0 },
            apiKey: nil, // pre-config: the drain bails immediately, leaving the row pending
            persistence: persistence
        )
        mgr.enqueue(impressionId: "imp", action: "seen")
        XCTAssertTrue(persistedQueue().isEmpty, "async persist never ran — in-memory only")
        mgr.persistNowSync()
        XCTAssertEqual(persistedQueue().map(\.impressionId), ["imp"])
    }

    func testOlderAsyncSnapshotCannotLoseANewerBeaconAfterBackgroundPersist() {
        let deferred = DeferredPersistenceSubmissions()
        let persistence = OrderedPersistenceExecutor(
            label: "beacon-persist-loss", deferAsyncSubmission: { deferred.hold($0) }
        )
        let mgr = AdBeaconManager(
            sender: FakeBeaconSender(), defaults: defaults, now: { 0 }, apiKey: nil,
            persistence: persistence
        )

        mgr.enqueue(impressionId: "old", action: "seen") // revision 1, held
        mgr.persistNowSync() // revision 2 writes [old]
        mgr.enqueue(impressionId: "new", action: "seen") // revision 3, held

        deferred.runNewestFirst() // force revision 3 to land before stale revision 1
        persistence.waitForPendingWrites()

        XCTAssertEqual(Set(persistedQueue().map(\.impressionId)), ["old", "new"])
    }

    func testOlderAsyncSnapshotCannotResurrectDeliveredBeaconAfterBackgroundPersist() async {
        let deferred = DeferredPersistenceSubmissions()
        let persistence = OrderedPersistenceExecutor(
            label: "beacon-persist-resurrection", deferAsyncSubmission: { deferred.hold($0) }
        )
        let sender = FakeBeaconSender() // 200: enqueue snapshot becomes stale after delivery
        let mgr = AdBeaconManager(
            sender: sender, defaults: defaults, now: { 0 }, persistence: persistence
        )

        mgr.enqueue(impressionId: "delivered", action: "seen")
        await waitUntil(timeout: 2) { deferred.count >= 2 } // enqueue + empty drain snapshot
        mgr.persistNowSync() // newest empty snapshot lands synchronously

        deferred.runOldestFirst()
        persistence.waitForPendingWrites()

        XCTAssertTrue(persistedQueue().isEmpty, "held stale snapshots must not resurrect delivered work")
    }
}

// MARK: - Test double

/// Counts `set(_:forKey:)` calls so the batched-persist shape is observable without a seam change.
private final class CountingDefaults: UserDefaults {
    private let lock = NSLock()
    private(set) var setCount = 0
    let suiteNameForTests: String

    override init?(suiteName: String?) {
        suiteNameForTests = suiteName ?? "counting-defaults"
        super.init(suiteName: suiteName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); setCount += 1; lock.unlock()
        super.set(value, forKey: defaultName)
    }
}

private final class DeferredPersistenceSubmissions: @unchecked Sendable {
    private let lock = NSLock()
    private var submissions: [@Sendable () -> Void] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return submissions.count
    }

    func hold(_ submission: @escaping @Sendable () -> Void) {
        lock.lock(); submissions.append(submission); lock.unlock()
    }

    func runOldestFirst() { run(reversed: false) }
    func runNewestFirst() { run(reversed: true) }

    private func run(reversed: Bool) {
        lock.lock()
        let pending = reversed ? Array(submissions.reversed()) : submissions
        submissions.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }
}

private final class FakeBeaconSender: BeaconSending, @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String: Int] = [:]
    private var errors: [String: Error] = [:]
    private var counts: [String: Int] = [:]

    private func key(_ id: String, _ action: String) -> String { "\(id):\(action)" }

    func setCode(_ code: Int, for id: String, _ action: String) { lock.lock(); codes[key(id, action)] = code; lock.unlock() }
    func setError(_ error: Error, for id: String, _ action: String) { lock.lock(); errors[key(id, action)] = error; lock.unlock() }
    func callCount(_ id: String, _ action: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key(id, action)] ?? 0 }
    var totalCalls: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }

    func sendImpressionBeacon(adId: String, action: String, apiKey: String) async throws -> Int {
        lock.lock()
        let k = key(adId, action)
        counts[k, default: 0] += 1
        let error = errors[k]
        let code = codes[k] ?? 200
        lock.unlock()
        if let error { throw error }
        return code
    }
}
