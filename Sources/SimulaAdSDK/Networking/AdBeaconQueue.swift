import Foundation

// MARK: - PendingBeacon

/// A billing/measurement beacon waiting to be delivered. Today's `track*` helpers are fire-and-forget:
/// a beacon that fails (offline, 5xx) is lost. This makes them durable — persisted so a beacon that
/// couldn't land before the app was backgrounded/killed is retried (PRD → durable billing queue).
/// `action` is the impression-action path segment: `shown` / `seen` / `click`.
struct PendingBeacon: Codable, Equatable {
    let impressionId: String
    let action: String
    var retryCount: Int = 0
    var lastAttemptTimestamp: Double = 0
    /// Enqueue time, for the TTL prune. Optional so rows persisted before this field
    /// existed still decode (stamped at first load).
    var createdAt: TimeInterval? = nil
}

/// Hard cap on each durable queue (billing beacons + reward verifications). On overflow the
/// oldest entry is dropped (and recorded) — a stuck endpoint + nonstop ads must never grow
/// the durable blob unboundedly (AND-2/iOS-4).
let maxPendingBeacons = 200

/// TTL for durable-queue entries: a beacon/verification older than this is outside any useful
/// attribution window and pruned at load instead of retried forever.
let durableQueueMaxAgeSeconds: TimeInterval = 24 * 3_600

/// `UserDefaults` is thread-safe (Apple docs) but not marked `Sendable` — box it so the
/// background persist closure can carry it without tripping Swift 6 `#SendableClosureCaptures`.
final class UncheckedSendableDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
}

// MARK: - Seam

/// Sends one impression-action beacon, returning the HTTP status (or throwing on connectivity).
/// `SimulaAPI` is the production implementation; tests substitute a fake.
protocol BeaconSending: Sendable {
    func sendImpressionBeacon(adId: String, action: String, apiKey: String) async throws -> Int
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
/// - Bounded: at most `maxPendingBeacons` entries (drop-oldest on overflow, recorded).
/// - Batched + off-main persistence: the queue lives in memory after one initial load; each
///   drain pass persists ONCE (per-mutation decode+encode+set on the main thread was O(n²)
///   jank), and the write itself runs on a utility queue. A crash mid-drain re-sends
///   already-accepted beacons — safe: `/seen` is deduped server-side, `/click` over-count is
///   the same small risk the retry path already accepts.
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
    /// Executes the JSON-encode + `UserDefaults.set` persist off the calling thread
    /// (production: a serial utility queue; tests inject a synchronous runner).
    private let performPersist: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private var isProcessing = false
    private var apiKey: String?
    /// In-memory queue — loaded lazily on first use. Guarded by `lock`.
    private var cache: [PendingBeacon]?

