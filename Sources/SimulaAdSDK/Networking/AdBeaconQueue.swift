import Foundation

// MARK: - PendingBeacon

/// A billing/measurement beacon waiting to be delivered. Today's `track*` helpers are fire-and-forget:
/// a beacon that fails (offline, 5xx) is lost. This makes them durable — persisted so a beacon that
/// couldn't land before the app was backgrounded/killed is retried (PRD → durable billing queue).
/// `action` is the impression-action path segment: `shown` / `seen` / `click`.
struct PendingBeacon: Codable, Equatable {
    /// Stable identity for reconciliation. Optional so queues persisted before this field existed
    /// still decode; all newly enqueued records receive an id.
    let id: String?
    let impressionId: String
    let action: String
    let metadata: [String: String]?
    var retryCount: Int = 0
    var lastAttemptTimestamp: Double = 0

    init(
        id: String? = UUID().uuidString,
        impressionId: String,
        action: String,
        metadata: [String: String]? = nil,
        retryCount: Int = 0,
        lastAttemptTimestamp: Double = 0
    ) {
        self.id = id
        self.impressionId = impressionId
        self.action = action
        self.metadata = metadata
        self.retryCount = retryCount
        self.lastAttemptTimestamp = lastAttemptTimestamp
    }
}

// MARK: - Seam

/// Sends one impression-action beacon, returning the HTTP status (or throwing on connectivity).
/// `SimulaAPI` is the production implementation; tests substitute a fake.
protocol BeaconSending: Sendable {
    func sendImpressionBeacon(
        adId: String,
        action: String,
        apiKey: String,
        metadata: [String: String]?
    ) async throws -> Int
}

extension SimulaAPI: BeaconSending {}

// MARK: - AdBeaconManager

/// Thread-safe, persistent queue that delivers impression beacons (`/shown`, `/seen`, `/click`)
/// reliably and off the UI path — the same durable, conflict-free design as `RewardVerificationManager`.
/// The ad fires-and-forgets into this queue; the queue owns delivery.
///
/// - Deduped: at most one in-flight entry per `(impressionId, action)`. Retries only happen for sends
///   that did NOT get a 2xx, so a beacon the server already accepted isn't re-sent. (`/seen` is deduped
///   server-side per impression; `/click` increments a counter, so a lost-response retry carries a small
///   over-count risk — acceptable vs. today's silent loss, removable once the endpoint takes an
///   idempotency key.)
/// - Durable: atomically persisted under Application Support; survives relaunch and migrates the
///   exact legacy `simula_pending_beacons` UserDefaults entry once.
/// - Backed off: failed attempts retry with the shared exponential backoff (5s → 60s cap).
///
/// `@unchecked Sendable` is safe: mutable state and persistence are confined to `executor`, and
/// `URLSession` inside `SimulaAPI` is itself thread-safe.
public final class AdBeaconManager: @unchecked Sendable {
    public static let shared = AdBeaconManager()

    private struct BeaconKey: Hashable {
        let impressionId: String
        let action: String
    }

    private let sender: BeaconSending
    private let store: AdBeaconStoring
    private let now: @Sendable () -> TimeInterval
    private let launchGate: LaunchSettling
    private let persistenceSleep: @Sendable (TimeInterval) async -> Void
    private let loadSleep: @Sendable (TimeInterval) async -> Void
    private let executor = DispatchQueue(label: "ad.simula.beacon.queue", qos: .utility)
    private var queue: [PendingBeacon] = []
    private var pendingQueue: [PendingBeacon] = []
    private var isLoaded = false
    private var isDirty = false
    private var isProcessing = false
    private var apiKey: String?
    private var persistenceRetryCount = 0
    private var persistenceRetryTask: Task<Void, Never>?
    private var loadRetryCount = 0
    private var loadRetryTask: Task<Void, Never>?
    private var pendingRemovalKeys: Set<BeaconKey> = []
    private var pauseAfterPersistence = false
    private let maxPendingEnqueues = 100

