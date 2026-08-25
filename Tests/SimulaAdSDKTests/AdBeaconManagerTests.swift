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
        await mgr.cancelPendingWorkForTests()
    }

    func testConnectivityFailureKeepsBeacon() async {
        let sender = FakeBeaconSender()
        sender.setError(URLError(.notConnectedToInternet), for: "imp", "seen")
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.enqueue(impressionId: "imp", action: "seen")
        await waitUntil { store.persisted.first?.retryCount == 1 }
        XCTAssertEqual(store.persisted.count, 1)
        await mgr.cancelPendingWorkForTests()
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
        await mgr.cancelPendingWorkForTests()
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
        await mgr.cancelPendingWorkForTests()
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
        await mgr.cancelPendingWorkForTests()
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
        await mgr.cancelPendingWorkForTests()
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

    func testClickInteractionSurvivesDurableRetry() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "click")
        let clock = BeaconTestClock(0)
        let sleeper = BeaconControllableSleep()
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { clock.time },
            sleep: { await sleeper.sleep($0) }
        )

        mgr.enqueue(
            impressionId: "imp",
            action: "click",
            interactionId: "interaction-1",
            clickSource: "store_prompt"
        )
        _ = await sleeper.waitForSleepRequest()
        XCTAssertEqual(store.persisted.first?.interactionId, "interaction-1")
        XCTAssertEqual(store.persisted.first?.clickSource, "store_prompt")

        sender.setCode(200, for: "imp", "click")
        clock.time = 5
        sleeper.release()
        await waitUntil { sender.callCount("imp", "click") == 2 && store.persisted.isEmpty }

        XCTAssertEqual(sender.interactionIds("imp", "click"), ["interaction-1", "interaction-1"])
        XCTAssertEqual(sender.clickSources("imp", "click"), ["store_prompt", "store_prompt"])
    }

    func testClickRequestUsesContractHeadersAndShownDoesNot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BeaconHeaderURLProtocol.self]
        let api = SimulaAPI(session: URLSession(configuration: configuration))

        _ = try await api.sendImpressionBeacon(
            adId: "imp",
            action: "click",
            apiKey: "key",
            interactionId: "event-id",
            clickSource: "primary_cta"
        )
        _ = try await api.sendImpressionBeacon(adId: "imp", action: "shown", apiKey: "key")

        let requests = BeaconHeaderURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Simula-Click-Event-Id"), "event-id")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Simula-Click-Source"), "primary_cta")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "X-Simula-Click-Event-Id"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "X-Simula-Click-Source"))
    }

    func testLegacyPersistedBeaconWithoutMetadataDecodes() throws {
        let legacy = #"[{"impressionId":"imp","action":"seen","retryCount":0,"lastAttemptTimestamp":0}]"#
        defaults.set(Data(legacy.utf8), forKey: queueKey)

        let queue = persistedQueue()
        XCTAssertEqual(queue.count, 1)
        XCTAssertNil(queue.first?.id)
        XCTAssertNil(queue.first?.metadata)
    }

    func testLegacyClickRemainsHeaderlessDuringRecovery() async {
        let sender = FakeBeaconSender()
        let store = ScriptedBeaconStore(initial: [
            PendingBeacon(id: "legacy-row", impressionId: "imp", action: "click")
        ])
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })

        mgr.triggerProcessQueue()
        await waitUntil { sender.callCount("imp", "click") == 1 && store.persisted.isEmpty }

        XCTAssertEqual(sender.interactionIds("imp", "click").count, 1)
        XCTAssertNil(sender.interactionIds("imp", "click")[0])
        XCTAssertEqual(sender.clickSources("imp", "click").count, 1)
        XCTAssertNil(sender.clickSources("imp", "click")[0])
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

        let enqueueReturned = BeaconTestSignal()
        DispatchQueue(label: "beacon-enqueue-probe").async {
            mgr.enqueue(impressionId: "imp", action: "seen")
            enqueueReturned.signal()
        }

        await enqueueReturned.wait()
        await waitUntil { store.saveStarted }
        XCTAssertEqual(sender.totalCalls, 0, "delivery starts only after the durable write attempt returns")

        store.release()
        await waitUntil { sender.callCount("imp", "seen") == 1 }
    }

    func testClickHandoffWaitsForSuccessfulBeaconPersistence() async {
        let sender = FakeBeaconSender()
        let store = BlockingBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })
        let persisted = BeaconTestSignal()

        mgr.enqueue(
            impressionId: "imp",
            action: "click",
            interactionId: "interaction",
            clickSource: "primary_cta"
        )
        await waitUntil { store.saveStarted }
        mgr.afterClickPersistence(
            impressionId: "imp",
            interactionId: "interaction",
            timeout: 1
        ) { persisted.signal() }

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(persisted.isSignaled)
        store.release()
        await persisted.wait()
        XCTAssertTrue(persisted.isSignaled)
    }

    func testClickHandoffTimeoutDoesNotBlockBehindStalledPersistence() async {
        let sender = FakeBeaconSender()
        let store = BlockingBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 })
        let fallback = BeaconTestSignal()
        defer { store.release() }

        mgr.enqueue(
            impressionId: "imp",
            action: "click",
            interactionId: "interaction",
            clickSource: "primary_cta"
        )
        await waitUntil { store.saveStarted }
        mgr.afterClickPersistence(
            impressionId: "imp",
            interactionId: "interaction",
            timeout: 0.02
        ) { fallback.signal() }

        await fallback.wait()
        XCTAssertTrue(fallback.isSignaled)
        XCTAssertEqual(sender.totalCalls, 0)
    }

    func testLiveEnqueuePersistsAndSendsWithoutWaitingForLaunchGate() async {
        let sender = FakeBeaconSender()
        let gate = ControllableLaunchSettledGate()
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 }, launchGate: gate)

        mgr.enqueue(impressionId: "imp", action: "seen")
        await waitUntil { sender.callCount("imp", "seen") == 1 && store.persisted.isEmpty }

        let waitCount = await gate.waitCount
        XCTAssertEqual(waitCount, 0)
    }

    func testStartupTriggerWaitsWithoutClaimingProcessing() async {
        let seeded = [PendingBeacon(impressionId: "startup", action: "seen")]
        let sender = FakeBeaconSender()
        let gate = ControllableLaunchSettledGate()
        let store = ScriptedBeaconStore(initial: seeded)
        let mgr = AdBeaconManager(sender: sender, store: store, now: { 0 }, launchGate: gate)

        mgr.triggerProcessQueue()
        await waitForGateWaiter(gate)
        XCTAssertEqual(sender.totalCalls, 0)

        mgr.enqueue(impressionId: "live", action: "click")
        await waitUntil { sender.totalCalls == 2 && store.persisted.isEmpty }
        XCTAssertEqual(sender.callCount("live", "click"), 1, "startup waiting must not claim processing")
        await gate.open()
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

    func testMalformedStoreIsQuarantinedBeforePendingBeaconPersistsAndSends() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalformedBeaconManager-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("beacons.json")
        let malformed = Data("malformed".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try malformed.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = FakeBeaconSender()
        let store = SignalingBeaconStore(
            wrapping: FileAdBeaconStore(fileURL: fileURL, legacyDefaults: defaults)
        )
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { 0 }
        )

        mgr.enqueue(impressionId: "new", action: "shown")
        await store.waitForTerminalEmptySave()
        await mgr.waitForExecutorForTests()
        await mgr.cancelPendingWorkForTests()
        await mgr.waitForExecutorForTests()

        let quarantine = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("beacons.json.quarantine.") }
        XCTAssertNotNil(quarantine)
        if let quarantine { XCTAssertEqual(try Data(contentsOf: quarantine), malformed) }
        XCTAssertEqual(try JSONDecoder().decode([PendingBeacon].self, from: Data(contentsOf: fileURL)), [])
        XCTAssertEqual(sender.callCount("new", "shown"), 1)
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

    func testRetryWakeReDrainsAfterBackoffWithoutNewEnqueue() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let clock = BeaconTestClock(0)
        let sleeper = BeaconControllableSleep()
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { clock.time },
            sleep: { await sleeper.sleep($0) }
        )

        mgr.enqueue(impressionId: "imp", action: "seen")
        let delay = await sleeper.waitForSleepRequest()
        XCTAssertEqual(delay, 5, accuracy: 0.01)
        XCTAssertEqual(store.persisted.first?.retryCount, 1)

        sender.setCode(200, for: "imp", "seen")
        clock.time = 5
        sleeper.release()

        await waitUntil { sender.callCount("imp", "seen") == 2 && store.persisted.isEmpty }
        XCTAssertEqual(sleeper.count, 1)
    }

    func testRetryWakeWaitsForRetryStatePersistence() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let store = ScriptedBeaconStore(saveResults: [true, false, true])
        let persistenceSleep = ControllablePersistenceSleep()
        let retrySleep = BeaconControllableSleep()
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { 100 },
            sleep: { await retrySleep.sleep($0) },
            persistenceSleep: { await persistenceSleep.sleep($0) }
        )
        defer { retrySleep.release() }

        mgr.enqueue(impressionId: "imp", action: "seen")
        _ = await persistenceSleep.waitForRequest()
        XCTAssertFalse(retrySleep.isSleeping)
        XCTAssertEqual(store.persisted.first?.retryCount, 0)

        persistenceSleep.release()
        let delay = await retrySleep.waitForSleepRequest()
        XCTAssertEqual(delay, 5, accuracy: 0.01)
        XCTAssertEqual(store.persisted.first?.retryCount, 1)
    }

    func testRecoveredBackedOffRowsScheduleOneEarliestWake() async {
        let seeded = [
            PendingBeacon(impressionId: "later", action: "seen", retryCount: 2, lastAttemptTimestamp: 95),
            PendingBeacon(impressionId: "earlier", action: "click", retryCount: 1, lastAttemptTimestamp: 98),
        ]
        let sender = FakeBeaconSender()
        let clock = BeaconTestClock(100)
        let sleeper = BeaconControllableSleep()
        let store = ScriptedBeaconStore(initial: seeded)
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { clock.time },
            sleep: { await sleeper.sleep($0) }
        )
        defer { sleeper.release() }

        mgr.triggerProcessQueue()
        let delay = await sleeper.waitForSleepRequest()

        XCTAssertEqual(delay, 3, accuracy: 0.01)
        XCTAssertEqual(sleeper.count, 1)
        XCTAssertEqual(sender.totalCalls, 0)
    }

    func testRetryWakeDoesNotRescheduleWhenStillBackedOff() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "imp", "seen")
        let clock = BeaconTestClock(0)
        let sleeper = BeaconControllableSleep()
        let store = ScriptedBeaconStore()
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { clock.time },
            sleep: { await sleeper.sleep($0) }
        )

        mgr.enqueue(impressionId: "imp", action: "seen")
        _ = await sleeper.waitForSleepRequest()

        sleeper.release()
        await waitUntil { !sleeper.isSleeping }
        await mgr.waitForExecutorForTests()

        XCTAssertEqual(sender.callCount("imp", "seen"), 1)
        XCTAssertEqual(store.persisted.count, 1)
        XCTAssertEqual(sleeper.count, 1, "an early wake must not start a retry loop")
    }

    func testCompletedStaleWakeDoesNotClearNewerRetryTask() async {
        let sender = FakeBeaconSender()
        sender.setCode(503, for: "A", "seen")
        sender.setCode(503, for: "B", "seen")
        let clock = BeaconTestClock(0)
        let sleeper = BeaconControllableSleep()
        let store = BlockingNthSaveBeaconStore(blockingSave: 4)
        let mgr = AdBeaconManager(
            sender: sender,
            store: store,
            now: { clock.time },
            sleep: { await sleeper.sleep($0) }
        )
        defer {
            store.release()
            sleeper.release()
        }

        mgr.enqueue(impressionId: "A", action: "seen")
        _ = await sleeper.waitForSleepRequest()
        guard let staleWake = await mgr.retryTaskForTests() else {
            XCTFail("expected first retry wake")
            return
        }

        mgr.enqueue(impressionId: "B", action: "seen")
        await waitUntil { store.isBlocked }
        guard store.isBlocked else {
            XCTFail("expected B retry persistence to block")
            sleeper.release()
            return
        }

        // Finish A's wake while B's failure owns the executor. Its drain is now queued behind
        // the executor turn that replaces A with B's newer retry task.
        sleeper.release()
        await staleWake.value
        store.release()
        _ = await sleeper.waitForSleepRequest()
        await mgr.waitForExecutorForTests()

        let ownedRetryTask = await mgr.retryTaskForTests()
        XCTAssertNotNil(ownedRetryTask, "the stale wake must not discard B's task handle")

        await mgr.cancelPendingWorkForTests()
        sleeper.release()
    }

    private func waitForGateWaiter(_ gate: ControllableLaunchSettledGate) async {
        await waitUntil { await gate.waitCount > 0 }
    }
}