    private init() {
        self.sender = SimulaAPI()
        self.defaults = .standard
        self.now = { Date().timeIntervalSince1970 }
        let persistQueue = DispatchQueue(label: "com.simula.adbeacon.persist", qos: .utility)
        self.performPersist = { work in persistQueue.async(execute: work) }
        #if canImport(UIKit)
        // Sync-persist as the app heads to the background: enqueues mutate the in-memory
        // queue and persist on a utility queue, so a beacon fired moments before the
        // process is suspended/killed could otherwise be lost (the durability window the
        // in-memory cache re-opens). Mirrors the telemetry pipeline's background flush;
        // `UserDefaults.set` is a non-blocking cfprefsd handoff, safe on the posting thread.
        backgroundFlushObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.persistNowSync() }
        #endif
    }

    #if canImport(UIKit)
    /// Token for the app-background persist hook (retained for the process lifetime by design).
    private var backgroundFlushObserver: NSObjectProtocol?
    #endif

    /// Test seam: inject a fake sender, isolated `UserDefaults`, and a controllable clock.
    /// `performPersist` defaults to synchronous; inject a swallowing runner to simulate a
    /// pending utility-queue write that never lands before a process kill.
    init(sender: BeaconSending, defaults: UserDefaults, now: @escaping @Sendable () -> TimeInterval, apiKey: String? = "test", performPersist: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        self.sender = sender
        self.defaults = defaults
        self.now = now
        self.apiKey = apiKey
        self.performPersist = performPersist ?? { work in work() }
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
    public func enqueue(impressionId: String, action: String, adFormat: String? = nil, adUnitId: String? = nil) {
        guard !impressionId.isEmpty else { return }
        switch action {
        case "seen":
            Telemetry.shared.recordLifecycle(stage: "impression_fired", adFormat: adFormat, adUnitId: adUnitId, adId: impressionId)
        case "click":
            Telemetry.shared.recordLifecycle(stage: "click_fired", adFormat: adFormat, adUnitId: adUnitId, adId: impressionId)
        default:
            break
        }
        lock.lock()
        var list = loadQueueLocked()
        if !list.contains(where: { $0.impressionId == impressionId && $0.action == action }) {
            if list.count >= maxPendingBeacons {
                list.removeFirst() // drop oldest: bounded queue > an unbounded main-thread backlog
                Telemetry.shared.recordError(
                    signature: "beacon:queue_overflow",
                    errorCode: "queue_full",
                    message: "pending beacon queue at cap (\(maxPendingBeacons)) — dropped oldest"
                )
            }
            list.append(PendingBeacon(impressionId: impressionId, action: action, createdAt: now()))
            cache = list
            persistLocked()
        }
        lock.unlock()
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
                let code = try await sender.sendImpressionBeacon(adId: task.impressionId, action: task.action, apiKey: key)
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
        persistLocked() // ONE persist per drain pass (was per mutation — the O(n²) shape)
        var reDrain = false
        if reDrainIfEligible {
            let nowTs = now()
            reDrain = loadQueueLocked().contains { nowTs - $0.lastAttemptTimestamp >= rewardVerificationBackoff(retryCount: $0.retryCount) }
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
        return loadQueueLocked().first { nowTs - $0.lastAttemptTimestamp >= rewardVerificationBackoff(retryCount: $0.retryCount) }
    }

    private func removeTask(_ task: PendingBeacon) {
        lock.lock()
        defer { lock.unlock() }
        // In-memory mutation only — the drain pass persists once, in finishProcessing.
        cache?.removeAll { $0.impressionId == task.impressionId && $0.action == task.action }
    }

    private func recordAttempt(_ task: PendingBeacon) {
        lock.lock()
        defer { lock.unlock() }
        // In-memory mutation only — persisted by the drain pass's single write.
        guard let idx = cache?.firstIndex(where: { $0.impressionId == task.impressionId && $0.action == task.action }) else { return }
        cache?[idx].retryCount += 1
        cache?[idx].lastAttemptTimestamp = now()
    }

    // MARK: - Persistence

    /// The live queue, in memory after one lazy disk load (which also stamps legacy rows and
    /// prunes expired ones). MUST only be called under `lock`.
    private func loadQueueLocked() -> [PendingBeacon] {
        if let cache { return cache }
        let nowTs = now()
        var dirty = false
        let list: [PendingBeacon] = loadQueue().compactMap { beacon in
            var b = beacon
            if b.createdAt == nil || b.createdAt == 0 {
                // Legacy row (pre-TTL): baseline = its last attempt (or now when never
                // attempted), so genuinely old rows expire instead of retrying forever.
                b.createdAt = b.lastAttemptTimestamp > 0 ? b.lastAttemptTimestamp : nowTs
                dirty = true
            }
            if nowTs - (b.createdAt ?? nowTs) > durableQueueMaxAgeSeconds {
                dirty = true
                return nil // TTL prune: outside any useful attribution window
            }
            return b
        }
        cache = list
        if dirty { persistLocked() }
        return list
    }

    /// Encode + write the current cache off the calling thread (snapshot is a value type).
    /// MUST only be called under `lock`.
    private func persistLocked() {
        guard let cache else { return }
        let box = UncheckedSendableDefaults(defaults)
        performPersist { [userDefaultsKey] in
            if let data = try? JSONEncoder().encode(cache) {
                box.defaults.set(data, forKey: userDefaultsKey)
            }
        }
    }

    /// Synchronously persist the in-memory queue NOW (app-background path). Closes the
    /// durability window between an in-memory enqueue and the async utility-queue write:
    /// without it, a beacon fired just before the process is suspended/killed is lost.
    func persistNowSync() {
        lock.lock()
        let snapshot = cache
        lock.unlock()
        guard let snapshot,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }

    private func loadQueue() -> [PendingBeacon] {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingBeacon].self, from: data)) ?? []
    }
}
