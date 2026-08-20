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
    /// Sent to verify-reward so the SSV callback resolves the ad unit. Optional (`var ... ?`) so
    /// queue entries persisted before this field existed still decode (as `nil`) instead of being
    /// dropped — which would lose the pending reward.
    var adUnitId: String?
}

// MARK: - Seams (injected so the queue is unit-testable without the network/clock)

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
/// - Durable: atomically persisted under Application Support and migrated once from the exact
///   legacy `simula_pending_reward_verifications` UserDefaults entry.
/// - Backed off: failed attempts retry with exponential backoff (5s → max 60s).
///
/// `@unchecked Sendable` is safe: mutable state and persistence are confined to `executor`, and
/// the `URLSession` inside `SimulaAPI` is itself thread-safe.
public final class RewardVerificationManager: @unchecked Sendable {
    public static let shared = RewardVerificationManager()

    private let verifier: RewardVerifying
    private let store: RewardVerificationStoring
    private let now: @Sendable () -> TimeInterval
    private let launchGate: LaunchSettling
    private let persistenceSleep: @Sendable (TimeInterval) async -> Void
    private let loadSleep: @Sendable (TimeInterval) async -> Void
    /// Suspends for the retry-wake delay. Production uses `Task.sleep`; tests inject a
    /// controllable sleeper so the wake can be released after advancing the fake clock —
    /// without waiting on wall-clock backoff (5s → 60s).
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let executor = DispatchQueue(label: "ad.simula.reward-verification.queue", qos: .utility)
    private let callbackQueue = DispatchQueue(label: "ad.simula.reward-verification.callbacks", qos: .utility)
    private var queue: [PendingVerification] = []
    private var pendingQueue: [PendingVerification] = []
    private var isLoaded = false
    private var isDirty = false
    private var isProcessing = false
    private var persistenceRetryCount = 0
    private var persistenceRetryTask: Task<Void, Never>?
    private var loadRetryCount = 0
    private var loadRetryTask: Task<Void, Never>?
    private var startupTriggerTask: Task<Void, Never>?
    private var pendingRemovalServeIds: Set<String> = []
    private var pendingCallbacks: [(@Sendable (Result<String?, Error>) -> Void, Result<String?, Error>)] = []
    private var pendingNetworkRetryDelay: TimeInterval?
    private let maxPendingEnqueues = 100

    /// A scheduled wake-up for the earliest backed-off task after a retryable failure (e.g. a
    /// server 5xx). Without it the backoff computed eligibility but nothing ever re-triggered
    /// the drain — a failed verify sat in the queue until the NEXT earned reward or app
    /// relaunch, so REWARD_VERIFIED could stall for a whole session. Executor-confined.
    private var retryTask: Task<Void, Never>?

    /// Per-`serveId` result callbacks, so a verification's outcome reaches the caller
    /// that enqueued it — not whoever happens to be draining the queue. One-shot:
    /// removed the first time the task is attempted, so it can't be misrouted to
    /// another play. Executor-confined.
    private var activeCallbacks: [String: @Sendable (Result<String?, Error>) -> Void] = [:]

