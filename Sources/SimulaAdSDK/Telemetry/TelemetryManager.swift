import Foundation

/// Static per-process/device context attached to every telemetry batch.
struct TelemetryContext {
    let sdkVersion: String
    let osVersion: String
    let deviceModel: String
    let hostAppId: String
    let devMode: Bool
    var platform: String = "ios"
}

/// Batches handled-error + performance telemetry and delivers it to the Simula backend,
/// off the UI path. Models the durable, conflict-free design of `RewardVerificationManager`:
///
/// - **Durable**: the buffer is persisted via `TelemetryStoring`; errors persist immediately
///   (most likely to precede process death), perf events on each flush. Recovered on `start`.
/// - **Batched**: flushes at `flushThreshold` events, every `flushInterval`, or eagerly on an
///   error. Failed batches retry with exponential backoff.
/// - **Bounded**: the buffer caps at `maxBuffer` (oldest dropped) and distinct error signatures
///   at `maxErrorSignatures`; both surface a `dropped` meta event rather than silently truncating.
/// - **Sampled / killable**: perf is sampled per session at `sampleRate`; the whole pipeline
///   honors `isEnabled` (host opt-out always wins; the server can additionally disable it).
///
/// `@unchecked Sendable` is safe: all mutable state is guarded by `lock`, and the async send
/// happens off the lock. Collaborators are injected so the engine is exercised with an isolated
/// `UserDefaults`, a controllable clock, and a fake sender — no network, no wall-clock timing.
final class TelemetryManager: @unchecked Sendable {
    private let ctx: TelemetryContext
    private let store: TelemetryStoring
    private let sender: TelemetrySending
    private let primaryUserIdProvider: @Sendable () -> String?
    private let advertisingIdProvider: @Sendable () -> String?
    // Resolved fresh on each flush (off the UI path). Must be best-effort/non-throwing.
    private let connectionTypeProvider: @Sendable () -> String?
    private let now: @Sendable () -> TimeInterval
    private let random: @Sendable () -> Double
    private let backoff: @Sendable (Int) -> TimeInterval
    // Dev-only sink: when set (devMode), each recorded event is logged here (already redacted).
    private let debugLog: (@Sendable (String) -> Void)?
    private let flushThreshold: Int
    private let maxBuffer: Int
    private let maxErrorSignatures: Int
    private let maxMessageLen = 300
    private let flushInterval: TimeInterval

    // Serial queue so the UserDefaults encode + write never runs on the caller's thread
    // (often the main thread during ad-failure callbacks). Writes stay ordered: errors
    // persist via `persistAsync` (prompt, non-blocking) while the background / flush
    // paths persist via `persistSync` (must complete before returning).
    private let persistQueue = DispatchQueue(label: "ad.simula.telemetry.persist", qos: .utility)

    private let lock = NSLock()
    private var buffer: [TelemetryEvent] = []
    private var errorAgg: [String: TelemetryEvent] = [:]
    private var droppedCount = 0
    private var isFlushing = false
    private var flushScheduled = false
    private var retryCount = 0
    private var isEnabled: Bool
    private var perfSampledIn: Bool
    private var sessionId: String?

