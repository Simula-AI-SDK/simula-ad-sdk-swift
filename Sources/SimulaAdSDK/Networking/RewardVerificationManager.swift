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

        triggerProcessQueue(completion: completion)
    }

    /// Drains any persisted verifications that are eligible under their backoff.
    /// Call at app launch to recover work left over from a previous session.
    public func triggerProcessQueue(completion: (@Sendable (Result<String?, Error>) -> Void)? = nil) {
        lock.lock()
        if isProcessing {
            lock.unlock()
            return
        }
        isProcessing = true
        lock.unlock()

        Task { await self.processQueue(completion: completion) }
    }

    // MARK: - Processing

    private func processQueue(completion: (@Sendable (Result<String?, Error>) -> Void)?) async {
        defer { markProcessed() }

        while let task = nextEligibleTask() {
            do {
                let res = try await api.verifyReward(
                    serveId: task.serveId,
                    sessionId: task.sessionId,
                    elapsedPlayTime: task.elapsedPlayTime
                )
                removeTask(serveId: task.serveId)
                completion?(.success(res.token))
            } catch {
                // 4xx (except 408 Request Timeout / 429 Too Many Requests) is a
                // permanent client error: retrying won't help, so drop it.
                var retryable = true
                if case let SimulaAPIError.httpError(statusCode) = error,
                   (400...499).contains(statusCode), statusCode != 408, statusCode != 429 {
                    retryable = false
                }

                if retryable {
                    recordAttempt(serveId: task.serveId)
                    completion?(.failure(error))
                    // Stop here; the remaining backoff is awaited by a later trigger.
                    break
                } else {
                    removeTask(serveId: task.serveId)
                    completion?(.failure(error))
                }
            }
        }
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

    private func markProcessed() {
        lock.lock()
        isProcessing = false
        lock.unlock()
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
