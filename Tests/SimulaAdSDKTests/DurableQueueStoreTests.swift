import XCTest
@testable import SimulaAdSDK

final class DurableQueueStoreTests: XCTestCase {
    private func temporaryFile(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulaQueueTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(name)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "SimulaQueueMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testBeaconStoreMigratesExactLegacyKeyOnce() throws {
        let defaults = isolatedDefaults()
        let expected = [PendingBeacon(id: "b1", impressionId: "imp", action: "seen")]
        defaults.set(try JSONEncoder().encode(expected), forKey: "simula_pending_beacons")
        let fileURL = temporaryFile("beacons.json")
        let store = FileAdBeaconStore(fileURL: fileURL, legacyDefaults: defaults)

        XCTAssertEqual(beacons(from: store.load()), expected)
        XCTAssertNil(defaults.data(forKey: "simula_pending_beacons"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        defaults.set(
            try JSONEncoder().encode([PendingBeacon(impressionId: "new", action: "click")]),
            forKey: "simula_pending_beacons"
        )
        XCTAssertEqual(beacons(from: store.load()), expected, "the durable file wins after the one-time migration")
    }

    func testRewardStoreMigratesExactLegacyKeyAndPreservesOrder() throws {
        let defaults = isolatedDefaults()
        let expected = [
            PendingVerification(serveId: "A", sessionId: "s", elapsedPlayTime: 1, retryCount: 0, lastAttemptTimestamp: 0),
            PendingVerification(serveId: "B", sessionId: "s", elapsedPlayTime: 2, retryCount: 0, lastAttemptTimestamp: 0),
        ]
        defaults.set(try JSONEncoder().encode(expected), forKey: "simula_pending_reward_verifications")
        let fileURL = temporaryFile("rewards.json")
        let store = FileRewardVerificationStore(fileURL: fileURL, legacyDefaults: defaults)

        XCTAssertEqual(verifications(from: store.load()).map(\.serveId), ["A", "B"])
        XCTAssertNil(defaults.data(forKey: "simula_pending_reward_verifications"))

        XCTAssertTrue(store.save(expected + [
            PendingVerification(serveId: "C", sessionId: "s", elapsedPlayTime: 3, retryCount: 0, lastAttemptTimestamp: 0),
        ]))
        XCTAssertEqual(verifications(from: store.load()).map(\.serveId), ["A", "B", "C"])
    }

    func testMalformedBeaconLegacyDataIsClearedAndDoesNotLatchWrites() {
        let defaults = isolatedDefaults()
        let key = "simula_pending_beacons"
        defaults.set(Data("not-json".utf8), forKey: key)
        defaults.set(Data("keep".utf8), forKey: "unrelated")
        let store = FileAdBeaconStore(
            fileURL: temporaryFile("beacon-legacy-corruption.json"),
            legacyDefaults: defaults
        )

        guard case .missing = store.load() else { return XCTFail("obsolete malformed legacy data is missing") }
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertNotNil(defaults.object(forKey: "unrelated"))

        let replacement = [PendingBeacon(impressionId: "new", action: "seen")]
        XCTAssertTrue(store.save(replacement))
        XCTAssertEqual(beacons(from: store.load()), replacement)
    }

    func testMalformedRewardLegacyDataIsClearedAndDoesNotLatchWrites() {
        let defaults = isolatedDefaults()
        let key = "simula_pending_reward_verifications"
        defaults.set(Data("not-json".utf8), forKey: key)
        defaults.set(Data("keep".utf8), forKey: "unrelated")
        let store = FileRewardVerificationStore(
            fileURL: temporaryFile("reward-legacy-corruption.json"),
            legacyDefaults: defaults
        )

        guard case .missing = store.load() else { return XCTFail("obsolete malformed legacy data is missing") }
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertNotNil(defaults.object(forKey: "unrelated"))

        let replacement = [
            PendingVerification(
                serveId: "new", sessionId: "s", elapsedPlayTime: 1,
                retryCount: 0, lastAttemptTimestamp: 0
            ),
        ]
        XCTAssertTrue(store.save(replacement))
        XCTAssertEqual(verifications(from: store.load()), replacement)
    }

    func testMigrationPreservesQueuesBeyondFormerRecordAndByteCaps() throws {
        let defaults = isolatedDefaults()
        let payload = String(repeating: "x", count: 1_100)
        let expected = (0...1_000).map {
            PendingVerification(
                serveId: "serve-\($0)", sessionId: payload, elapsedPlayTime: Double($0),
                retryCount: 0, lastAttemptTimestamp: 0
            )
        }
        defaults.set(try JSONEncoder().encode(expected), forKey: "simula_pending_reward_verifications")
        let store = FileRewardVerificationStore(
            fileURL: temporaryFile("uncapped-rewards.json"),
            legacyDefaults: defaults
        )

        XCTAssertEqual(verifications(from: store.load()), expected)
        XCTAssertNil(defaults.data(forKey: "simula_pending_reward_verifications"))
    }

    func testReadableMalformedCurrentFileIsQuarantinedExactlyAndReplacedByEmptyTombstone() throws {
        let fileURL = temporaryFile("malformed-beacons.json")
        let malformed = Data("not-json".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try malformed.write(to: fileURL)
        let store = DurableJSONQueueStore<PendingBeacon>(
            fileURL: fileURL,
            legacyDefaults: isolatedDefaults(),
            legacyKey: "legacy",
            quarantineIdentifier: { "readable" }
        )

        guard case .loaded(let records) = store.load() else {
            return XCTFail("readable corruption must recover to an empty queue")
        }
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: fileURL.deletingLastPathComponent().appendingPathComponent("malformed-beacons.json.quarantine.readable")),
            malformed
        )
        XCTAssertEqual(try JSONDecoder().decode([PendingBeacon].self, from: Data(contentsOf: fileURL)), [])

        // Malformed records are intentionally not partially salvaged or delivered. Exact quarantine
        // preservation permits offline inspection while new durable work resumes from the tombstone.
        let replacement = [PendingBeacon(impressionId: "new", action: "seen")]
        XCTAssertTrue(store.save(replacement))
        XCTAssertEqual(beacons(from: store.load()), replacement)
    }

    func testTransientUnreadableCurrentFileRetriesAndSuccessfulFutureLoadClearsWriteRefusal() throws {
        let fileURL = temporaryFile("recovered-beacons.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recovered = [PendingBeacon(impressionId: "recovered", action: "seen")]
        try JSONEncoder().encode(recovered).write(to: fileURL)
        let fault = ReadFault(failuresRemaining: 1)
        let store = DurableJSONQueueStore<PendingBeacon>(
            fileURL: fileURL,
            legacyDefaults: isolatedDefaults(),
            legacyKey: "legacy",
            readData: { try fault.read($0) }
        )
        guard case .failed = store.load() else { return XCTFail("first load must fail") }
        XCTAssertFalse(store.save([PendingBeacon(impressionId: "blocked", action: "seen")]))

        XCTAssertEqual(beacons(from: store.load()), recovered)

        let replacement = [PendingBeacon(impressionId: "replacement", action: "click")]
        XCTAssertTrue(store.save(replacement))
        XCTAssertEqual(beacons(from: store.load()), replacement)
    }

    func testUnreadableCurrentFileQuarantinesOnlyAtRetryCapAndPreservesOriginalBytes() throws {
        let fileURL = temporaryFile("unreadable-rewards.json")
        let original = Data("billing-bytes-that-cannot-be-read-yet".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: fileURL)
        let clock = QueueStoreClock(0)
        let store = DurableJSONQueueStore<PendingVerification>(
            fileURL: fileURL,
            legacyDefaults: isolatedDefaults(),
            legacyKey: "legacy",
            readData: { _ in throw CocoaError(.fileReadNoPermission) },
            quarantineIdentifier: { "unreadable" },
            unreadableRetryLimit: 3,
            unreadableRecoveryDelay: 100,
            monotonicNow: { clock.value },
            protectedDataAvailable: { true }
        )

        guard case .failed = store.load() else { return XCTFail("first read must fail closed") }
        clock.value = 50
        guard case .failed = store.load() else { return XCTFail("retry count alone cannot quarantine") }
        clock.value = 99
        guard case .failed = store.load() else { return XCTFail("recovery window must fully elapse") }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertFalse(store.save([]))

        clock.value = 100
        guard case .loaded(let records) = store.load() else {
            return XCTFail("elapsed recovery window must recover after atomic preservation")
        }
        XCTAssertTrue(records.isEmpty)
        let quarantine = fileURL.deletingLastPathComponent()
            .appendingPathComponent("unreadable-rewards.json.quarantine.unreadable")
        XCTAssertEqual(try Data(contentsOf: quarantine), original)
        XCTAssertEqual(try JSONDecoder().decode([PendingVerification].self, from: Data(contentsOf: fileURL)), [])
    }

    func testProtectedDataUnavailabilityDoesNotAdvanceUnreadableRecoveryWindow() throws {
        let fileURL = temporaryFile("protected-rewards.json")
        let original = Data("protected-billing-bytes".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: fileURL)
        let clock = QueueStoreClock(0)
        let availability = ProtectedDataFlag(false)
        let store = DurableJSONQueueStore<PendingVerification>(
            fileURL: fileURL,
            legacyDefaults: isolatedDefaults(),
            legacyKey: "legacy",
            readData: { _ in throw CocoaError(.fileReadNoPermission) },
            quarantineIdentifier: { "protected" },
            unreadableRetryLimit: 1,
            unreadableRecoveryDelay: 100,
            monotonicNow: { clock.value },
            protectedDataAvailable: { availability.value }
        )

        guard case .failed = store.load() else { return XCTFail("protected data must fail closed") }
        clock.value = 1_000
        guard case .failed = store.load() else { return XCTFail("unavailable time must not count") }
        availability.value = true
        guard case .failed = store.load() else { return XCTFail("window starts at first eligible read") }
        clock.value = 1_099
        guard case .failed = store.load() else { return XCTFail("eligible window has not elapsed") }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)

        clock.value = 1_100
        guard case .loaded(let records) = store.load() else { return XCTFail("eligible window elapsed") }
        XCTAssertTrue(records.isEmpty)
    }

    func testProtectedDataInterruptionPausesAnActiveRecoveryWindow() throws {
        let fileURL = temporaryFile("paused-protected-rewards.json")
        let original = Data("paused-protected-billing-bytes".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: fileURL)
        let clock = QueueStoreClock(0)
        let availability = ProtectedDataFlag(true)
        let store = DurableJSONQueueStore<PendingVerification>(
            fileURL: fileURL,
            legacyDefaults: isolatedDefaults(),
            legacyKey: "legacy",
            readData: { _ in throw CocoaError(.fileReadNoPermission) },
            quarantineIdentifier: { "paused" },
            unreadableRetryLimit: 2,
            unreadableRecoveryDelay: 100,
            monotonicNow: { clock.value },
            protectedDataAvailable: { availability.value }
        )

        guard case .failed = store.load() else { return XCTFail("window starts with an eligible failure") }
        clock.value = 20
        guard case .failed = store.load() else { return XCTFail("retry count met but time remains") }
        availability.value = false
        guard case .failed = store.load() else { return XCTFail("protected interval starts") }
        clock.value = 1_020
        guard case .failed = store.load() else { return XCTFail("protected interval remains paused") }

        availability.value = true
        guard case .failed = store.load() else { return XCTFail("resume must not quarantine immediately") }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        clock.value = 1_099
        guard case .failed = store.load() else { return XCTFail("only eligible elapsed time counts") }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)

        clock.value = 1_100
        guard case .loaded(let records) = store.load() else { return XCTFail("remaining eligible window elapsed") }
        XCTAssertTrue(records.isEmpty)
    }