    private init() {
        self.sender = SimulaAPI()
        let fallback = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/SimulaAdSDK", isDirectory: true)
            .appendingPathComponent("pending_beacons.json")
        let url = DurableJSONQueueStore<PendingBeacon>.applicationSupportURL(fileName: "pending_beacons.json") ?? fallback
        self.store = FileAdBeaconStore(fileURL: url)
        self.now = { Date().timeIntervalSince1970 }
        self.launchGate = LaunchSettledGate.shared
        self.persistenceSleep = Self.defaultPersistenceSleep
        self.loadSleep = Self.defaultPersistenceSleep
    }

    /// Test seam: inject a fake sender, isolated `UserDefaults`, and a controllable clock.
    init(sender: BeaconSending, defaults: UserDefaults, now: @escaping @Sendable () -> TimeInterval, apiKey: String? = "test") {
        self.sender = sender
        self.store = UserDefaultsAdBeaconStore(defaults)
        self.now = now
        self.launchGate = ImmediateLaunchSettledGate.shared
        self.persistenceSleep = Self.defaultPersistenceSleep
        self.loadSleep = Self.defaultPersistenceSleep
        self.apiKey = apiKey
    }

    init(
        sender: BeaconSending,
        store: AdBeaconStoring,
        now: @escaping @Sendable () -> TimeInterval,
        apiKey: String? = "test",
        launchGate: LaunchSettling = ImmediateLaunchSettledGate.shared,
        persistenceSleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        loadSleep: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        self.sender = sender
        self.store = store
        self.now = now
        self.apiKey = apiKey
        self.launchGate = launchGate
        self.persistenceSleep = persistenceSleep ?? Self.defaultPersistenceSleep
        self.loadSleep = loadSleep ?? Self.defaultPersistenceSleep
    }

    /// Provide the api key (the beacon endpoints are Bearer-authed). Call once at SDK init; first wins.
    public func configure(apiKey: String) {
        executor.async { [weak self] in
            guard let self else { return }
            if self.apiKey == nil { self.apiKey = apiKey }
            self.processNextIfPossible()
        }
    }

    /// Durably enqueue an impression-action beacon (`shown` / `seen` / `click`) and emit a diagnostic
    /// lifecycle event for the billing-relevant ones. A no-op for a blank id. Kept OFF the telemetry
    /// pipeline; the diagnostic events are interim visibility into beacon firing, separate from the
    /// durable beacon itself.
    public func enqueue(
        impressionId: String,
        action: String,
        adFormat: String? = nil,
        adUnitId: String? = nil,
        metadata: [String: String]? = nil
    ) {
        guard !impressionId.isEmpty else { return }
        let normalizedMetadata = action == "seen" ? metadata.flatMap { normalizeExtraParameters($0) } : nil
        switch action {
        case "seen":
            Telemetry.shared.recordLifecycle(stage: "impression_fired", adFormat: adFormat, adUnitId: adUnitId, adId: impressionId)
        case "click":
            Telemetry.shared.recordLifecycle(stage: "click_fired", adFormat: adFormat, adUnitId: adUnitId, adId: impressionId)
        default:
            break
        }
        executor.async { [weak self] in
            self?.enqueueOnExecutor(
                impressionId: impressionId,
                action: action,
                normalizedMetadata: normalizedMetadata
            )
        }
    }

