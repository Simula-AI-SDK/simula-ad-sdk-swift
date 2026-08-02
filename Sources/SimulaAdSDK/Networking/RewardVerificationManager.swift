import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PendingVerification

/// A reward verification waiting to be delivered to the server. Persisted so a
/// verify that couldn't land before the app was backgrounded/killed is retried on
/// next launch — the reward (and its server-side SSV postback) is never silently lost.
struct PendingVerification: Codable, Equatable {
    let serveId: String
    let sessionId: String
    let elapsedPlayTime: Double
    var retryCount: Int
    var lastAttemptTimestamp: Double
    /// Sent to verify-reward so the SSV callback resolves the ad unit. Optional (`var ... ?`) so
    /// queue entries persisted before this field existed still decode (as `nil`) instead of being
    /// dropped — which would lose the pending reward.
    var adUnitId: String?
    /// Enqueue time, for the TTL prune. Optional so rows persisted before this field existed
    /// still decode (stamped at first load).
    var createdAt: TimeInterval? = nil
}

// MARK: - Seams (injected so the queue is unit-testable without the network/clock)

/// Delivered to the registered completion of a pending verification that was dropped at the
/// queue cap (oldest-out overflow) before its first attempt — so the host's reward flow gets
/// a terminal signal instead of hanging on a result that can never arrive.
struct VerificationQueueOverflowError: Error {}

/// Performs one `verify-reward` call. `SimulaAPI` is the production implementation;
/// tests substitute a fake. Mirrors the Kotlin `RewardVerifier`.
protocol RewardVerifying: Sendable {
    func verifyReward(serveId: String, sessionId: String, elapsedPlayTime: Double, adUnitId: String) async throws -> VerifyRewardResponse
}

extension SimulaAPI: RewardVerifying {}

/// Exponential backoff for verification retries: 0, then 5s, 10s, 20s, 40s, capped 60s.
func rewardVerificationBackoff(retryCount: Int) -> TimeInterval {
    guard retryCount > 0 else { return 0 }
    return min(pow(2.0, Double(retryCount - 1)) * 5.0, 60.0)
}

/// True if [error] is a permanent client error — a 4xx other than 408 (Request Timeout)
/// or 429 (Too Many Requests) — for which retrying won't help.
func isPermanentVerificationError(_ error: Error) -> Bool {
    if case let SimulaAPIError.httpError(statusCode) = error,
       (400...499).contains(statusCode), statusCode != 408, statusCode != 429 {
        return true
    }
    return false
}

// MARK: - RewardVerificationManager

/// Thread-safe, persistent queue that delivers `verify-reward` calls reliably and
/// idempotently. Verification is intentionally off the UI path: the rewarded ad
/// closes optimistically and enqueues here, so the user never waits on the network.
///
/// - Idempotent: deduped by `serve_id`; the API layer maps HTTP 409 (already
///   claimed) to a successful verification, so retries converge without
///   double-firing the publisher's postback.
/// - Durable: the queue is persisted to `UserDefaults` and survives relaunch.
/// - Backed off: failed attempts retry with exponential backoff (5s → max 60s).
///
/// `@unchecked Sendable` is safe: all mutable state is guarded by `lock`, and the
/// `URLSession` inside `SimulaAPI` is itself thread-safe.
public final class RewardVerificationManager: @unchecked Sendable {
    public static let shared = RewardVerificationManager()

    private let userDefaultsKey = "simula_pending_reward_verifications"
    private let verifier: RewardVerifying
    private let defaults: UserDefaults
    private let now: @Sendable () -> TimeInterval
    /// Suspends for the retry-wake delay. Production uses `Task.sleep`; tests inject a
    /// controllable sleeper so the wake can be released after advancing the fake clock —
    /// without waiting on wall-clock backoff (5s → 60s).
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let lock = NSLock()
    private var isProcessing = false
    /// In-memory queue — loaded lazily on first use. Guarded by `lock`.
    private var cache: [PendingVerification]?
    /// Executes the JSON-encode + `UserDefaults.set` persist off the calling thread
    /// (production: a serial utility queue; tests inject a synchronous runner).
    private let performPersist: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// A scheduled wake-up for the earliest backed-off task after a retryable failure (e.g. a
    /// server 5xx). Without it the backoff computed eligibility but nothing ever re-triggered
    /// the drain — a failed verify sat in the queue until the NEXT earned reward or app
    /// relaunch, so REWARD_VERIFIED could stall for a whole session. Guarded by `lock`.
    private var retryTask: Task<Void, Never>?

    /// Per-`serveId` result callbacks, so a verification's outcome reaches the caller
    /// that enqueued it — not whoever happens to be draining the queue. One-shot:
    /// removed the first time the task is attempted, so it can't be misrouted to
    /// another play. Guarded by `lock`.
    private var activeCallbacks: [String: @Sendable (Result<String?, Error>) -> Void] = [:]

