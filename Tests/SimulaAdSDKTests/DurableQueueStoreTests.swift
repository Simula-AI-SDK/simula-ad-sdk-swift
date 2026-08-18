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
        let defaults = UserDefaults(suiteName: name) ?? .standard
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

    func testMalformedCurrentFileFailsClosedAndRefusesOverwrite() throws {
        let fileURL = temporaryFile("malformed-beacons.json")
        let malformed = Data("not-json".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try malformed.write(to: fileURL)
        let store = FileAdBeaconStore(fileURL: fileURL, legacyDefaults: isolatedDefaults())

        guard case .failed = store.load() else {
            return XCTFail("malformed durable state must be reported as a failed read")
        }
        XCTAssertFalse(store.save([PendingBeacon(impressionId: "new", action: "seen")]))
        XCTAssertEqual(try Data(contentsOf: fileURL), malformed)
    }

    func testSuccessfulFutureLoadClearsWriteRefusal() throws {
        let fileURL = temporaryFile("recovered-beacons.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)
        let store = FileAdBeaconStore(fileURL: fileURL, legacyDefaults: isolatedDefaults())
        guard case .failed = store.load() else { return XCTFail("first load must fail") }

        let recovered = [PendingBeacon(impressionId: "recovered", action: "seen")]
        try JSONEncoder().encode(recovered).write(to: fileURL, options: .atomic)
        XCTAssertEqual(beacons(from: store.load()), recovered)

        let replacement = [PendingBeacon(impressionId: "replacement", action: "click")]
        XCTAssertTrue(store.save(replacement))
        XCTAssertEqual(beacons(from: store.load()), replacement)
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

        XCTAssertEqual(beacons(from: store.load()), expected)
        XCTAssertNotNil(defaults.data(forKey: "simula_pending_beacons"))
        XCTAssertFalse(store.save(expected))
        XCTAssertNotNil(defaults.data(forKey: "simula_pending_beacons"))
    }

    func testPersistenceBackoffIsBounded() {
        XCTAssertEqual(queuePersistenceBackoff(retryCount: 1), 1)
        XCTAssertEqual(queuePersistenceBackoff(retryCount: 7), 60)
        XCTAssertEqual(queuePersistenceBackoff(retryCount: 100), 60)
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