// MARK: - Test double

private final class FakeBeaconSender: BeaconSending, @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String: Int] = [:]
    private var errors: [String: Error] = [:]
    private var counts: [String: Int] = [:]
    private var metadataByKey: [String: [String: String]] = [:]
    private var interactionIdsByKey: [String: [String?]] = [:]
    private var clickSourcesByKey: [String: [String?]] = [:]

    private func key(_ id: String, _ action: String) -> String { "\(id):\(action)" }

    func setCode(_ code: Int, for id: String, _ action: String) { lock.lock(); codes[key(id, action)] = code; lock.unlock() }
    func setError(_ error: Error, for id: String, _ action: String) { lock.lock(); errors[key(id, action)] = error; lock.unlock() }
    func callCount(_ id: String, _ action: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key(id, action)] ?? 0 }
    var totalCalls: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }
    func lastMetadata(_ id: String, _ action: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }; return metadataByKey[key(id, action)]
    }
    func interactionIds(_ id: String, _ action: String) -> [String?] {
        lock.lock(); defer { lock.unlock() }; return interactionIdsByKey[key(id, action)] ?? []
    }
    func clickSources(_ id: String, _ action: String) -> [String?] {
        lock.lock(); defer { lock.unlock() }; return clickSourcesByKey[key(id, action)] ?? []
    }

    func sendImpressionBeacon(
        adId: String,
        action: String,
        apiKey: String,
        metadata: [String: String]?,
        interactionId: String?,
        clickSource: String?
    ) async throws -> Int {
        lock.lock()
        let k = key(adId, action)
        counts[k, default: 0] += 1
        metadataByKey[k] = metadata
        interactionIdsByKey[k, default: []].append(interactionId)
        clickSourcesByKey[k, default: []].append(clickSource)
        let error = errors[k]
        let code = codes[k] ?? 200
        lock.unlock()
        if let error { throw error }
        return code
    }
}