    private init() {
        self.verifier = SimulaAPI()
        self.defaults = .standard
        self.now = { Date().timeIntervalSince1970 }
        self.sleep = { delay in
            do { try await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000)) } catch { return }
        }
        let persistQueue = DispatchQueue(label: "com.simula.rewardverify.persist", qos: .utility)
        self.performPersist = { work in persistQueue.async(execute: work) }
        #if canImport(UIKit)
        // Reward completion commonly happens immediately before backgrounding. Persist the
        // in-memory queue synchronously as the app leaves the foreground so suspension/kill
        // cannot lose the reward + SSV postback while the utility write is still pending.
        backgroundFlushObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.persistNowSync() }
        #endif
    }

    #if canImport(UIKit)
    /// Token for the app-background persist hook (retained for the process lifetime by design).
    private var backgroundFlushObserver: NSObjectProtocol?
    #endif

    /// Test seam: inject a fake verifier, an isolated `UserDefaults`, a controllable
    /// clock, and (optionally) a controllable sleeper so the draining + retry-wake logic
    /// can be exercised deterministically — no network, no wall-clock timing.
    init(
        verifier: RewardVerifying,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> TimeInterval,
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        performPersist: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
    ) {
        self.verifier = verifier
        self.defaults = defaults
        self.now = now
        self.sleep = sleep ?? { delay in
            do { try await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000)) } catch { return }
        }
        self.performPersist = performPersist ?? { work in work() }
    }

    /// Enqueues a verification, persists it, and starts draining the queue. The
    /// `completion` is invoked per attempt: `.success(token)` once verified (or
    /// already-claimed), `.failure` on a (possibly retryable) error. Safe to call
    /// repeatedly for the same `serveId` — duplicates are ignored.
    public func queueVerification(
        serveId: String,
        sessionId: String,
        elapsedPlayTime: Double,
        adUnitId: String = "",
        completion: (@Sendable (Result<String?, Error>) -> Void)? = nil
    ) {
        lock.lock()
        // Register before enqueueing so a drain already in flight (which reloads the
        // queue each iteration and can pick this task up) still routes the result here.
        if let completion = completion {
            activeCallbacks[serveId] = completion
        }
        var droppedServeId: String?
        var list = loadQueueLocked()
        if !list.contains(where: { $0.serveId == serveId }) {
            if list.count >= maxPendingBeacons {
                droppedServeId = list.removeFirst().serveId // drop oldest: bounded queue > an unbounded main-thread backlog
                Telemetry.shared.recordError(
                    signature: "reward:queue_overflow",
                    errorCode: "queue_full",
                    message: "pending verification queue at cap (\(maxPendingBeacons)) — dropped oldest"
                )
            }
            list.append(
                PendingVerification(
                    serveId: serveId,
                    sessionId: sessionId,
                    elapsedPlayTime: elapsedPlayTime,
                    retryCount: 0,
                    lastAttemptTimestamp: 0,
                    adUnitId: adUnitId,
                    createdAt: now()
                )
            )
            cache = list
            persistLocked()
        }
        lock.unlock()

        // The dropped play's one-shot must still fire — otherwise its registered callback
        // leaks in `activeCallbacks` and the host's reward flow hangs waiting on a result
        // that can never arrive. Delivered off the lock, like every other outcome.
        if let droppedServeId {
            invokeCallback(serveId: droppedServeId, .failure(VerificationQueueOverflowError()))
        }

        triggerProcessQueue()
    }

    /// Drains any persisted verifications that are eligible under their backoff.
    /// Call at app launch to recover work left over from a previous session.
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
        // True when we stop because a task hit a retryable error: its peers (if any)
        // are intentionally left for a later trigger, so we must NOT immediately re-drain.
        var bailedForBackoff = false

        while let task = nextEligibleTask() {
            do {
                let res = try await verifier.verifyReward(
                    serveId: task.serveId,
                    sessionId: task.sessionId,
                    elapsedPlayTime: task.elapsedPlayTime,
                    adUnitId: task.adUnitId ?? ""
                )
                removeTask(serveId: task.serveId)
                invokeCallback(serveId: task.serveId, .success(res.token))
            } catch {
                // A 4xx (except 408/429) is permanent: retrying won't help, so drop it.
                if !isPermanentVerificationError(error) {
                    // Keep the task for a later trigger; deliver this attempt's failure
                    // to its caller once (the server-side SSV postback still lands on a
                    // successful retry — the client signal is one-shot).
                    recordAttempt(serveId: task.serveId)
                    invokeCallback(serveId: task.serveId, .failure(error))
                    bailedForBackoff = true
                    break
                } else {
                    removeTask(serveId: task.serveId)
                    invokeCallback(serveId: task.serveId, .failure(error))
                }
            }
        }

        finishProcessing(reDrainIfEligible: !bailedForBackoff)
    }

    /// Delivers a task's outcome to its registered caller exactly once, off the lock.
    private func invokeCallback(serveId: String, _ result: Result<String?, Error>) {
        lock.lock()
        let callback = activeCallbacks.removeValue(forKey: serveId)
        lock.unlock()
        callback?(result)
    }

    /// Releases the processing claim and, under the SAME lock that observes the queue,
    /// decides whether to re-drain. This closes the race where a verification enqueued
    /// just as the drain finished would otherwise sit idle until some later trigger: a
    /// task persisted concurrently is either seen here (→ re-trigger) or seen by the
    /// enqueuer's own `triggerProcessQueue` once `isProcessing` is false.
    private func finishProcessing(reDrainIfEligible: Bool) {
        lock.lock()
        isProcessing = false
        persistLocked() // ONE persist per drain pass (was per mutation — the O(n²) shape)
        var reDrain = false
        var retryDelay: TimeInterval?
        let nowTs = now()
        if reDrainIfEligible {
            reDrain = loadQueueLocked().contains { nowTs - $0.lastAttemptTimestamp >= rewardVerificationBackoff(retryCount: $0.retryCount) }
        } else {
            // Bailed on a retryable failure: schedule a wake at the earliest remaining backoff so
            // the retry actually happens in-session, instead of waiting for the next enqueue or
            // launch. Scheduled ONLY from the bail path (not from every pass with pending tasks),
            // so a wake that finds nothing eligible — e.g. under a frozen test clock — terminates
            // instead of rescheduling itself forever.
            let queue = loadQueueLocked()
            if !queue.isEmpty {
                let soonest = queue
                    .map { rewardVerificationBackoff(retryCount: $0.retryCount) - (nowTs - $0.lastAttemptTimestamp) }
                    .min() ?? 0
                // ≥1s floor: never hot-loop against a backend that just failed.
                retryDelay = max(soonest, 1)
            }
        }
        lock.unlock()
        if reDrain { triggerProcessQueue() }
        if let retryDelay { scheduleRetry(after: retryDelay) }
    }

    /// Schedules (replacing any prior schedule) a queue drain after `delay`. A single pending
    /// wake is enough: every bail recomputes the earliest eligibility across the WHOLE queue,
    /// and a completed wake either drains or chains the next bail's schedule.
    private func scheduleRetry(after delay: TimeInterval) {
        lock.lock()
        retryTask?.cancel()
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        retryTask = Task { await self.runRetryWake(delay: delay) }
        lock.unlock()
    }

    /// Retry-wake task body (named method — see the task-shape note in TelemetryManager).
    private func runRetryWake(delay: TimeInterval) async {
        await sleep(delay)
        guard !Task.isCancelled else { return }
        triggerProcessQueue()
    }

    // MARK: - Queue state (lock-guarded)

    private func nextEligibleTask() -> PendingVerification? {
        lock.lock()
        defer { lock.unlock() }
        let nowTs = now()
        return loadQueueLocked().first { nowTs - $0.lastAttemptTimestamp >= rewardVerificationBackoff(retryCount: $0.retryCount) }
    }

    private func removeTask(serveId: String) {
        lock.lock()
        defer { lock.unlock() }
        // In-memory mutation only — the drain pass persists once, in finishProcessing.
        cache?.removeAll { $0.serveId == serveId }
    }

    private func recordAttempt(serveId: String) {
        lock.lock()
        defer { lock.unlock() }
        // In-memory mutation only — persisted by the drain pass's single write.
        guard let idx = cache?.firstIndex(where: { $0.serveId == serveId }) else { return }
        cache?[idx].retryCount += 1
        cache?[idx].lastAttemptTimestamp = now()
    }

    // MARK: - Persistence

    /// The live queue, in memory after one lazy disk load (which also stamps legacy rows and
    /// prunes expired ones). MUST only be called under `lock`.
    private func loadQueueLocked() -> [PendingVerification] {
        if let cache { return cache }
        let nowTs = now()
        var dirty = false
        let list: [PendingVerification] = loadQueue().compactMap { verification in
            var v = verification
            if v.createdAt == nil || v.createdAt == 0 {
                // Legacy row (pre-TTL): baseline = its last attempt (or now when never
                // attempted), so genuinely old rows expire instead of retrying forever.
                v.createdAt = v.lastAttemptTimestamp > 0 ? v.lastAttemptTimestamp : nowTs
                dirty = true
            }
            if nowTs - (v.createdAt ?? nowTs) > durableQueueMaxAgeSeconds {
                dirty = true
                return nil // TTL prune: outside any useful attribution window
            }
            return v
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
    /// durability window between an earned reward entering memory and the async utility
    /// write: suspension/kill in that window would lose both the reward and SSV postback.
    func persistNowSync() {
        lock.lock()
        let snapshot = cache
        lock.unlock()
        guard let snapshot,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }

    private func loadQueue() -> [PendingVerification] {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingVerification].self, from: data)) ?? []
    }
}
