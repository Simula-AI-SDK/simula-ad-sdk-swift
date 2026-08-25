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
    let interactionId: String?
    let clickSource: String?
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
        self.init(
            id: id,
            impressionId: impressionId,
            action: action,
            metadata: metadata,
            interactionId: nil,
            clickSource: nil,
            retryCount: retryCount,
            lastAttemptTimestamp: lastAttemptTimestamp
        )
    }

    init(
        id: String? = UUID().uuidString,
        impressionId: String,
        action: String,
        metadata: [String: String]? = nil,
        interactionId: String?,
        clickSource: String?,
        retryCount: Int = 0,
        lastAttemptTimestamp: Double = 0
    ) {
        self.id = id
        self.impressionId = impressionId
        self.action = action
        self.metadata = metadata
        self.interactionId = interactionId
        self.clickSource = clickSource
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
        metadata: [String: String]?,
        interactionId: String?,
        clickSource: String?
    ) async throws -> Int
}

extension BeaconSending {
    func sendImpressionBeacon(
        adId: String,
        action: String,
        apiKey: String,
        metadata: [String: String]?
    ) async throws -> Int {
        try await sendImpressionBeacon(
            adId: adId,
            action: action,
            apiKey: apiKey,
            metadata: metadata,
            interactionId: nil,
            clickSource: nil
        )
    }
}

extension SimulaAPI: BeaconSending {}

// MARK: - AdBeaconManager

