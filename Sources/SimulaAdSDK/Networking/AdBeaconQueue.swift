import Foundation

// MARK: - PendingBeacon

/// A billing/measurement beacon waiting to be delivered. Today's `track*` helpers are fire-and-forget:
/// a beacon that fails (offline, 5xx) is lost. This makes them durable — persisted so a beacon that
/// couldn't land before the app was backgrounded/killed is retried (PRD → durable billing queue).
/// `action` is the impression-action path segment: `shown` / `seen` / `click`.
struct PendingBeacon: Codable, Equatable {
    let impressionId: String
    let action: String
    let metadata: [String: String]?
    var retryCount: Int = 0
    var lastAttemptTimestamp: Double = 0

    init(
        impressionId: String,
        action: String,
        metadata: [String: String]? = nil,
        retryCount: Int = 0,
        lastAttemptTimestamp: Double = 0
    ) {
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
/// - Durable: persisted to `UserDefaults`; survives relaunch, recovered on the next trigger.
/// - Backed off: failed attempts retry with the shared exponential backoff (5s → 60s cap).
///
/// `@unchecked Sendable` is safe: mutable state is guarded by `lock`, and `URLSession` inside
/// `SimulaAPI` is itself thread-safe.
public final class AdBeaconManager: @unchecked Sendable {
    public static let shared = AdBeaconManager()

    private let userDefaultsKey = "simula_pending_beacons"
    private let sender: BeaconSending
    private let defaults: UserDefaults
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var isProcessing = false
    private var apiKey: String?

    private init() {
        self.sender = SimulaAPI()
        self.defaults = .standard
        self.now = { Date().timeIntervalSince1970 }
    }

    /// Test seam: inject a fake sender, isolated `UserDefaults`, and a controllable clock.
    init(sender: BeaconSending, defaults: UserDefaults, now: @escaping @Sendable () -> TimeInterval, apiKey: String? = "test") {
        self.sender = sender
        self.defaults = defaults
        self.now = now
        self.apiKey = apiKey
    }

    /// Provide the api key (the beacon endpoints are Bearer-authed). Call once at SDK init; first wins.
    public func configure(apiKey: String) {
        lock.lock()
        if self.apiKey == nil { self.apiKey = apiKey }
        lock.unlock()
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
        var shouldWarnForMergedMetadata = false
        lock.lock()
        var list = loadQueue()
        if let index = list.firstIndex(where: { $0.impressionId == impressionId && $0.action == action }) {
            if let normalizedMetadata {
                var merged = list[index].metadata ?? [:]
                merged.merge(normalizedMetadata) { _, new in new }
                list[index] = PendingBeacon(
                    impressionId: list[index].impressionId,
                    action: list[index].action,
                    metadata: normalizeExtraParameters(merged, warn: { shouldWarnForMergedMetadata = true }),
                    retryCount: list[index].retryCount,
                    lastAttemptTimestamp: list[index].lastAttemptTimestamp
                )
                saveQueue(list)
            }
        } else {
            list.append(PendingBeacon(impressionId: impressionId, action: action, metadata: normalizedMetadata))
            saveQueue(list)
        }
        lock.unlock()
        if shouldWarnForMergedMetadata { warnInvalidExtraParameters() }
        triggerProcessQueue()
    }

    /// Drains any persisted beacons eligible under their backoff. Call at launch to recover work.
    public func triggerProcessQueue() {
        lock.lock()
        if isProcessing {
            lock.unlock()
            return
        }
        isProcessing = true
        lock.unlock()
        Task { await self.processQueue() }
    }

    // MARK: - Processing

    private func processQueue() async {
        guard let key = currentApiKey() else {
            // Not configured yet (pre-init) — leave the queue for the post-configure trigger.
            finishProcessing(reDrainIfEligible: false)
            return
        }
        var bailedForBackoff = false
        while let task = nextEligibleTask() {
            let delivered: Bool
            do {
                let code = try await sender.sendImpressionBeacon(
                    adId: task.impressionId,
                    action: task.action,
                    apiKey: key,
                    metadata: task.metadata
                )
                if (200...299).contains(code) {
                    delivered = true // accepted
                } else if (400...499).contains(code) && code != 408 && code != 429 {
                    delivered = true // permanent client error → drop
                } else {
                    delivered = false // 5xx / 408 / 429 → retry
                }
            } catch {
                delivered = false // connectivity failure → retry (server never received it)
            }
            if delivered {
                removeTask(task)
            } else {
                recordAttempt(task)
                bailedForBackoff = true
                break
            }
        }
        finishProcessing(reDrainIfEligible: !bailedForBackoff)
    }

    private func finishProcessing(reDrainIfEligible: Bool) {
        lock.lock()
        isProcessing = false
        var reDrain = false
        if reDrainIfEligible {
            let nowTs = now()
            reDrain = loadQueue().contains { nowTs - $0.lastAttemptTimestamp >= rewardVerificationBackoff(retryCount: $0.retryCount) }
        }
        lock.unlock()
        if reDrain { triggerProcessQueue() }
    }

    // MARK: - Queue state (lock-guarded)

    private func currentApiKey() -> String? {
        lock.lock(); defer { lock.unlock() }; return apiKey
    }

    private func nextEligibleTask() -> PendingBeacon? {
        lock.lock()
        defer { lock.unlock() }
        let nowTs = now()
        return loadQueue().first { nowTs - $0.lastAttemptTimestamp >= rewardVerificationBackoff(retryCount: $0.retryCount) }
    }

    private func removeTask(_ task: PendingBeacon) {
        lock.lock()
        defer { lock.unlock() }
        var queue = loadQueue()
        queue.removeAll {
            $0.impressionId == task.impressionId &&
                $0.action == task.action &&
                $0.metadata == task.metadata
        }
        saveQueue(queue)
    }

    private func recordAttempt(_ task: PendingBeacon) {
        lock.lock()
        defer { lock.unlock() }
        var queue = loadQueue()
        if let idx = queue.firstIndex(where: { $0.impressionId == task.impressionId && $0.action == task.action }) {
            queue[idx].retryCount += 1
            queue[idx].lastAttemptTimestamp = now()
        }
        saveQueue(queue)
    }

    // MARK: - Persistence

    private func loadQueue() -> [PendingBeacon] {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingBeacon].self, from: data)) ?? []
    }

    private func saveQueue(_ queue: [PendingBeacon]) {
        if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: userDefaultsKey)
        }
    }
}