    private init() {
        self.verifier = SimulaAPI()
        let fallback = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/SimulaAdSDK", isDirectory: true)
            .appendingPathComponent("pending_reward_verifications.json")
        let url = DurableJSONQueueStore<PendingVerification>.applicationSupportURL(fileName: "pending_reward_verifications.json") ?? fallback
        self.store = FileRewardVerificationStore(fileURL: url)
        self.now = { Date().timeIntervalSince1970 }
        self.launchGate = LaunchSettledGate.shared
        self.persistenceSleep = Self.defaultPersistenceSleep
        self.loadSleep = Self.defaultPersistenceSleep
        self.sleep = { delay in
            do { try await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000)) } catch { return }
        }
    }

    /// Test seam: inject a fake verifier, an isolated `UserDefaults`, a controllable
    /// clock, and (optionally) a controllable sleeper so the draining + retry-wake logic
    /// can be exercised deterministically — no network, no wall-clock timing.
    init(
        verifier: RewardVerifying,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> TimeInterval,
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        self.verifier = verifier
        self.store = UserDefaultsRewardVerificationStore(defaults)
        self.now = now
        self.launchGate = ImmediateLaunchSettledGate.shared
        self.persistenceSleep = Self.defaultPersistenceSleep
        self.loadSleep = Self.defaultPersistenceSleep
        self.sleep = sleep ?? { delay in
            do { try await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000)) } catch { return }
        }
    }

    init(
        verifier: RewardVerifying,
        store: RewardVerificationStoring,
        now: @escaping @Sendable () -> TimeInterval,
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        launchGate: LaunchSettling = ImmediateLaunchSettledGate.shared,
        persistenceSleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        loadSleep: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        self.verifier = verifier
        self.store = store
        self.now = now
        self.launchGate = launchGate
        self.persistenceSleep = persistenceSleep ?? Self.defaultPersistenceSleep
        self.loadSleep = loadSleep ?? Self.defaultPersistenceSleep
        self.sleep = sleep ?? { delay in
            do { try await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000)) } catch { return }
        }
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
        executor.async { [weak self] in
            self?.enqueueOnExecutor(
                serveId: serveId,
                sessionId: sessionId,
                elapsedPlayTime: elapsedPlayTime,
                adUnitId: adUnitId,
                completion: completion
            )
        }
    }

    private func enqueueOnExecutor(
        serveId: String,
        sessionId: String,
        elapsedPlayTime: Double,
        adUnitId: String,
        completion: (@Sendable (Result<String?, Error>) -> Void)?
    ) {
        guard elapsedPlayTime.isFinite else {
            Telemetry.shared.recordError(
                signature: "reward_verification:invalid_elapsed_time",
                breadcrumb: "value=non_finite"
            )
            callbackQueue.async { completion?(.failure(SimulaAPIError.invalidResponse)) }
            return
        }
        guard !pendingRemovalServeIds.contains(serveId) else { return }
        let loaded = loadIfNeeded()
        if let completion { activeCallbacks[serveId] = completion }
        guard loaded else {
            if !pendingQueue.contains(where: { $0.serveId == serveId }) {
                guard pendingQueue.count < maxPendingEnqueues else {
                    Telemetry.shared.recordError(
                        signature: "durable_queue:pending_full",
                        breadcrumb: "queue=reward_verification"
                    )
                    let callback = activeCallbacks.removeValue(forKey: serveId)
                    callbackQueue.async {
                        callback?(.failure(SimulaAPIError.invalidResponse))
                    }
                    return
                }
                pendingQueue.append(
                    PendingVerification(
                        serveId: serveId,
                        sessionId: sessionId,
                        elapsedPlayTime: elapsedPlayTime,
                        retryCount: 0,
                        lastAttemptTimestamp: 0,
                        adUnitId: adUnitId
                    )
                )
            }
            return
        }
        if !queue.contains(where: { $0.serveId == serveId }) {
            queue.append(
                PendingVerification(
                    serveId: serveId,
                    sessionId: sessionId,
                    elapsedPlayTime: elapsedPlayTime,
                    retryCount: 0,
                    lastAttemptTimestamp: 0,
                    adUnitId: adUnitId
                )
            )
            isDirty = true
            persistIfNeeded()
        } else if !isDirty {
            processOrScheduleRetry()
        }
    }

    /// Drains any persisted verifications that are eligible under their backoff.
    /// Call at app launch to recover work left over from a previous session.
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
        guard isLoaded, !isDirty, !isProcessing else { return false }
        let nowTs = now()
        guard let task = queue.first(where: {
            nowTs - $0.lastAttemptTimestamp >= rewardVerificationBackoff(retryCount: $0.retryCount)
        }) else { return false }
        isProcessing = true
        Task { await self.verify(task) }
        return true
    }

    private func verify(_ task: PendingVerification) async {
        let result: Result<String?, Error>
        do {
            let response = try await verifier.verifyReward(
                serveId: task.serveId,
                sessionId: task.sessionId,
                elapsedPlayTime: task.elapsedPlayTime,
                adUnitId: task.adUnitId ?? ""
            )
            result = .success(response.token)
        } catch {
            result = .failure(error)
        }
        executor.async { [weak self] in self?.complete(task: task, result: result) }
    }

    /// Releases the processing claim on the same serial executor that observes the queue,
    /// then decides whether to re-drain. This closes the race where a verification enqueued
    /// just as the drain finished would otherwise sit idle until some later trigger: a
    /// task persisted concurrently is either seen here (→ re-trigger) or seen by the
    /// enqueuer's own executor turn once `isProcessing` is false.
    private func complete(task: PendingVerification, result: Result<String?, Error>) {
        isProcessing = false
        let callback = activeCallbacks.removeValue(forKey: task.serveId)
        var retryDelay: TimeInterval?
        switch result {
        case .success:
            pendingRemovalServeIds.insert(task.serveId)
            queue.removeAll { $0.serveId == task.serveId }
        case .failure(let error):
            if isPermanentVerificationError(error) {
                pendingRemovalServeIds.insert(task.serveId)
                queue.removeAll { $0.serveId == task.serveId }
            } else if let index = queue.firstIndex(where: { $0.serveId == task.serveId }) {
                if queue[index].retryCount < Int.max { queue[index].retryCount += 1 }
                queue[index].lastAttemptTimestamp = now()
                let nowTs = now()
                let soonest = queue.map {
                    rewardVerificationBackoff(retryCount: $0.retryCount) - (nowTs - $0.lastAttemptTimestamp)
                }.min() ?? 0
                retryDelay = max(soonest, 1)
            }
        }
        if let callback { pendingCallbacks.append((callback, result)) }
        pendingNetworkRetryDelay = retryDelay
        isDirty = true
        persistIfNeeded()
    }

    /// Schedules (replacing any prior schedule) a queue drain after `delay`. A single pending
    /// wake is enough: every bail recomputes the earliest eligibility across the WHOLE queue,
    /// and a completed wake either drains or chains the next bail's schedule.
    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        retryTask = Task { await self.runRetryWake(delay: delay) }
    }

    private func processOrScheduleRetry() {
        guard !processNextIfPossible() else { return }
        let nowTs = now()
        guard let delay = queue.map({
            rewardVerificationBackoff(retryCount: $0.retryCount) - (nowTs - $0.lastAttemptTimestamp)
        }).filter({ $0 > 0 }).min() else {
            return
        }
        scheduleRetry(after: max(delay, 1))
    }

    /// Retry-wake task body (named method — see the task-shape note in TelemetryManager).
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
        switch store.load() {
        case .missing:
            queue = []
        case .loaded(let records):
            queue = records
        case .failed:
            loadRetryCount += 1
            Telemetry.shared.recordError(signature: "reward_verification:load_failed")
            scheduleLoadRetry()
            return false
        }
        isLoaded = true
        loadRetryCount = 0
        loadRetryTask?.cancel()
        loadRetryTask = nil
        let hadPending = !pendingQueue.isEmpty
        for pending in pendingQueue where !queue.contains(where: { $0.serveId == pending.serveId }) {
            queue.append(pending)
        }
        pendingQueue.removeAll()
        if hadPending {
            // Persist the complete loaded + pending candidate even when every pending serve id
            // deduped against recovered state. Only then may callbacks/sends use that recovery.
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
            persistenceRetryCount = 0
            persistenceRetryTask?.cancel()
            persistenceRetryTask = nil
            durabilityCommitted()
        } else {
            persistenceRetryCount += 1
            Telemetry.shared.recordError(signature: "reward_verification:persist_failed")
            schedulePersistenceRetry()
        }
    }

    private func durabilityCommitted() {
        pendingRemovalServeIds.removeAll()
        let callbacks = pendingCallbacks
        pendingCallbacks.removeAll()
        for (callback, result) in callbacks {
            callbackQueue.async { callback(result) }
        }
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
