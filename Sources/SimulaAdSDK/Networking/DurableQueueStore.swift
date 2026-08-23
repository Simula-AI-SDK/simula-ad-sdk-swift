import Foundation
#if os(iOS)
import UIKit
#endif

#if os(iOS)
private final class DurableQueueProtectedDataMonitor: @unchecked Sendable {
    static let shared = DurableQueueProtectedDataMonitor()

    private let lock = NSLock()
    private var available: Bool?
    private var started = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        if Thread.isMainThread { startOnMain() }
        else { DispatchQueue.main.async { [weak self] in self?.startOnMain() } }
    }

    var current: Bool? { lock.lock(); defer { lock.unlock() }; return available }

    private func startOnMain() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        updateOnMain()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.setAvailable(true) },
            center.addObserver(
                forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.setAvailable(false) },
        ]
    }

    private func updateOnMain() {
        setAvailable(UIApplication.shared.isProtectedDataAvailable)
    }

    private func setAvailable(_ value: Bool) { lock.lock(); available = value; lock.unlock() }
}
#endif

private func durableQueueProtectedDataAvailable() -> Bool? {
    #if os(iOS)
    return DurableQueueProtectedDataMonitor.shared.current
    #else
    return true
    #endif
}

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
    static var unreadableReadRetryLimit: Int { 10 }
    static var unreadableRecoveryDelay: TimeInterval { 15 * 60 }

    private let fileURL: URL
    private let legacyDefaults: UserDefaults
    private let legacyKey: String
    private let readData: @Sendable (URL) throws -> Data
    private let quarantineIdentifier: @Sendable () -> String
    private let unreadableRetryLimit: Int
    private let unreadableRecoveryDelay: TimeInterval
    private let monotonicNow: @Sendable () -> TimeInterval
    private let protectedDataAvailable: @Sendable () -> Bool?
    private let verificationDataReader: @Sendable (URL) throws -> Data
    private let atomicDataWriter: @Sendable (Data, URL) -> Bool
    private let replaceCurrentItem: @Sendable (URL, URL, String) throws -> Void
    private var unreadableReadFailures = 0
    private var firstUnreadableReadFailure: TimeInterval?
    private var lastEligibleRecoveryObservation: TimeInterval?
    private var protectedDataPauseStarted: TimeInterval?
    private var pendingReplacementQuarantineURL: URL?
    private var currentRecoveryIntegrityFailed = false
    /// Refuse manager saves until a durable source is readable or has been preserved and replaced
    /// with an empty tombstone. This prevents pending in-memory work from overwriting unknown bytes.
    private var refusesWrites = false

    init(
        fileURL: URL,
        legacyDefaults: UserDefaults = .standard,
        legacyKey: String,
        readData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
        quarantineIdentifier: @escaping @Sendable () -> String = { UUID().uuidString },
        unreadableRetryLimit: Int = DurableJSONQueueStore.unreadableReadRetryLimit,
        unreadableRecoveryDelay: TimeInterval = DurableJSONQueueStore.unreadableRecoveryDelay,
        monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        protectedDataAvailable: @escaping @Sendable () -> Bool? = { durableQueueProtectedDataAvailable() },
        verificationDataReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
        atomicDataWriter: @escaping @Sendable (Data, URL) -> Bool = { data, url in
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
        },
        replaceCurrentItem: @escaping @Sendable (URL, URL, String) throws -> Void = { current, replacement, backupName in
            _ = try FileManager.default.replaceItemAt(
                current,
                withItemAt: replacement,
                backupItemName: backupName,
                options: .withoutDeletingBackupItem
            )
        }
    ) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
        self.legacyKey = legacyKey
        self.readData = readData
        self.quarantineIdentifier = quarantineIdentifier
        self.unreadableRetryLimit = max(1, unreadableRetryLimit)
        self.unreadableRecoveryDelay = max(0, unreadableRecoveryDelay)
        self.monotonicNow = monotonicNow
        self.protectedDataAvailable = protectedDataAvailable
        self.verificationDataReader = verificationDataReader
        self.atomicDataWriter = atomicDataWriter
        self.replaceCurrentItem = replaceCurrentItem
    }

    func load() -> DurableQueueLoad<Record> {
        if pendingReplacementQuarantineURL != nil { return verifyPendingReplacement() }
        guard !currentRecoveryIntegrityFailed else { return .failed }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data: Data
            do {
                data = try readData(fileURL)
            } catch {
                return recoverUnreadableCurrentFile()
            }
            resetUnreadableRecoveryWindow()
            guard let records = try? JSONDecoder().decode([Record].self, from: data) else {
                return recoverReadableCorruption(data)
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
        return writeAtomically(data)
    }

    private func writeAtomically(_ data: Data) -> Bool {
        atomicDataWriter(data, fileURL)
    }

    /// A successful read proves the bytes are available but malformed. Preserve those exact bytes
    /// without overwriting an earlier quarantine, then atomically establish the current `[]` tombstone.
    private func recoverReadableCorruption(_ data: Data) -> DurableQueueLoad<Record> {
        refusesWrites = true
        guard let quarantineURL = uniqueQuarantineURL() else { return .failed }
        do {
            try data.write(to: quarantineURL, options: .withoutOverwriting)
        } catch {
            return .failed
        }
        guard writeLocked([]) else { return .failed }
        refusesWrites = false
        return .loaded([])
    }

    /// Protected-data and transient filesystem failures stay fail-closed for a bounded number of
    /// retries and at least the conservative recovery window. Protected-data unavailability does not
    /// advance either bound. Once both are met, atomically replace the unreadable current file with
    /// `[]` while retaining the original as a same-directory backup.
    private func recoverUnreadableCurrentFile() -> DurableQueueLoad<Record> {
        refusesWrites = true
        let currentTime = monotonicNow()
        guard protectedDataAvailable() == true else {
            if firstUnreadableReadFailure != nil, protectedDataPauseStarted == nil {
                // The transition can happen between retry attempts. Starting at the last eligible
                // observation conservatively excludes the whole unobserved interval.
                protectedDataPauseStarted = lastEligibleRecoveryObservation ?? currentTime
            }
            return .failed
        }
        if let pauseStarted = protectedDataPauseStarted,
           let firstFailure = firstUnreadableReadFailure {
            firstUnreadableReadFailure = firstFailure + max(0, currentTime - pauseStarted)
            protectedDataPauseStarted = nil
        }
        if firstUnreadableReadFailure == nil { firstUnreadableReadFailure = currentTime }
        lastEligibleRecoveryObservation = currentTime
        unreadableReadFailures = min(unreadableReadFailures + 1, unreadableRetryLimit)
        let elapsed = max(0, currentTime - (firstUnreadableReadFailure ?? currentTime))
        guard unreadableReadFailures >= unreadableRetryLimit,
              elapsed >= unreadableRecoveryDelay,
              let quarantineURL = uniqueQuarantineURL(),
              let tombstone = try? JSONEncoder().encode([Record]()) else {
            return .failed
        }

        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).tombstone.\(UUID().uuidString)")
        do {
            try tombstone.write(to: temporaryURL, options: .atomic)
            try replaceCurrentItem(fileURL, temporaryURL, quarantineURL.lastPathComponent)
            pendingReplacementQuarantineURL = quarantineURL
            return verifyPendingReplacement()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            if FileManager.default.fileExists(atPath: quarantineURL.path) {
                pendingReplacementQuarantineURL = quarantineURL
                if !FileManager.default.fileExists(atPath: fileURL.path) { _ = writeLocked([]) }
            } else if !FileManager.default.fileExists(atPath: fileURL.path) {
                currentRecoveryIntegrityFailed = true
            }
            return .failed
        }
    }

    /// Retryable post-replacement verification. A transient read failure leaves the preserved
    /// quarantine and current tombstone untouched and retries on the next manager load attempt.
    private func verifyPendingReplacement() -> DurableQueueLoad<Record> {
        refusesWrites = true
        guard protectedDataAvailable() == true else { return .failed }
        guard let quarantineURL = pendingReplacementQuarantineURL else { return .failed }
        guard FileManager.default.fileExists(atPath: quarantineURL.path) else {
            currentRecoveryIntegrityFailed = true
            return .failed
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            // `replaceItemAt` may have preserved the backup before failing to install the replacement.
            // The original is safe, so retry the empty tombstone whenever storage becomes writable.
            guard writeLocked([]) else { return .failed }
        }
        do {
            let current = try verificationDataReader(fileURL)
            guard (try? JSONDecoder().decode([Record].self, from: current))?.isEmpty == true else {
                // The original is safely preserved, so re-establishing the tombstone is safe. Verify
                // on the next attempt to keep transient replacement/read failures fail-closed.
                _ = writeLocked([])
                return .failed
            }
        } catch {
            return .failed
        }
        pendingReplacementQuarantineURL = nil
        currentRecoveryIntegrityFailed = false
        refusesWrites = false
        resetUnreadableRecoveryWindow()
        return .loaded([])
    }

    private func resetUnreadableRecoveryWindow() {
        unreadableReadFailures = 0
        firstUnreadableReadFailure = nil
        lastEligibleRecoveryObservation = nil
        protectedDataPauseStarted = nil
    }

    private func uniqueQuarantineURL() -> URL? {
        let identifier = quarantineIdentifier()
        guard !identifier.isEmpty else { return nil }
        let url = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).quarantine.\(identifier)"
        )
        return FileManager.default.fileExists(atPath: url.path) ? nil : url
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