    func testTransientPostReplacementVerificationFailureRetriesWithoutWedging() throws {
        let fileURL = temporaryFile("verification-retry-rewards.json")
        let original = Data("unreadable-billing-bytes".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: fileURL)
        let verificationFault = ReadFault(failuresRemaining: 1)
        let store = DurableJSONQueueStore<PendingVerification>(
            fileURL: fileURL,
            legacyDefaults: isolatedDefaults(),
            legacyKey: "legacy",
            readData: { _ in throw CocoaError(.fileReadNoPermission) },
            quarantineIdentifier: { "verification" },
            unreadableRetryLimit: 1,
            unreadableRecoveryDelay: 0,
            protectedDataAvailable: { true },
            verificationDataReader: { try verificationFault.read($0) }
        )

        guard case .failed = store.load() else { return XCTFail("first verification is transiently unreadable") }
        guard case .loaded(let records) = store.load() else { return XCTFail("verification must retry") }
        XCTAssertTrue(records.isEmpty)
        let quarantine = fileURL.deletingLastPathComponent()
            .appendingPathComponent("verification-retry-rewards.json.quarantine.verification")
        XCTAssertEqual(try Data(contentsOf: quarantine), original)
        XCTAssertTrue(store.save([
            PendingVerification(
                serveId: "future", sessionId: "s", elapsedPlayTime: 1,
                retryCount: 0, lastAttemptTimestamp: 0
            ),
        ]))
    }