private final class SignalingBeaconStore: AdBeaconStoring, @unchecked Sendable {
    private let wrapped: AdBeaconStoring
    private let lock = NSLock()
    private var terminalEmptySaved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(wrapping wrapped: AdBeaconStoring) { self.wrapped = wrapped }

    func load() -> DurableQueueLoad<PendingBeacon> { wrapped.load() }

    func save(_ records: [PendingBeacon]) -> Bool {
        let saved = wrapped.save(records)
        guard saved, records.isEmpty else { return saved }
        lock.lock()
        terminalEmptySaved = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
        return true
    }

    func waitForTerminalEmptySave() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if terminalEmptySaved {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class BeaconTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool { lock.lock(); defer { lock.unlock() }; return signaled }

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

private actor BlockingBeaconSender: BeaconSending {
    private var metadata: [[String: String]?] = []
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private let firstCode: Int

    init(firstCode: Int = 200) {
        self.firstCode = firstCode
    }

    func sendImpressionBeacon(
        adId: String,
        action: String,
        apiKey: String,
        metadata: [String: String]?,
        interactionId: String?,
        clickSource: String?
    ) async throws -> Int {
        self.metadata.append(metadata)
        guard self.metadata.count == 1 else { return 200 }
        firstCallWaiters.forEach { $0.resume() }
        firstCallWaiters.removeAll()
        await withCheckedContinuation { continuation in
            if releaseRequested {
                releaseRequested = false
                continuation.resume()
            } else {
                firstCallContinuation = continuation
            }
        }
        return firstCode
    }

    func waitForFirstCall() async {
        if !metadata.isEmpty { return }
        await withCheckedContinuation { firstCallWaiters.append($0) }
    }

    func releaseFirstCall() {
        guard let continuation = firstCallContinuation else {
            releaseRequested = true
            return
        }
        firstCallContinuation = nil
        continuation.resume()
    }

    func metadataSnapshots() -> [[String: String]?] { metadata }
}

private final class BeaconHeaderURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.captured.append(request); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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

private final class BlockingNthSaveBeaconStore: AdBeaconStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockingSave: Int
    private var saves = 0
    private var blocked = false
    private var didRelease = false
    private var durable: [PendingBeacon] = []

    init(blockingSave: Int) { self.blockingSave = blockingSave }

    func load() -> DurableQueueLoad<PendingBeacon> {
        lock.lock(); defer { lock.unlock() }
        return .loaded(durable)
    }

    func save(_ records: [PendingBeacon]) -> Bool {
        lock.lock()
        saves += 1
        let shouldBlock = saves == blockingSave && !didRelease
        if shouldBlock { blocked = true }
        lock.unlock()

        if shouldBlock { gate.wait() }

        lock.lock()
        durable = records
        lock.unlock()
        return true
    }

    var isBlocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return blocked && !didRelease
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

private final class BeaconTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    init(_ value: TimeInterval) { self.value = value }
    var time: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class BeaconControllableSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingDelay: TimeInterval?
    private var delayWaiter: CheckedContinuation<TimeInterval, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var sleeping = false
    private var sleepCount = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return sleepCount }
    var isSleeping: Bool { lock.lock(); defer { lock.unlock() }; return sleeping }

    func sleep(_ delay: TimeInterval) async {
        lock.lock()
        sleepCount += 1
        sleeping = true
        pendingDelay = delay
        let waiter = delayWaiter
        delayWaiter = nil
        lock.unlock()
        waiter?.resume(returning: delay)

        await withCheckedContinuation { continuation in
            lock.lock()
            if releaseRequested {
                releaseRequested = false
                lock.unlock()
                continuation.resume()
                return
            }
            releaseContinuation = continuation
            lock.unlock()
        }

        lock.lock()
        sleeping = false
        pendingDelay = nil
        lock.unlock()
    }

    func waitForSleepRequest() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pendingDelay {
                lock.unlock()
                continuation.resume(returning: pendingDelay)
                return
            }
            delayWaiter = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let continuation = releaseContinuation
        releaseContinuation = nil
        if continuation == nil { releaseRequested = true }
        lock.unlock()
        continuation?.resume()
    }
}