    private func enqueueOnExecutor(
        impressionId: String,
        action: String,
        normalizedMetadata: [String: String]?
    ) {
        guard loadIfNeeded() else {
            enqueuePending(impressionId: impressionId, action: action, metadata: normalizedMetadata)
            return
        }
        let key = BeaconKey(impressionId: impressionId, action: action)
        guard !pendingRemovalKeys.contains(key) else { return }
        // An explicit enqueue is a fresh drain trigger once the latest full candidate is durable.
        pauseAfterPersistence = false
        var changed = false
        if let index = queue.firstIndex(where: { $0.impressionId == impressionId && $0.action == action }) {
            if let normalizedMetadata {
                var shouldWarnForMergedMetadata = false
                let merged = mergeExtraParameters(
                    existing: queue[index].metadata,
                    newest: normalizedMetadata,
                    warn: { shouldWarnForMergedMetadata = true }
                )
                if merged != queue[index].metadata {
                    queue[index] = PendingBeacon(
                        impressionId: queue[index].impressionId,
                        action: queue[index].action,
                        metadata: merged,
                        retryCount: queue[index].retryCount,
                        lastAttemptTimestamp: queue[index].lastAttemptTimestamp
                    )
                    changed = true
                }
                if shouldWarnForMergedMetadata { warnInvalidExtraParameters() }
            }
        } else {
            queue.append(PendingBeacon(impressionId: impressionId, action: action, metadata: normalizedMetadata))
            changed = true
        }
        if changed {
            isDirty = true
            persistIfNeeded()
        } else if !isDirty {
            processNextIfPossible()
        }
    }

    /// Drains any persisted beacons eligible under their backoff. Call at launch to recover work.
    public func triggerProcessQueue() {
        executor.async { [weak self] in
            guard let self else { return }
            guard self.loadIfNeeded() else { return }
            self.pauseAfterPersistence = false
            if self.isDirty { self.persistIfNeeded() }
            else { self.processNextIfPossible() }
        }
    }

    // MARK: - Processing

    private func processNextIfPossible() {
        guard isLoaded, !isDirty, !isProcessing, let key = apiKey else { return }
        let nowTs = now()
        guard let task = queue.first(where: {
            nowTs - $0.lastAttemptTimestamp >= rewardVerificationBackoff(retryCount: $0.retryCount)
        }) else { return }
        isProcessing = true
        Task { await self.send(task: task, apiKey: key) }
    }

    private func send(task: PendingBeacon, apiKey: String) async {
        await launchGate.waitUntilSettled()
        let delivered: Bool
        do {
            let code = try await sender.sendImpressionBeacon(
                adId: task.impressionId,
                action: task.action,
                apiKey: apiKey,
                metadata: task.metadata
            )
            delivered = (200...299).contains(code) || ((400...499).contains(code) && code != 408 && code != 429)
        } catch {
            delivered = false
        }
        executor.async { [weak self] in self?.complete(task: task, delivered: delivered) }
    }

    private func complete(task: PendingBeacon, delivered: Bool) {
        isProcessing = false
        let index = queue.firstIndex {
            if let id = task.id { return $0.id == id }
            return $0.id == nil && $0.impressionId == task.impressionId && $0.action == task.action
        }
        if let index {
            if delivered {
                pendingRemovalKeys.insert(BeaconKey(impressionId: task.impressionId, action: task.action))
                queue.remove(at: index)
                pauseAfterPersistence = false
            } else {
                if queue[index].retryCount < Int.max { queue[index].retryCount += 1 }
                queue[index].lastAttemptTimestamp = now()
                // Preserve the existing bail-on-transient-failure behavior. A later enqueue,
                // startup trigger, or explicit trigger can re-enter the drain after backoff.
                pauseAfterPersistence = true
            }
            isDirty = true
            persistIfNeeded()
            return
        }
        // A concurrent metadata merge replaces the stable id. Continue immediately with that newer
        // record; a retryable failure on the unchanged record remains backed off.
        if delivered || index == nil { processNextIfPossible() }
    }

    // MARK: - Persistence

    @discardableResult
    private func loadIfNeeded() -> Bool {
        if isLoaded { return true }
        if loadRetryTask != nil { return false }
        return attemptLoad()
    }