    init(
        ctx: TelemetryContext,
        store: TelemetryStoring,
        sender: TelemetrySending,
        primaryUserIdProvider: @escaping @Sendable () -> String?,
        advertisingIdProvider: @escaping @Sendable () -> String?,
        connectionTypeProvider: @escaping @Sendable () -> String? = { nil },
        enabled: Bool = true,
        sampleRate: Double = 1.0,
        // Epoch milliseconds, matching the Kotlin SDK's `System.currentTimeMillis()` timestamps.
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 * 1000 },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        backoff: @escaping @Sendable (Int) -> TimeInterval = { telemetryBackoff(retryCount: $0) },
        debugLog: (@Sendable (String) -> Void)? = nil,
        flushThreshold: Int = 20,
        maxBuffer: Int = 200,
        maxErrorSignatures: Int = 50,
        flushInterval: TimeInterval = 30
    ) {
        self.ctx = ctx
        self.store = store
        self.sender = sender
        self.primaryUserIdProvider = primaryUserIdProvider
        self.advertisingIdProvider = advertisingIdProvider
        self.connectionTypeProvider = connectionTypeProvider
        self.now = now
        self.random = random
        self.backoff = backoff
        self.debugLog = debugLog
        self.flushThreshold = flushThreshold
        self.maxBuffer = maxBuffer
        self.maxErrorSignatures = maxErrorSignatures
        self.flushInterval = flushInterval
        self.isEnabled = enabled
        self.perfSampledIn = enabled && random() < sampleRate
    }

    /// Recover any buffer left by a prior process, then attempt a flush.
    func start() {
        Task { [weak self] in await self?.recoverAndFlush() }
    }

    private func recoverAndFlush() async {
        recover()
        await flush()
    }

    /// Synchronous (no `await`) so `NSLock` use stays out of async contexts (Swift 6).
    private func recover() {
        lock.lock()
        for e in store.load() {
            if e.type == TelemetryType.error, !e.name.isEmpty { errorAgg[e.name] = e }
            else { buffer.append(e) }
        }
        lock.unlock()
    }

    /// Push the live session id (from `SimulaProvider`) so the envelope can carry it without
    /// the manager reaching into non-Sendable provider state from a background flush.
    func setSessionId(_ id: String?) {
        lock.lock(); sessionId = id; lock.unlock()
    }

    /// Apply a server-side directive (kill-switch / sampling) from `/session/create`.
    func applyServerConfig(enabled: Bool, sampleRate: Double) {
        lock.lock()
        isEnabled = enabled
        perfSampledIn = enabled && random() < min(max(sampleRate, 0), 1)
        lock.unlock()
    }

    // MARK: - Record entry points

    func recordNetwork(
        path: String,
        method: String,
        statusCode: Int?,
        durationMs: Int,
        requestBytes: Int64,
        responseBytes: Int64,
        failureClass: String?
    ) {
        var e = newEvent(type: TelemetryType.network, name: "\(method) \(path)")
        e.statusCode = statusCode
        e.durationMs = durationMs
        e.requestBytes = requestBytes
        e.responseBytes = responseBytes
        e.failureClass = failureClass
        enqueuePerf(e)
    }

    func recordOperation(name: String, durationMs: Int, success: Bool, failureClass: String? = nil, breadcrumb: String? = nil) {
        var e = newEvent(type: TelemetryType.operation, name: name)
        e.durationMs = durationMs
        e.success = success
        e.failureClass = failureClass
        e.breadcrumb = breadcrumb
        enqueuePerf(e)
    }

    func recordLifecycle(
        stage: String,
        adFormat: String?,
        adUnitId: String?,
        adId: String?,
        serveId: String?,
        durationMs: Int?,
        errorCode: String?,
        trigger: String? = nil,
        cacheSource: String? = nil
    ) {
        var e = newEvent(type: TelemetryType.lifecycle, name: stage)
        e.adFormat = adFormat
        e.adUnitId = adUnitId
        e.adId = adId
        e.serveId = serveId
        e.durationMs = durationMs
        e.errorCode = errorCode
        e.trigger = trigger
        e.cacheSource = cacheSource
        enqueuePerf(e)
    }

    /// Record a handled error. `signature` is the dedup key (e.g. `domain:code`); identical
    /// signatures aggregate with a count instead of flooding the buffer. `message` is truncated;
    /// never pass raw URLs/tokens/PII.
    func recordError(signature: String, errorCode: String? = nil, message: String? = nil, breadcrumb: String? = nil) {
        // Sanitize at the source so secrets are stripped from BOTH the dev log and the payload
        // sent to the backend (exception text can embed URLs/tokens).
        let redacted = redact(message)
        lock.lock()
        guard isEnabled else { lock.unlock(); return }
        if var existing = errorAgg[signature] {
            existing.count = (existing.count ?? 1) + 1
            errorAgg[signature] = existing
        } else if errorAgg.count < maxErrorSignatures {
            var e = newEvent(type: TelemetryType.error, name: signature)
            e.errorCode = errorCode
            e.message = redacted
            e.breadcrumb = breadcrumb
            e.count = 1
            errorAgg[signature] = e
        } else {
            droppedCount += 1
        }
        let logEvent = errorAgg[signature]
        let snapshot = snapshotLocked()
        lock.unlock()
        // Persist off the caller's thread (often the main thread during ad-failure
        // callbacks). The serial queue keeps the write ordered and prompt, so the error
        // still lands quickly before a possible crash without blocking the caller on a
        // JSON encode + UserDefaults write.
        persistAsync(snapshot)
        if let logEvent { debugLog?(formatForLog(logEvent)) }
        Task { [weak self] in await self?.flush() } // eager — an error may precede a crash/kill
    }

    /// Persist + attempt a flush now (e.g. app background).
    func flushNow() {
        persistNow()
        Task { [weak self] in await self?.flush() }
    }

    private func persistNow() {
        // App-background path: snapshot under lock, then block until the write lands
        // (ordered after any pending async writes) so nothing is lost on suspension.
        lock.lock(); let snapshot = snapshotLocked(); lock.unlock()
        persistSync(snapshot)
    }

    // MARK: - Internals

    private func newEvent(type: String, name: String) -> TelemetryEvent {
        TelemetryEvent(type: type, name: name, eventId: UUID().uuidString, timestamp: now())
    }

    /// Compact one-line view for the dev console. Carries only non-sensitive event fields —
    /// never the envelope's apiKey/ppid/advertising-id — and the message is already redacted.
    private func formatForLog(_ e: TelemetryEvent) -> String {
        var s = "\(e.type) \(e.name)"
        if let v = e.statusCode { s += " status=\(v)" }
        if let v = e.durationMs { s += " dur=\(v)ms" }
        if let v = e.failureClass { s += " fail=\(v)" }
        if let v = e.requestBytes { s += " reqB=\(v)" }
        if let v = e.responseBytes { s += " respB=\(v)" }
        if let v = e.success { s += " ok=\(v)" }
        if let v = e.cacheHit { s += " cache=\(v)" }
        if let v = e.adFormat { s += " fmt=\(v)" }
        if let v = e.adUnitId { s += " unit=\(v)" }
        if let v = e.adId { s += " ad=\(v)" }
        if let v = e.serveId { s += " serve=\(v)" }
        if let v = e.errorCode { s += " code=\(v)" }
        if let v = e.count { s += " count=\(v)" }
        if let v = e.message { s += " msg=\(v)" }
        return s
    }

    // Precompiled once (each `.regularExpression` call compiled the pattern fresh on every error).
    private static let redactQueryRegex = try? NSRegularExpression(pattern: "\\?\\S*")
    private static let redactBearerRegex = try? NSRegularExpression(pattern: "(?i)bearer\\s+\\S+")
    private static let redactSecretRegex = try? NSRegularExpression(pattern: "(?i)(api[_-]?key|token|secret|password)([=:])\\S+")

    private static func apply(_ regex: NSRegularExpression?, to s: String, template: String) -> String {
        guard let regex else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Strips likely secrets from free-text (URL query strings, bearer tokens, key/secret
    /// assignments) and caps length. Applied to error messages before they're stored or logged.
    private func redact(_ message: String?) -> String? {
        guard let message else { return nil }
        var r = message
        r = Self.apply(Self.redactQueryRegex, to: r, template: "?…")
        r = Self.apply(Self.redactBearerRegex, to: r, template: "Bearer ***")
        r = Self.apply(Self.redactSecretRegex, to: r, template: "$1$2***")
        return String(r.prefix(maxMessageLen))
    }

    private func enqueuePerf(_ event: TelemetryEvent) {
        lock.lock()
        guard isEnabled, perfSampledIn else { lock.unlock(); return }
        buffer.append(event)
        while buffer.count > maxBuffer { buffer.removeFirst(); droppedCount += 1 }
        let shouldFlush = buffer.count >= flushThreshold
        lock.unlock()
        debugLog?(formatForLog(event))
        if shouldFlush { Task { [weak self] in await self?.flush() } } else { scheduleTimedFlush() }
    }

    /// Buffer + aggregated errors as one list for persistence / recovery. Caller holds `lock`.
    private func snapshotLocked() -> [TelemetryEvent] { buffer + Array(errorAgg.values) }

    /// Persist off the caller's thread (non-blocking), ordered via the serial queue.
    private func persistAsync(_ events: [TelemetryEvent]) {
        persistQueue.async { [store] in store.save(events) }
    }

    /// Persist and block until written, ordered after any pending async writes — used
    /// where durability must complete before returning (app background, flush reconcile).
    private func persistSync(_ events: [TelemetryEvent]) {
        persistQueue.sync { [store] in store.save(events) }
    }

    /// One flush attempt: claim + snapshot + encode (sync, under lock), send (async, off lock),
    /// reconcile (sync, under lock). All `NSLock` use stays in the synchronous helpers.
    private func flush() async {
        guard let batch = beginFlush() else { return }
        let ack: TelemetryAck = batch.body.isEmpty ? .retry : await sender.send(batch.body)
        let outcome = completeFlush(ack: ack, batch: batch)
        if outcome.needRetry { scheduleRetry() } else if outcome.reFlush { await flush() }
    }

    private struct FlushBatch {
        let body: Data
        let pendingBuffer: [TelemetryEvent]
        let pendingErrors: [String: Int]
        let droppedSnap: Int
    }

    /// Claims the flush, snapshots the pending events, and encodes the body — all under `lock`.
    /// Returns `nil` when another flush is in flight or there's nothing to send.
    private func beginFlush() -> FlushBatch? {
        lock.lock(); defer { lock.unlock() }
        if isFlushing || (buffer.isEmpty && errorAgg.isEmpty) { return nil }
        isFlushing = true
        let pendingBuffer = buffer
        let pendingErrorEvents = Array(errorAgg.values)
        var pendingErrors: [String: Int] = [:]
        for e in pendingErrorEvents { pendingErrors[e.name] = e.count ?? 1 }
        let droppedSnap = droppedCount
        var events = pendingBuffer + pendingErrorEvents
        if droppedSnap > 0 {
            var meta = newEvent(type: TelemetryType.meta, name: "dropped")
            meta.count = droppedSnap
            events.append(meta)
        }
        // Stamp wall-clock staleness per event at flush time (copies leave buffered originals intact).
        let stampClock = now()
        events = events.map { e in
            guard e.eventAgeMs == nil else { return e }
            var c = e
            c.eventAgeMs = Int(stampClock - e.timestamp)
            return c
        }
        let body = (try? JSONEncoder().encode(envelopeLocked(events: events))) ?? Data()
        return FlushBatch(body: body, pendingBuffer: pendingBuffer, pendingErrors: pendingErrors, droppedSnap: droppedSnap)
    }

    /// Reconciles the buffer with the send outcome under `lock`; returns whether to re-drain
    /// immediately (accepted) or schedule a backoff retry (transient failure).
    private func completeFlush(ack: TelemetryAck, batch: FlushBatch) -> (reFlush: Bool, needRetry: Bool) {
        lock.lock(); defer { lock.unlock() }
        switch ack {
        case .accepted, .drop:
            let ids = Set(batch.pendingBuffer.map { $0.eventId })
            buffer.removeAll { ids.contains($0.eventId) }
            for (sig, cnt) in batch.pendingErrors {
                if var e = errorAgg[sig] {
                    let remaining = (e.count ?? 0) - cnt
                    if remaining <= 0 { errorAgg[sig] = nil } else { e.count = remaining; errorAgg[sig] = e }
                }
            }
            droppedCount = max(0, droppedCount - batch.droppedSnap)
            retryCount = 0
            persistSync(snapshotLocked())
            isFlushing = false
            // Re-drain leftovers that arrived mid-send: perf once it re-hits the threshold,
            // errors promptly (low-volume, valuable).
            return (buffer.count >= flushThreshold || !errorAgg.isEmpty, false)
        case .retry:
            persistSync(snapshotLocked())
            retryCount += 1
            isFlushing = false
            return (false, true)
        }
    }

    /// Caller holds `lock` (reads `sessionId`).
    private func envelopeLocked(events: [TelemetryEvent]) -> TelemetryEnvelope {
        var env = TelemetryEnvelope(
            sdkVersion: ctx.sdkVersion,
            platform: ctx.platform,
            osVersion: ctx.osVersion,
            deviceModel: ctx.deviceModel,
            hostAppId: ctx.hostAppId,
            devMode: ctx.devMode,
            events: events
        )
        env.sessionId = sessionId
        // Providers are already consent-gated by the facade (re-checked at send time).
        env.primaryUserId = primaryUserIdProvider()
        env.advertisingId = advertisingIdProvider()
        env.connectionType = connectionTypeProvider()
        return env
    }

    private func scheduleTimedFlush() {
        guard claimFlushSchedule() else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.flushInterval * 1_000_000_000))
            self.releaseFlushSchedule()
            await self.flush()
        }
    }

    private func scheduleRetry() {
        let rc = currentRetryCount()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.backoff(rc) * 1_000_000_000))
            await self.flush()
        }
    }

    // Synchronous lock-guarded accessors so the schedulers' async closures never touch NSLock.
    private func claimFlushSchedule() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flushScheduled { return false }
        flushScheduled = true
        return true
    }

    private func releaseFlushSchedule() { lock.lock(); flushScheduled = false; lock.unlock() }

    private func currentRetryCount() -> Int { lock.lock(); defer { lock.unlock() }; return retryCount }
}

/// Exponential backoff for failed telemetry batches: 2s, 4s, 8s … capped at 60s.
func telemetryBackoff(retryCount: Int) -> TimeInterval {
    guard retryCount > 0 else { return 0 }
    return min(pow(2.0, Double(retryCount)), 60.0)
}
