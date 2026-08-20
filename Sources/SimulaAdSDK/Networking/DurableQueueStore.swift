import Foundation

func queuePersistenceBackoff(retryCount: Int) -> TimeInterval {
    guard retryCount > 0 else { return 0 }
    return min(pow(2, Double(retryCount - 1)), 60)
}

/// Small JSON-array store used by billing-sensitive queues. Every production instance is confined
/// to its manager's dedicated serial executor; callers must provide the same confinement. Keeping
/// filesystem operations lock-free avoids holding an `NSLock` across reads, encoding, or writes.
enum DurableQueueLoad<Record> {
    case missing
    case loaded([Record])
    case failed
}

final class DurableJSONQueueStore<Record: Codable>: @unchecked Sendable {
    private let fileURL: URL
    private let legacyDefaults: UserDefaults
    private let legacyKey: String
    /// Once an existing durable source fails to decode/read, refusing writes is the only safe
    /// behavior: overwriting it would silently discard billing work we could not inspect.
    private var refusesWrites = false

    init(
        fileURL: URL,
        legacyDefaults: UserDefaults = .standard,
        legacyKey: String
    ) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
        self.legacyKey = legacyKey
    }

    func load() -> DurableQueueLoad<Record> {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  let records = try? JSONDecoder().decode([Record].self, from: data) else {
                refusesWrites = true
                return .failed
            }
            refusesWrites = false
            return .loaded(records)
        }

        guard let legacyValue = legacyDefaults.object(forKey: legacyKey) else {
            refusesWrites = false
            return .missing
        }
        guard let legacyData = legacyValue as? Data else {
            legacyDefaults.removeObject(forKey: legacyKey)
            refusesWrites = false
            return .missing
        }
        guard let legacy = try? JSONDecoder().decode([Record].self, from: legacyData) else {
            legacyDefaults.removeObject(forKey: legacyKey)
            refusesWrites = false
            return .missing
        }
        guard writeLocked(legacy) else {
            refusesWrites = true
            return .failed
        }
        legacyDefaults.removeObject(forKey: legacyKey)
        refusesWrites = false
        return .loaded(legacy)
    }

    @discardableResult
    func save(_ records: [Record]) -> Bool {
        guard !refusesWrites else { return false }
        let saved = writeLocked(records)
        if saved { legacyDefaults.removeObject(forKey: legacyKey) }
        return saved
    }

    private func writeLocked(_ records: [Record]) -> Bool {
        guard let data = try? JSONEncoder().encode(records) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func applicationSupportURL(fileName: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimulaAdSDK", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

protocol AdBeaconStoring: Sendable {
    func load() -> DurableQueueLoad<PendingBeacon>
    @discardableResult func save(_ records: [PendingBeacon]) -> Bool
}

final class FileAdBeaconStore: AdBeaconStoring, @unchecked Sendable {
    static let legacyKey = "simula_pending_beacons"
    private let store: DurableJSONQueueStore<PendingBeacon>

    init(fileURL: URL, legacyDefaults: UserDefaults = .standard) {
        store = DurableJSONQueueStore(fileURL: fileURL, legacyDefaults: legacyDefaults, legacyKey: Self.legacyKey)
    }

    func load() -> DurableQueueLoad<PendingBeacon> { store.load() }
    func save(_ records: [PendingBeacon]) -> Bool { store.save(records) }
}

protocol RewardVerificationStoring: Sendable {
    func load() -> DurableQueueLoad<PendingVerification>
    @discardableResult func save(_ records: [PendingVerification]) -> Bool
}

final class FileRewardVerificationStore: RewardVerificationStoring, @unchecked Sendable {
    static let legacyKey = "simula_pending_reward_verifications"
    private let store: DurableJSONQueueStore<PendingVerification>

    init(fileURL: URL, legacyDefaults: UserDefaults = .standard) {
        store = DurableJSONQueueStore(fileURL: fileURL, legacyDefaults: legacyDefaults, legacyKey: Self.legacyKey)
    }

    func load() -> DurableQueueLoad<PendingVerification> { store.load() }
    func save(_ records: [PendingVerification]) -> Bool { store.save(records) }
}

/// Compatibility-only test stores. Production managers always use Application Support files.
final class UserDefaultsAdBeaconStore: AdBeaconStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func load() -> DurableQueueLoad<PendingBeacon> {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: FileAdBeaconStore.legacyKey) else { return .missing }
        guard let records = try? JSONDecoder().decode([PendingBeacon].self, from: data) else { return .failed }
        return .loaded(records)
    }
    func save(_ records: [PendingBeacon]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: FileAdBeaconStore.legacyKey)
        return true
    }
}

final class UserDefaultsRewardVerificationStore: RewardVerificationStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func load() -> DurableQueueLoad<PendingVerification> {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: FileRewardVerificationStore.legacyKey) else { return .missing }
        guard let records = try? JSONDecoder().decode([PendingVerification].self, from: data) else { return .failed }
        return .loaded(records)
    }
    func save(_ records: [PendingVerification]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: FileRewardVerificationStore.legacyKey)
        return true
    }
}