/// Thread-safe, persistent queue that delivers impression beacons (`/shown`, `/seen`, `/click`)
/// reliably and off the UI path — the same durable, conflict-free design as `RewardVerificationManager`.
/// The ad fires-and-forgets into this queue; the queue owns delivery.
///
/// - Deduped: shown/seen use `(impressionId, action)`; each click uses its stable interaction id.
///   Retries only happen for sends that did NOT get a terminal response, and click retries carry the
///   same event-id header so the backend can reconcile a lost response idempotently.
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
        let interactionId: String?
    }

    private let sender: BeaconSending
    private let store: AdBeaconStoring
    private let now: @Sendable () -> TimeInterval
    private let launchGate: LaunchSettling
    private let persistenceSleep: @Sendable (TimeInterval) async -> Void
    private let loadSleep: @Sendable (TimeInterval) async -> Void
    private let sleep: @Sendable (TimeInterval) async -> Void
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
    private var retryTask: Task<Void, Never>?
    private var startupTriggerTask: Task<Void, Never>?
    private var pendingRemovalKeys: Set<BeaconKey> = []
    private var durableKeys: Set<BeaconKey> = []
    private var persistenceWaiters: [UUID: (key: BeaconKey, completion: @Sendable () -> Void)] = [:]
    private var pendingNetworkRetryDelay: TimeInterval?
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
        self.sleep = Self.defaultPersistenceSleep
    }

    /// Test seam: inject a fake sender, isolated `UserDefaults`, and a controllable clock.
    init(sender: BeaconSending, defaults: UserDefaults, now: @escaping @Sendable () -> TimeInterval, apiKey: String? = "test") {
        self.sender = sender
        self.store = UserDefaultsAdBeaconStore(defaults)
        self.now = now
        self.launchGate = ImmediateLaunchSettledGate.shared
        self.persistenceSleep = Self.defaultPersistenceSleep
        self.loadSleep = Self.defaultPersistenceSleep
        self.sleep = Self.defaultPersistenceSleep
        self.apiKey = apiKey
    }

    init(
        sender: BeaconSending,
        store: AdBeaconStoring,
        now: @escaping @Sendable () -> TimeInterval,
        apiKey: String? = "test",
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil,
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
        self.sleep = sleep ?? Self.defaultPersistenceSleep
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
        enqueueInternal(
            impressionId: impressionId,
            action: action,
            adFormat: adFormat,
            adUnitId: adUnitId,
            metadata: metadata,
            interactionId: nil,
            clickSource: nil
        )
    }

    public func enqueue(
        impressionId: String,
        action: String,
        adFormat: String? = nil,
        adUnitId: String? = nil,
        metadata: [String: String]? = nil,
        interactionId: String,
        clickSource: String
    ) {
        enqueueInternal(
            impressionId: impressionId,
            action: action,
            adFormat: adFormat,
            adUnitId: adUnitId,
            metadata: metadata,
            interactionId: interactionId,
            clickSource: clickSource
        )
    }

    private func enqueueInternal(
        impressionId: String,
        action: String,
        adFormat: String?,
        adUnitId: String?,
        metadata: [String: String]?,
        interactionId: String?,
        clickSource: String?
    ) {
        guard !impressionId.isEmpty else { return }
        let normalizedMetadata = action == "seen" ? metadata.flatMap { normalizeExtraParameters($0) } : nil
        let resolvedInteractionId = action == "click"
            ? ((interactionId?.isEmpty == false) ? interactionId : UUID().uuidString)
            : nil
        let normalizedClickSource = clickSource.flatMap(ClickSource.init(rawValue:)) ?? .primaryCTA
        let resolvedClickSource = action == "click" ? normalizedClickSource.rawValue : nil
        switch action {
        case "seen":
            Telemetry.shared.recordLifecycle(stage: "impression_fired", adFormat: adFormat, adUnitId: adUnitId, adId: impressionId)
        case "click":
            if let resolvedInteractionId {
                Telemetry.shared.recordLifecycle(
                    stage: "click_fired", adFormat: adFormat, adUnitId: adUnitId, adId: impressionId,
                    serveId: adFormat == "interstitial" ? impressionId : nil,
                    interactionId: resolvedInteractionId, clickSource: normalizedClickSource
                )
            }
        default:
            break
        }
        executor.async { [weak self] in
            self?.enqueueOnExecutor(
                impressionId: impressionId,
                action: action,
                normalizedMetadata: normalizedMetadata,
                interactionId: resolvedInteractionId,
                clickSource: resolvedClickSource
            )
        }
    }

    /// Waits until this click row has reached durable storage. The timeout always releases the
    /// caller, so a broken filesystem cannot swallow the user's external navigation.
    func afterClickPersistence(
        impressionId: String,
        interactionId: String,
        timeout: TimeInterval,
        completion: @escaping @Sendable () -> Void
    ) {
        guard !impressionId.isEmpty, !interactionId.isEmpty else {
            completion()
            return
        }
        let gate = BoundedCompletion(completion)
        let waiterId = UUID()
        let key = BeaconKey(impressionId: impressionId, action: "click", interactionId: interactionId)
        executor.async { [weak self] in
            guard let self else { gate.complete(); return }
            if self.clickPersistenceSatisfied(key) {
                gate.complete()
            } else {
                self.persistenceWaiters[waiterId] = (key, { gate.complete() })
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
            gate.complete()
            self?.executor.async { self?.persistenceWaiters[waiterId] = nil }
        }
    }

    private func enqueueOnExecutor(
        impressionId: String,
        action: String,
        normalizedMetadata: [String: String]?,
        interactionId: String?,
        clickSource: String?
    ) {
        guard loadIfNeeded() else {
            enqueuePending(
                impressionId: impressionId, action: action, metadata: normalizedMetadata,
                interactionId: interactionId, clickSource: clickSource
            )
            return
        }
        let key = BeaconKey(impressionId: impressionId, action: action, interactionId: interactionId)
        guard !pendingRemovalKeys.contains(key) else { return }
        var changed = false
        if let index = queue.firstIndex(where: { beaconKey($0) == key }) {
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
                        interactionId: queue[index].interactionId,
                        clickSource: queue[index].clickSource,
                        retryCount: queue[index].retryCount,
                        lastAttemptTimestamp: queue[index].lastAttemptTimestamp
                    )
                    changed = true
                }
                if shouldWarnForMergedMetadata { warnInvalidExtraParameters() }
            }
        } else {
            queue.append(PendingBeacon(
                impressionId: impressionId, action: action, metadata: normalizedMetadata,
                interactionId: interactionId, clickSource: clickSource
            ))
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
            guard self.startupTriggerTask == nil else { return }
            self.startupTriggerTask = Task { await self.runStartupTrigger() }
        }
    }

    private func runStartupTrigger() async {
        await launchGate.waitUntilSettled()
        guard !Task.isCancelled else { return }
        executor.async { [weak self] in
            guard let self else { return }
            self.startupTriggerTask = nil
            let wasLoaded = self.isLoaded
            guard self.loadIfNeeded() else { return }
            guard wasLoaded else { return }
            if self.isDirty { self.persistIfNeeded() }
            else { self.processOrScheduleRetry() }
        }
    }

    // MARK: - Processing

    @discardableResult
    private func processNextIfPossible() -> Bool {
        guard isLoaded, !isDirty, !isProcessing, let key = apiKey else { return false }
        let nowTs = now()
        guard let task = queue.first(where: {
            nowTs - $0.lastAttemptTimestamp >= rewardVerificationBackoff(retryCount: $0.retryCount)
        }) else { return false }
        isProcessing = true
        Task { await self.send(task: task, apiKey: key) }
        return true
    }

    private func send(task: PendingBeacon, apiKey: String) async {
        let delivered: Bool
        do {
            let code = try await sender.sendImpressionBeacon(
                adId: task.impressionId,
                action: task.action,
                apiKey: apiKey,
                metadata: task.metadata,
                interactionId: task.interactionId,
                clickSource: task.clickSource
            )
            delivered = (200...299).contains(code) || ((400...499).contains(code) && code != 408 && code != 429)
        } catch {
            delivered = false
        }
        executor.async { [weak self] in self?.complete(task: task, delivered: delivered) }
    }

    private func complete(task: PendingBeacon, delivered: Bool) {
        isProcessing = false
        var retryDelay: TimeInterval?
        let index = queue.firstIndex {
            if let id = task.id { return $0.id == id }
            return $0.id == nil && $0.impressionId == task.impressionId && $0.action == task.action
        }
        if let index {
            if delivered {
                pendingRemovalKeys.insert(beaconKey(task))
                queue.remove(at: index)
            } else {
                if queue[index].retryCount < Int.max { queue[index].retryCount += 1 }
                queue[index].lastAttemptTimestamp = now()
                retryDelay = earliestRetryDelay()
            }
            pendingNetworkRetryDelay = retryDelay
            isDirty = true
            persistIfNeeded()
            return
        }
        // A concurrent metadata merge replaces the stable id. Continue immediately with that newer
        // record; a retryable failure on the unchanged record remains backed off.
        if delivered || index == nil { processNextIfPossible() }
    }

    private func earliestRetryDelay() -> TimeInterval? {
        guard !queue.isEmpty else { return nil }
        let nowTs = now()
        let soonest = queue.map {
            rewardVerificationBackoff(retryCount: $0.retryCount) - (nowTs - $0.lastAttemptTimestamp)
        }.min() ?? 0
        return max(soonest, 1)
    }

    private func processOrScheduleRetry() {
        guard !processNextIfPossible(), apiKey != nil else { return }
        let nowTs = now()
        guard let delay = queue.map({
            rewardVerificationBackoff(retryCount: $0.retryCount) - (nowTs - $0.lastAttemptTimestamp)
        }).filter({ $0 > 0 }).min() else {
            return
        }
        scheduleRetry(after: max(delay, 1))
    }

    private func scheduleRetry(after delay: TimeInterval) {
        // Recompute from the whole durable queue after every reconciliation. A newly failed row
        // may become eligible before the existing wake, so keep exactly one task for the latest
        // earliest deadline rather than leaving newer work parked behind an older backoff.
        retryTask?.cancel()
        retryTask = Task { await self.runRetryWake(delay: delay) }
    }

    private func runRetryWake(delay: TimeInterval) async {
        await sleep(delay)
        guard !Task.isCancelled else { return }
        executor.async { [weak self] in self?.processNextIfPossible() }
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
        var migratedClickRecords = false
        switch store.load() {
        case .missing:
            queue = []
        case .loaded(let records):
            // Legacy click rows intentionally remain headerless. Assigning a new event id after an
            // upgrade could double-count a click whose accepted response was lost before persistence.
            queue = records.map { record in
                guard record.action == "click", let interactionId = record.interactionId,
                      !interactionId.isEmpty else { return record }
                let source = record.clickSource.flatMap(ClickSource.init(rawValue:)) ?? .primaryCTA
                let normalized = PendingBeacon(
                    id: record.id, impressionId: record.impressionId, action: record.action,
                    metadata: record.metadata, interactionId: interactionId, clickSource: source.rawValue,
                    retryCount: record.retryCount, lastAttemptTimestamp: record.lastAttemptTimestamp
                )
                if normalized != record { migratedClickRecords = true }
                return normalized
            }
        case .failed:
            loadRetryCount += 1
            Telemetry.shared.recordError(signature: "beacon:load_failed")
            scheduleLoadRetry()
            return false
        }
        isLoaded = true
        durableKeys = Set(queue.map(beaconKey))
        loadRetryCount = 0
        loadRetryTask?.cancel()
        loadRetryTask = nil
        let hadPending = !pendingQueue.isEmpty
        mergePendingQueue()
        if hadPending || migratedClickRecords {
            isDirty = true
            persistIfNeeded()
        } else {
            processOrScheduleRetry()
        }
        return true
    }

    private func persistIfNeeded() {
        guard isDirty, isLoaded, persistenceRetryTask == nil else { return }
        if store.save(queue) {
            isDirty = false
            durableKeys = Set(queue.map(beaconKey))
            persistenceRetryCount = 0
            persistenceRetryTask?.cancel()
            persistenceRetryTask = nil
            durabilityCommitted()
            resolvePersistenceWaiters()
        } else {
            persistenceRetryCount += 1
            Telemetry.shared.recordError(signature: "beacon:persist_failed")
            schedulePersistenceRetry()
        }
    }

    private func durabilityCommitted() {
        pendingRemovalKeys.removeAll()
        if let delay = pendingNetworkRetryDelay {
            pendingNetworkRetryDelay = nil
            scheduleRetry(after: delay)
        } else {
            processOrScheduleRetry()
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

    private func enqueuePending(
        impressionId: String,
        action: String,
        metadata: [String: String]?,
        interactionId: String?,
        clickSource: String?
    ) {
        let key = BeaconKey(impressionId: impressionId, action: action, interactionId: interactionId)
        if let index = pendingQueue.firstIndex(where: { beaconKey($0) == key }) {
            guard let metadata else { return }
            let merged = mergeExtraParameters(existing: pendingQueue[index].metadata, newest: metadata)
            if merged != pendingQueue[index].metadata {
                pendingQueue[index] = PendingBeacon(
                    impressionId: impressionId,
                    action: action,
                    metadata: merged,
                    interactionId: pendingQueue[index].interactionId,
                    clickSource: pendingQueue[index].clickSource,
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
            pendingQueue.append(PendingBeacon(
                impressionId: impressionId, action: action, metadata: metadata,
                interactionId: interactionId, clickSource: clickSource
            ))
        }
    }

    private func mergePendingQueue() {
        for pending in pendingQueue {
            if let index = queue.firstIndex(where: { beaconKey($0) == beaconKey(pending) }) {
                guard let metadata = pending.metadata else { continue }
                let merged = mergeExtraParameters(existing: queue[index].metadata, newest: metadata)
                if merged != queue[index].metadata {
                    queue[index] = PendingBeacon(
                        impressionId: queue[index].impressionId,
                        action: queue[index].action,
                        metadata: merged,
                        interactionId: queue[index].interactionId,
                        clickSource: queue[index].clickSource,
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

    private func beaconKey(_ beacon: PendingBeacon) -> BeaconKey {
        BeaconKey(
            impressionId: beacon.impressionId,
            action: beacon.action,
            interactionId: beacon.action == "click" ? beacon.interactionId : nil
        )
    }

    private func clickPersistenceSatisfied(_ key: BeaconKey) -> Bool {
        if durableKeys.contains(key) { return true }
        guard isLoaded else { return false }
        return !queue.contains { beaconKey($0) == key }
            && !pendingQueue.contains { beaconKey($0) == key }
    }

    private func resolvePersistenceWaiters() {
        let ready = persistenceWaiters.filter { clickPersistenceSatisfied($0.value.key) }
        for (id, waiter) in ready {
            persistenceWaiters[id] = nil
            waiter.completion()
        }
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

    func waitForExecutorForTests() async {
        await withCheckedContinuation { continuation in
            executor.async { continuation.resume() }
        }
    }

    func retryTaskForTests() async -> Task<Void, Never>? {
        await withCheckedContinuation { continuation in
            executor.async { [self] in continuation.resume(returning: retryTask) }
        }
    }

    func cancelPendingWorkForTests() async {
        await withCheckedContinuation { continuation in
            executor.async { [self] in
                persistenceRetryTask?.cancel()
                persistenceRetryTask = nil
                loadRetryTask?.cancel()
                loadRetryTask = nil
                retryTask?.cancel()
                retryTask = nil
                startupTriggerTask?.cancel()
                startupTriggerTask = nil
                continuation.resume()
            }
        }
    }

    private static let defaultPersistenceSleep: @Sendable (TimeInterval) async -> Void = { delay in
        do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) } catch { return }
    }
}