    @discardableResult
    private func attemptLoad() -> Bool {
        switch store.load() {
        case .missing:
            queue = []
        case .loaded(let records):
            queue = records
        case .failed:
            loadRetryCount += 1
            Telemetry.shared.recordError(signature: "beacon:load_failed")
            scheduleLoadRetry()
            return false
        }
        isLoaded = true
        loadRetryCount = 0
        loadRetryTask?.cancel()
        loadRetryTask = nil
        let hadPending = !pendingQueue.isEmpty
        mergePendingQueue()
        if hadPending {
            isDirty = true
            pauseAfterPersistence = false
            persistIfNeeded()
        } else {
            processNextIfPossible()
        }
        return true
    }

    private func persistIfNeeded() {
        guard isDirty, isLoaded, persistenceRetryTask == nil else { return }
        if store.save(queue) {
            isDirty = false
            pendingRemovalKeys.removeAll()
            persistenceRetryCount = 0
            persistenceRetryTask?.cancel()
            persistenceRetryTask = nil
            if pauseAfterPersistence {
                pauseAfterPersistence = false
            } else {
                processNextIfPossible()
            }
        } else {
            persistenceRetryCount += 1
            Telemetry.shared.recordError(signature: "beacon:persist_failed")
            schedulePersistenceRetry()
        }
    }

    private func schedulePersistenceRetry() {
        guard persistenceRetryTask == nil else { return }
        let delay = queuePersistenceBackoff(retryCount: persistenceRetryCount)
        persistenceRetryTask = Task { await self.runPersistenceRetry(after: delay) }
    }

    private func runPersistenceRetry(after delay: TimeInterval) async {
        await persistenceSleep(delay)
        guard !Task.isCancelled else { return }
        executor.async { [weak self] in
            guard let self else { return }
            self.persistenceRetryTask = nil
            self.persistIfNeeded()
        }
    }

    private func enqueuePending(impressionId: String, action: String, metadata: [String: String]?) {
        if let index = pendingQueue.firstIndex(where: {
            $0.impressionId == impressionId && $0.action == action
        }) {
            guard let metadata else { return }
            let merged = mergeExtraParameters(existing: pendingQueue[index].metadata, newest: metadata)
            if merged != pendingQueue[index].metadata {
                pendingQueue[index] = PendingBeacon(
                    impressionId: impressionId,
                    action: action,
                    metadata: merged,
                    retryCount: pendingQueue[index].retryCount,
                    lastAttemptTimestamp: pendingQueue[index].lastAttemptTimestamp
                )
            }
        } else {
            guard pendingQueue.count < maxPendingEnqueues else {
                Telemetry.shared.recordError(
                    signature: "durable_queue:pending_full",
                    breadcrumb: "queue=beacon"
                )
                return
            }
            pendingQueue.append(PendingBeacon(impressionId: impressionId, action: action, metadata: metadata))
        }
    }

    private func mergePendingQueue() {
        for pending in pendingQueue {
            if let index = queue.firstIndex(where: {
                $0.impressionId == pending.impressionId && $0.action == pending.action
            }) {
                guard let metadata = pending.metadata else { continue }
                let merged = mergeExtraParameters(existing: queue[index].metadata, newest: metadata)
                if merged != queue[index].metadata {
                    queue[index] = PendingBeacon(
                        impressionId: queue[index].impressionId,
                        action: queue[index].action,
                        metadata: merged,
                        retryCount: queue[index].retryCount,
                        lastAttemptTimestamp: queue[index].lastAttemptTimestamp
                    )
                }
            } else {
                queue.append(pending)
            }
        }
        pendingQueue.removeAll()
    }

    private func scheduleLoadRetry() {
        guard loadRetryTask == nil else { return }
        let delay = queuePersistenceBackoff(retryCount: loadRetryCount)
        loadRetryTask = Task { await self.runLoadRetry(after: delay) }
    }

    private func runLoadRetry(after delay: TimeInterval) async {
        await loadSleep(delay)
        guard !Task.isCancelled else { return }
        executor.async { [weak self] in
            guard let self else { return }
            self.loadRetryTask = nil
            _ = self.attemptLoad()
        }
    }

    private static let defaultPersistenceSleep: @Sendable (TimeInterval) async -> Void = { delay in
        do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) } catch { return }
    }
}