    func testMissingCurrentAfterPreservedReplacementRetriesTombstoneCreation() throws {
        let fileURL = temporaryFile("missing-tombstone-rewards.json")
        let original = Data("preserved-before-missing-tombstone".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: fileURL)
        let writer = ScriptedAtomicWriter(results: [false, true])
        let store = DurableJSONQueueStore<PendingVerification>(
            fileURL: fileURL,
            legacyDefaults: isolatedDefaults(),
            legacyKey: "legacy",
            readData: { _ in throw CocoaError(.fileReadNoPermission) },
            quarantineIdentifier: { "preserved" },
            unreadableRetryLimit: 1,
            unreadableRecoveryDelay: 0,
            protectedDataAvailable: { true },
            atomicDataWriter: { writer.write($0, to: $1) },
            replaceCurrentItem: { current, replacement, backupName in
                let quarantine = current.deletingLastPathComponent().appendingPathComponent(backupName)
                try FileManager.default.moveItem(at: current, to: quarantine)
                try? FileManager.default.removeItem(at: replacement)
                throw CocoaError(.fileWriteUnknown)
            }
        )

        guard case .failed = store.load() else {
            return XCTFail("initial tombstone recreation failure must remain fail-closed")
        }
        let quarantine = fileURL.deletingLastPathComponent()
            .appendingPathComponent("missing-tombstone-rewards.json.quarantine.preserved")
        XCTAssertEqual(try Data(contentsOf: quarantine), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(store.save([]))

        guard case .loaded(let records) = store.load() else {
            return XCTFail("later load must recreate and verify the missing tombstone")
        }
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: quarantine), original)
        XCTAssertEqual(try JSONDecoder().decode([PendingVerification].self, from: Data(contentsOf: fileURL)), [])
    }

    func testUnreadableQuarantineNeverOverwritesExistingBillingBytes() throws {
        let fileURL = temporaryFile("collision-rewards.json")
        let original = Data("current-billing-bytes".utf8)
        let quarantine = fileURL.deletingLastPathComponent()
            .appendingPathComponent("collision-rewards.json.quarantine.fixed")
        let priorQuarantine = Data("older-billing-bytes".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: fileURL)
        try priorQuarantine.write(to: quarantine)
        let store = DurableJSONQueueStore<PendingVerification>(
            fileURL: fileURL,
            legacyDefaults: isolatedDefaults(),
            legacyKey: "legacy",
            readData: { _ in throw CocoaError(.fileReadNoPermission) },
            quarantineIdentifier: { "fixed" },
            unreadableRetryLimit: 1,
            unreadableRecoveryDelay: 0,
            protectedDataAvailable: { true }
        )

        guard case .failed = store.load() else { return XCTFail("collision must remain fail-closed") }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(try Data(contentsOf: quarantine), priorQuarantine)
        XCTAssertFalse(store.save([]))
    }

    func testUnreadablePreservationFailureRemainsFailClosed() throws {
        let fileURL = temporaryFile("lost-before-preserve-rewards.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("billing".utf8).write(to: fileURL)
        let readFault = DisappearingReadFault()
        let store = DurableJSONQueueStore<PendingVerification>(
            fileURL: fileURL,
            legacyDefaults: isolatedDefaults(),
            legacyKey: "legacy",
            readData: { try readFault.read($0) },
            quarantineIdentifier: { "missing" },
            unreadableRetryLimit: 1,
            unreadableRecoveryDelay: 0,
            protectedDataAvailable: { true }
        )

        guard case .failed = store.load() else { return XCTFail("failed preservation must fail closed") }
        XCTAssertFalse(store.save([]))
        try JSONEncoder().encode([PendingVerification]()).write(to: fileURL)
        guard case .failed = store.load() else { return XCTFail("unpreserved bytes cannot be trusted later") }
        XCTAssertFalse(store.save([]))
    }

    func testFailedMigrationPreservesCompleteLegacyQueueAndKey() throws {
        let defaults = isolatedDefaults()
        let expected = [
            PendingBeacon(impressionId: "A", action: "seen"),
            PendingBeacon(impressionId: "B", action: "click"),
        ]
        defaults.set(try JSONEncoder().encode(expected), forKey: "simula_pending_beacons")
        // A regular file cannot be used as a parent directory, so every atomic write fails.
        let store = FileAdBeaconStore(
            fileURL: URL(fileURLWithPath: "/dev/null/pending_beacons.json"),
            legacyDefaults: defaults
        )

        guard case .failed = store.load() else {
            return XCTFail("a failed migration must block queue delivery")
        }
        XCTAssertNotNil(defaults.data(forKey: "simula_pending_beacons"))
        XCTAssertFalse(store.save(expected))
        XCTAssertNotNil(defaults.data(forKey: "simula_pending_beacons"))
    }

    func testFailedMigrationRetriesTheWholeMigrationBeforeLoading() throws {
        let defaults = isolatedDefaults()
        let expected = [PendingBeacon(impressionId: "A", action: "seen")]
        defaults.set(try JSONEncoder().encode(expected), forKey: "simula_pending_beacons")
        let blockedParent = temporaryFile("blocked-parent")
        try FileManager.default.createDirectory(
            at: blockedParent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-a-directory".utf8).write(to: blockedParent)
        let fileURL = blockedParent.appendingPathComponent("pending_beacons.json")
        let store = FileAdBeaconStore(fileURL: fileURL, legacyDefaults: defaults)

        guard case .failed = store.load() else { return XCTFail("blocked migration must fail closed") }
        try FileManager.default.removeItem(at: blockedParent)

        XCTAssertEqual(beacons(from: store.load()), expected)
        XCTAssertNil(defaults.data(forKey: "simula_pending_beacons"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEmptyQueueFilePreventsStaleLegacyQueueResurrection() throws {
        let defaults = isolatedDefaults()
        let current = [PendingBeacon(impressionId: "current", action: "seen")]
        let stale = [PendingBeacon(impressionId: "stale", action: "click")]
        let fileURL = temporaryFile("empty-tombstone.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(current).write(to: fileURL)
        defaults.set(try JSONEncoder().encode(stale), forKey: "simula_pending_beacons")
        let store = FileAdBeaconStore(fileURL: fileURL, legacyDefaults: defaults)

        XCTAssertTrue(store.save([]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        // Model termination before stale migration cleanup: the current empty file must still win.
        defaults.set(try JSONEncoder().encode(stale), forKey: "simula_pending_beacons")

        let relaunched = FileAdBeaconStore(fileURL: fileURL, legacyDefaults: defaults)
        XCTAssertEqual(beacons(from: relaunched.load()), [])
    }

    func testPersistenceBackoffIsBounded() {
        XCTAssertEqual(queuePersistenceBackoff(retryCount: 1), 1)
        XCTAssertEqual(queuePersistenceBackoff(retryCount: 7), 60)
        XCTAssertEqual(queuePersistenceBackoff(retryCount: 100), 60)
    }

    func testUnreadableRecoveryDefaultsAreConservativeAndBounded() {
        XCTAssertGreaterThanOrEqual(DurableJSONQueueStore<PendingBeacon>.unreadableReadRetryLimit, 10)
        XCTAssertGreaterThanOrEqual(DurableJSONQueueStore<PendingBeacon>.unreadableRecoveryDelay, 15 * 60)
    }


    private func beacons(from result: DurableQueueLoad<PendingBeacon>) -> [PendingBeacon] {
        if case .loaded(let records) = result { return records }
        return []
    }

    private func verifications(from result: DurableQueueLoad<PendingVerification>) -> [PendingVerification] {
        if case .loaded(let records) = result { return records }
        return []
    }
}

private final class ReadFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: Int

    init(failuresRemaining: Int) { self.failuresRemaining = failuresRemaining }

    func read(_ url: URL) throws -> Data {
        lock.lock()
        let shouldFail = failuresRemaining > 0
        if shouldFail { failuresRemaining -= 1 }
        lock.unlock()
        if shouldFail { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
}

private final class DisappearingReadFault: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func read(_ url: URL) throws -> Data {
        lock.lock()
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail {
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileReadNoPermission)
        }
        return try Data(contentsOf: url)
    }
}

private final class QueueStoreClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ value: TimeInterval) { time = value }
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return time }
        set { lock.lock(); time = newValue; lock.unlock() }
    }
}

private final class ProtectedDataFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Bool
    init(_ value: Bool) { available = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return available }
        set { lock.lock(); available = newValue; lock.unlock() }
    }
}

private final class ScriptedAtomicWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]

    init(results: [Bool]) { self.results = results }

    func write(_ data: Data, to url: URL) -> Bool {
        lock.lock()
        let result = results.isEmpty ? true : results.removeFirst()
        lock.unlock()
        guard result else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
