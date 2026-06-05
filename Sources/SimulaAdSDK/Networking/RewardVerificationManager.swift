import Foundation

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
    private let api = SimulaAPI()
    private let lock = NSLock()
    private var isProcessing = false

    /// Per-`serveId` result callbacks, so a verification's outcome reaches the caller
    /// that enqueued it — not whoever happens to be draining the queue. One-shot:
    /// removed the first time the task is attempted, so it can't be misrouted to
    /// another play. Guarded by `lock`.
    private var activeCallbacks: [String: @Sendable (Result<String?, Error>) -> Void] = [:]

    private init() {}

    /// Enqueues a verification, persists it, and starts draining the queue. The
    /// `completion` is invoked per attempt: `.success(token)` once verified (or
    /// already-claimed), `.failure` on a (possibly retryable) error. Safe to call
    /// repeatedly for the same `serveId` — duplicates are ignored.
    public func queueVerification(
        serveId: String,
        sessionId: String,
        elapsedPlayTime: Double,
        completion: (@Sendable (Result<String?, Error>) -> Void)? = nil
    ) {
        lock.lock()
        // Register before enqueueing so a drain already in flight (which reloads the
        // queue each iteration and can pick this task up) still routes the result here.
        if let completion = completion {
            activeCallbacks[serveId] = completion
        }
        var list = loadQueue()
        if !list.contains(where: { $0.serveId == serveId }) {
            list.append(
                PendingVerification(
                    serveId: serveId,
                    sessionId: sessionId,
                    elapsedPlayTime: elapsedPlayTime,
                    retryCount: 0,
                    lastAttemptTimestamp: 0
                )
            )
            saveQueue(list)
        }
        lock.unlock()

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
                let res = try await api.verifyReward(
                    serveId: task.serveId,
                    sessionId: task.sessionId,
                    elapsedPlayTime: task.elapsedPlayTime
                )
                removeTask(serveId: task.serveId)
                invokeCallback(serveId: task.serveId, .success(res.token))
            } catch {
                // 4xx (except 408 Request Timeout / 429 Too Many Requests) is a
                // permanent client error: retrying won't help, so drop it.
                var retryable = true
                if case let SimulaAPIError.httpError(statusCode) = error,
                   (400...499).contains(statusCode), statusCode != 408, statusCode != 429 {
                    retryable = false
                }

                if retryable {
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
        var reDrain = false
        if reDrainIfEligible {
            let now = Date().timeIntervalSince1970
            reDrain = loadQueue().contains { now - $0.lastAttemptTimestamp >= calculateBackoff(retryCount: $0.retryCount) }
        }
        lock.unlock()
        if reDrain { triggerProcessQueue() }
    }

    /// Exponential backoff: first attempt immediate, then 5s, 10s, 20s, 40s, 60s cap.
    private func calculateBackoff(retryCount: Int) -> Double {
        guard retryCount > 0 else { return 0 }
        return min(pow(2.0, Double(retryCount - 1)) * 5.0, 60.0)
    }

    // MARK: - Queue state (lock-guarded)

    private func nextEligibleTask() -> PendingVerification? {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        return loadQueue().first { now - $0.lastAttemptTimestamp >= calculateBackoff(retryCount: $0.retryCount) }
    }

    private func removeTask(serveId: String) {
        lock.lock()
        defer { lock.unlock() }
        var queue = loadQueue()
        queue.removeAll { $0.serveId == serveId }
        saveQueue(queue)
    }

    private func recordAttempt(serveId: String) {
        lock.lock()
        defer { lock.unlock() }
        var queue = loadQueue()
        if let idx = queue.firstIndex(where: { $0.serveId == serveId }) {
            queue[idx].retryCount += 1
            queue[idx].lastAttemptTimestamp = Date().timeIntervalSince1970
        }
        saveQueue(queue)
    }

    // MARK: - Persistence

    private func loadQueue() -> [PendingVerification] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingVerification].self, from: data)) ?? []
    }

    private func saveQueue(_ queue: [PendingVerification]) {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
}
