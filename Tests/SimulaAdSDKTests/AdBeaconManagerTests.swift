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

    func testSeenMetadataIsPersistedAndForwarded() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 1000 })

        mgr.enqueue(
            impressionId: "imp",
            action: "seen",
            metadata: ["page_name": "Search", "surface": "chat"]
        )

        await waitUntil(timeout: 2) { self.persistedQueue().first?.retryCount == 1 }
        XCTAssertEqual(persistedQueue().first?.metadata, ["page_name": "Search", "surface": "chat"])
        XCTAssertEqual(sender.lastMetadata("imp", "seen"), ["page_name": "Search", "surface": "chat"])
    }

    func testDuplicateSeenMergesMetadataWithoutResettingRetry() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 1000 })

        mgr.enqueue(impressionId: "imp", action: "seen", metadata: ["page_name": "Search"])
        await waitUntil(timeout: 2) { self.persistedQueue().first?.retryCount == 1 }
        mgr.enqueue(impressionId: "imp", action: "seen", metadata: ["surface": "chat"])

        await waitUntil(timeout: 2) { self.persistedQueue().first?.metadata?["surface"] == "chat" }
        let queued = persistedQueue().first
        XCTAssertEqual(queued?.metadata, ["page_name": "Search", "surface": "chat"])
        XCTAssertEqual(queued?.retryCount, 1)
    }

    func testDuplicateSeenMergeRemainsBounded() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 1000 })
        let first = Dictionary(uniqueKeysWithValues: (0..<6).map { ("a\($0)", "v") })
        let second = Dictionary(uniqueKeysWithValues: (0..<6).map { ("b\($0)", "v") })

        mgr.enqueue(impressionId: "imp", action: "seen", metadata: first)
        await waitUntil(timeout: 2) { self.persistedQueue().first?.retryCount == 1 }
        mgr.enqueue(impressionId: "imp", action: "seen", metadata: second)

        await waitUntil(timeout: 2) { self.persistedQueue().first?.metadata?["b0"] == "v" }
        XCTAssertEqual(persistedQueue().first?.metadata?.count, 10)
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

    func testLegacyPersistedBeaconWithoutMetadataDecodes() throws {
        let legacy = #"[{"impressionId":"imp","action":"seen","retryCount":0,"lastAttemptTimestamp":0}]"#
        defaults.set(Data(legacy.utf8), forKey: queueKey)

        let queue = persistedQueue()
        XCTAssertEqual(queue.count, 1)
        XCTAssertNil(queue.first?.metadata)
    }

    func testBlankImpressionIdIgnored() async {
        let sender = FakeBeaconSender()
        let mgr = AdBeaconManager(sender: sender, defaults: defaults, now: { 0 })

        mgr.enqueue(impressionId: "", action: "seen")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(persistedQueue().isEmpty)
        XCTAssertEqual(sender.totalCalls, 0)
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
