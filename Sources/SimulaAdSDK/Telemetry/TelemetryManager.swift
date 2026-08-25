import Foundation

protocol TelemetryTimeoutScheduling: Sendable {
    func schedule(after timeout: TimeInterval, completion: @escaping @Sendable () -> Void)
}

struct DispatchTelemetryTimeoutScheduler: TelemetryTimeoutScheduling {
    func schedule(after timeout: TimeInterval, completion: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
            completion()
        }
    }
}

/// Static per-process/device context attached to every telemetry batch.
struct TelemetryContext {
    let sdkVersion: String
    let osVersion: String
    let deviceModel: String
    let hostAppId: String
    let devMode: Bool
    var platform: String = "ios"
    // Always-on device diagnostics, resolved once at init (constant per process).
    var manufacturer: String?
    var locale: String?
    var deviceRamMb: Int?
    var buildType: String?
}

/// Flush-time battery snapshot (level 0..1 + charging). Best-effort; nil when unavailable.
struct BatteryInfo: Sendable {
    let level: Double
    let charging: Bool
}

/// Raw main-thread battery reading shared by telemetry and request-header snapshots.
struct DeviceBatterySnapshot: Sendable {
    let level: Float
    let stateRaw: Int

    static func telemetryInfo(from snapshot: DeviceBatterySnapshot?) -> BatteryInfo? {
        guard let snapshot, snapshot.level.isFinite, snapshot.level >= 0 else { return nil }
        return BatteryInfo(
            level: Double(snapshot.level),
            charging: snapshot.stateRaw == 2 || snapshot.stateRaw == 3
        )
    }
}

/// Flush-time carrier/radio snapshot. On iOS `carrier` is nil (CTCarrier deprecated); `radio` is
/// best-effort via CoreTelephony.
struct CarrierInfo: Sendable {
    let carrier: String?
    let radio: String?
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
    private let identityProvider: @Sendable () -> TelemetryIdentity
    // Resolved fresh on each flush (off the UI path). Must be best-effort/non-throwing.
    private let connectionTypeProvider: @Sendable () -> String?
    // Compact diagnostics breadcrumb (memory etc.), sampled on flush. Best-effort.
    private let diagnosticsProvider: @Sendable () -> String?
    // Battery + carrier/radio, resolved fresh on each flush. Best-effort; nil when unavailable.
    private let batteryProvider: @Sendable () -> BatteryInfo?
    private let carrierProvider: @Sendable () -> CarrierInfo?
    private let now: @Sendable () -> TimeInterval
    private let random: @Sendable () -> Double
    private let backoff: @Sendable (Int) -> TimeInterval
    private let timedFlushSleep: @Sendable (TimeInterval) async -> Void
    private let retrySleep: @Sendable (TimeInterval) async -> Void
    private let timeoutScheduler: any TelemetryTimeoutScheduling
    private let launchGate: LaunchSettling
    // Dev-only sink: when set (devMode), each recorded event is logged here (already redacted).
    private let debugLog: (@Sendable (String) -> Void)?
    private let flushThreshold: Int
    private let maxBuffer: Int
    private let maxErrorSignatures: Int
    private let maxMessageLen = 300
    private let flushInterval: TimeInterval
    /// Background durability is best-effort: never block the lifecycle caller indefinitely behind a
    /// stalled UserDefaults implementation or an earlier persistence item.
    private let persistenceWaitTimeout: TimeInterval

    // Serial queue so the UserDefaults encode + write never runs on the caller's thread
    // (often the main thread during ad-failure callbacks). Writes are enqueued while holding
    // `lock`, preserving snapshot order; explicit durability paths wait briefly after releasing it.
    private let persistQueue = DispatchQueue(label: "ad.simula.telemetry.persist", qos: .utility)

    private let lock = NSLock()
    private var buffer: [TelemetryEvent] = []
    private var errorAgg: [String: TelemetryEvent] = [:]
    private var metaAgg: [String: TelemetryEvent] = [:]
    private var droppedCount = 0
    private var isFlushing = false
    private var flushScheduled = false
    private var immediateFlushScheduled = false
    private var immediateFlushIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var retryScheduled = false
    private var retryCount = 0
    private var isEnabled: Bool
    private var sampleRate: Double
    private var perfSampledIn: Bool
    private var recoveryStarted = false
    private var recoveryCompleted = false
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
    // Aux session state for the funnel / time-to-first-ad / experiment, guarded by `lock`.
    private let createdAtMs: TimeInterval
    private var firstAdRecorded = false
    // Per-format funnel counters: [filled, nofill, failed, impressions, clicks]. Reset on emit (deltas).
    private var funnel: [String: [Int]] = [:]
    private var experimentId: String?
    private var variantId: String?

    init(
        ctx: TelemetryContext,
        store: TelemetryStoring,
        sender: TelemetrySending,
        identityProvider: @escaping @Sendable () -> TelemetryIdentity,
        connectionTypeProvider: @escaping @Sendable () -> String? = { nil },
        diagnosticsProvider: @escaping @Sendable () -> String? = { nil },
        batteryProvider: @escaping @Sendable () -> BatteryInfo? = { nil },
        carrierProvider: @escaping @Sendable () -> CarrierInfo? = { nil },
        enabled: Bool = true,
        sampleRate: Double = 1.0,
        // Epoch milliseconds, matching the Kotlin SDK's `System.currentTimeMillis()` timestamps.
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 * 1000 },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        backoff: @escaping @Sendable (Int) -> TimeInterval = { telemetryBackoff(retryCount: $0) },
        timedFlushSleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        retrySleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        timeoutScheduler: any TelemetryTimeoutScheduling = DispatchTelemetryTimeoutScheduler(),
        launchGate: LaunchSettling = ImmediateLaunchSettledGate.shared,
        debugLog: (@Sendable (String) -> Void)? = nil,
        flushThreshold: Int = 20,
        maxBuffer: Int = 200,
        maxErrorSignatures: Int = 50,
        flushInterval: TimeInterval = 30,
        persistenceWaitTimeout: TimeInterval = 0.1
    ) {
        self.ctx = ctx
        self.store = store
        self.sender = sender
        self.identityProvider = identityProvider
        self.connectionTypeProvider = connectionTypeProvider
        self.diagnosticsProvider = diagnosticsProvider
        self.batteryProvider = batteryProvider
        self.carrierProvider = carrierProvider
        self.now = now
        self.createdAtMs = now()
        self.random = random
        self.backoff = backoff
        self.timedFlushSleep = timedFlushSleep ?? Self.defaultSleep
        self.retrySleep = retrySleep ?? Self.defaultSleep
        self.timeoutScheduler = timeoutScheduler
        self.launchGate = launchGate
        self.debugLog = debugLog
        self.flushThreshold = flushThreshold
        self.maxBuffer = maxBuffer
        self.maxErrorSignatures = maxErrorSignatures
        self.flushInterval = flushInterval
        self.persistenceWaitTimeout = max(0, persistenceWaitTimeout)
        let normalizedSampleRate = min(max(sampleRate, 0), 1)
        self.isEnabled = enabled
        self.sampleRate = normalizedSampleRate
        self.perfSampledIn = enabled && random() < normalizedSampleRate
    }

    /// Recover any buffer left by a prior process, then attempt a flush.
    func start() {
        lock.lock()
        if recoveryStarted {
            lock.unlock()
            return
        }
        recoveryStarted = true
        lock.unlock()
        persistQueue.async { [weak self] in self?.recoverOnPersistenceQueue() }
    }

    private func recoverOnPersistenceQueue() {
        let recovered = store.load()
        lock.lock()
        if isEnabled {
            var recoveredBuffer: [TelemetryEvent] = []
            for recoveredEvent in recovered {
                var event = recoveredEvent
                // Pre-sampling-metadata events cannot reveal their historical rate. Admit them
                // under the current effective rate so aggregation and envelope weighting remain
                // internally consistent rather than mixing an unknown rate into a known bucket.
                if event.sampleRate == nil { event.sampleRate = sampleRate }
                if event.type == TelemetryType.error, !event.name.isEmpty {
                    let key = aggregationKey(for: event)
                    if var existing = errorAgg[key] {
                        let existingCount = max(1, existing.count ?? 1)
                        let recoveredCount = max(1, event.count ?? 1)
                        existing.count = existingCount >= Int.max - recoveredCount
                            ? Int.max
                            : existingCount + recoveredCount
                        errorAgg[key] = existing
                    } else {
                        errorAgg[key] = event
                    }
                } else if event.type == TelemetryType.meta, !event.name.isEmpty {
                    mergeCountedEvent(
                        event,
                        into: &metaAgg,
                        key: sampledAggregationKey(event.name, sampleRate: event.sampleRate)
                    )
                } else {
                    recoveredBuffer.append(event)
                }
            }
            buffer.insert(contentsOf: recoveredBuffer, at: 0)
        }
        recoveryCompleted = true
        let waiters = recoveryWaiters
        recoveryWaiters.removeAll()
        let snapshot = snapshotLocked()
        lock.unlock()
        requestImmediateFlush()
        waiters.forEach { $0.resume() }
        store.save(snapshot)
    }

    /// Apply a server-side directive (kill-switch / sampling) from `/session/create`.
    func applyServerConfig(enabled: Bool, sampleRate: Double) {
        lock.lock()
        isEnabled = enabled
        self.sampleRate = min(max(sampleRate, 0), 1)
        perfSampledIn = enabled && random() < self.sampleRate
        if !enabled {
            buffer.removeAll()
            errorAgg.removeAll()
            metaAgg.removeAll()
            droppedCount = 0
            funnel.removeAll()
            retryCount = 0
            if recoveryCompleted { persistAsync([]) }
        }
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

    func recordOperation(
        name: String,
        durationMs: Int,
        success: Bool,
        failureClass: String? = nil,
        breadcrumb: String? = nil,
        timeSinceInitMs: Int? = nil
    ) {
        var e = newEvent(type: TelemetryType.operation, name: name)
        e.durationMs = durationMs
        e.timeSinceInitMs = timeSinceInitMs.map { max(0, $0) }
        e.success = success
        e.failureClass = failureClass
        e.breadcrumb = breadcrumb
        enqueuePerf(e)
    }

    func recordMeta(name: String, count: Int) {
        guard !name.isEmpty, count > 0 else { return }
        lock.lock()
        guard isEnabled else { lock.unlock(); return }
        let key = sampledAggregationKey(name, sampleRate: sampleRate)
        var event = metaAgg[key] ?? newEvent(type: TelemetryType.meta, name: name)
        if event.sampleRate == nil { event.sampleRate = sampleRate }
        let existing = max(0, event.count ?? 0)
        event.count = existing >= Int.max - count ? Int.max : existing + count
        metaAgg[key] = event
        // Duplicate-init counts are process-local until they reach this manager. Persist each
        // aggregate update with the same prompt serial-queue path used by handled errors.
        if recoveryCompleted { persistAsync(snapshotLocked()) }
        lock.unlock()
        scheduleTimedFlush()
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
        cacheSource: String? = nil,
        breadcrumb: String? = nil
    ) {
        recordLifecycle(
            stage: stage,
            adFormat: adFormat,
            adUnitId: adUnitId,
            adId: adId,
            serveId: serveId,
            durationMs: durationMs,
            errorCode: errorCode,
            trigger: trigger,
            cacheSource: cacheSource,
            breadcrumb: breadcrumb,
            interactionId: nil,
            clickSource: nil
        )
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
        cacheSource: String? = nil,
        breadcrumb: String? = nil,
        interactionId: String?,
        clickSource: String?
    ) {
        var e = newEvent(type: TelemetryType.lifecycle, name: stage)
        e.adFormat = adFormat
        e.adUnitId = adUnitId
        e.adId = adId
        e.serveId = serveId
        e.interactionId = interactionId
        e.clickSource = clickSource
        e.durationMs = durationMs
        e.errorCode = errorCode
        e.trigger = trigger
        e.cacheSource = cacheSource
        e.breadcrumb = breadcrumb
        let accumulatedFunnel = accumulate(stage: stage, adFormat: adFormat, cacheSource: cacheSource, errorCode: errorCode)
        if stage == "click" {
            enqueueCritical(e)
        } else {
            enqueuePerf(e)
        }
        // A threshold-triggered send can drain the lifecycle event immediately, but the derived
        // funnel delta still needs its periodic turn even when it is then the only pending data.
        if accumulatedFunnel { scheduleTimedFlush() }
    }

    /// Set the session experiment assignment for the envelope (last assignment wins).
    func setExperiment(experimentId: String?, variantId: String?) {
        if (experimentId?.isEmpty ?? true) && (variantId?.isEmpty ?? true) { return }
        lock.lock()
        self.experimentId = experimentId
        self.variantId = variantId
        lock.unlock()
    }

    /// Fold a lifecycle event into the per-format funnel and detect the first ad load. Unconditional
    /// (not perf-sampled) so the funnel reflects real activity. Cache re-renders are excluded from
    /// `filled`. `recordOperation` for time-to-first-ad is called OFF the lock (NSLock isn't reentrant).
    private func accumulate(stage: String, adFormat: String?, cacheSource: String?, errorCode: String?) -> Bool {
        guard let fmt = adFormat else { return false }
        lock.lock()
        var c = funnel[fmt] ?? [0, 0, 0, 0, 0]
        let accumulated: Bool
        switch stage {
        case "load_success":
            accumulated = cacheSource != "cache"
            if accumulated { c[0] += 1 }
        case "load_fail":
            accumulated = true
            if errorCode == "no_fill" { c[1] += 1 } else { c[2] += 1 }
        case "displayed":
            accumulated = true
            c[3] += 1
        case "click":
            accumulated = true
            c[4] += 1
        default:
            accumulated = false
        }
        funnel[fmt] = c
        let firstAd = stage == "load_success" && !firstAdRecorded
        if firstAd { firstAdRecorded = true }
        let created = createdAtMs
        lock.unlock()
        if firstAd { recordOperation(name: "time_to_first_ad", durationMs: Int(now() - created), success: true) }
        return accumulated
    }

    /// Record a handled error. `signature` is the dedup key (e.g. `domain:code`); identical
    /// signatures aggregate with a count instead of flooding the buffer. `message` is truncated;
    /// never pass raw URLs/tokens/PII.
    func recordError(
        signature: String,
        errorCode: String? = nil,
        message: String? = nil,
        breadcrumb: String? = nil,
        stack: [String]? = nil,
        dedupeDiscriminator: String? = nil
    ) {
        // Sanitize at the source so secrets are stripped from BOTH the dev log and the payload
        // sent to the backend (exception text can embed URLs/tokens).
        let redacted = redact(message)
        let stackFingerprint = stack.flatMap {
            $0.isEmpty ? nil : SimulaMetricKitParser.fingerprint(for: Array($0.prefix(8)))
        }
        let baseAggregateKey = aggregationKey(
            signature: signature,
            discriminator: dedupeDiscriminator ?? stackFingerprint
        )
        lock.lock()
        guard isEnabled else { lock.unlock(); return }
        let aggregateKey = sampledAggregationKey(baseAggregateKey, sampleRate: sampleRate)
        if var existing = errorAgg[aggregateKey] {
            let count = existing.count ?? 1
            existing.count = count < Int.max ? count + 1 : Int.max
            errorAgg[aggregateKey] = existing
        } else if errorAgg.count < maxErrorSignatures {
            var e = newEvent(type: TelemetryType.error, name: signature)
            e.errorCode = errorCode
            e.message = redacted
            e.breadcrumb = breadcrumb
            // Frames are structural (module.symbol / file:line) — no free text, so unlike
            // `message` they carry no URLs/tokens/PII and need no redaction.
            e.stack = stack
            e.count = 1
            e.sampleRate = sampleRate
            errorAgg[aggregateKey] = e
        } else {
            droppedCount += 1
        }
        let logEvent = errorAgg[aggregateKey]
        if recoveryCompleted { persistAsync(snapshotLocked()) }
        lock.unlock()
        // Persist off the caller's thread (often the main thread during ad-failure
        // callbacks). The serial queue keeps the write ordered and prompt, so the error
        // still lands quickly before a possible crash without blocking the caller on a
        // JSON encode + UserDefaults write.
        if let logEvent { debugLog?(formatForLog(logEvent)) }
        requestImmediateFlush() // eager — an error may precede a crash/kill
    }

    /// Persist + attempt a flush now (e.g. app background).
    func flushNow() {
        // Emit the session funnel deltas + a diagnostics sample as part of this (background) flush.
        emitSummaries()
        persistNow()
        requestImmediateFlush()
    }

    private func emitSummaries() {
        emitFunnelSummary()
        emitDiagnostics()
    }

    /// Emit one `funnel_summary` operation per active format (cumulative since the last emit), then
    /// reset — so the backend can sum deltas without double-counting across backgrounds.
    private func emitFunnelSummary() {
        lock.lock()
        let snapshot = funnel
        funnel = [:]
        lock.unlock()
        for (fmt, c) in snapshot {
            let requested = c[0] + c[1] + c[2]
            enqueueOperation(
                name: "funnel_summary",
                durationMs: 0,
                success: true,
                breadcrumb: "fmt=\(fmt);req=\(requested);fill=\(c[0]);nofill=\(c[1]);fail=\(c[2]);imp=\(c[3]);clk=\(c[4])",
                triggersFlush: false
            )
        }
    }

    /// Sample best-effort runtime diagnostics (memory) onto a meta-ish operation event. No-op when
    /// the provider yields nothing.
    private func emitDiagnostics() {
        guard let line = diagnosticsProvider() else { return }
        enqueueOperation(
            name: "diagnostics", durationMs: 0, success: true, breadcrumb: line,
            triggersFlush: false
        )
    }

    private func persistNow() {
        // App-background path: enqueue the snapshot in state-mutation order, then release the
        // lock before waiting for it to land so nothing is lost on suspension.
        lock.lock()
        guard recoveryCompleted else {
            lock.unlock()
            return
        }
        let persistence = persistAsync(snapshotLocked())
        lock.unlock()
        _ = persistence.wait(timeout: .now() + persistenceWaitTimeout)
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

    /// Internal-only error key. Crash/hang records keep their stable wire `name` for dashboards,
    /// while a bounded discriminator prevents different attributed sites/build windows collapsing.
    private func aggregationKey(signature: String, discriminator: String?) -> String {
        guard let discriminator = boundedDedupeToken(discriminator) else { return signature }
        return "\(signature)\u{1f}\(discriminator)"
    }

    /// Rebuild the key after durable recovery from the token persisted in the existing breadcrumb.
    private func aggregationKey(for event: TelemetryEvent) -> String {
        let fields = event.breadcrumb?.split(separator: ";") ?? []
        let dedupe = fields.first { $0.hasPrefix("dedupe=") }
        let fingerprint = fields.first { $0.hasPrefix("fp=") }
        let value: String?
        if let dedupe {
            value = String(dedupe.dropFirst("dedupe=".count))
        } else if let fingerprint {
            value = String(fingerprint.dropFirst("fp=".count))
        } else {
            value = nil
        }
        let stackFingerprint = event.stack.flatMap {
            $0.isEmpty ? nil : SimulaMetricKitParser.fingerprint(for: Array($0.prefix(8)))
        }
        return sampledAggregationKey(
            aggregationKey(signature: event.name, discriminator: value ?? stackFingerprint),
            sampleRate: event.sampleRate
        )
    }

    private func sampledAggregationKey(_ base: String, sampleRate: Double?) -> String {
        guard let sampleRate else { return base }
        return "\(base)\u{1e}sample_rate=\(sampleRate)"
    }

    private func boundedDedupeToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let filtered = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
        let token = String(String.UnicodeScalarView(filtered)).prefix(64)
        return token.isEmpty ? nil : String(token)
    }

    private func enqueuePerf(_ event: TelemetryEvent) {
        enqueuePerf(event, triggersFlush: true)
    }

    private func enqueueOperation(
        name: String,
        durationMs: Int,
        success: Bool,
        breadcrumb: String?,
        triggersFlush: Bool
    ) {
        var event = newEvent(type: TelemetryType.operation, name: name)
        event.durationMs = durationMs
        event.success = success
        event.breadcrumb = breadcrumb
        enqueuePerf(event, triggersFlush: triggersFlush)
    }

    private func enqueuePerf(_ event: TelemetryEvent, triggersFlush: Bool) {
        lock.lock()
        guard isEnabled, perfSampledIn else { lock.unlock(); return }
        var event = event
        event.sampleRate = sampleRate
        buffer.append(event)
        while buffer.count > maxBuffer { buffer.removeFirst(); droppedCount += 1 }
        let shouldFlush = buffer.count >= flushThreshold
        lock.unlock()
        debugLog?(formatForLog(event))
        if triggersFlush {
            if shouldFlush {
                requestImmediateFlush()
            } else {
                scheduleTimedFlush()
            }
        }
    }

    /// Click lifecycle is conversion-critical and must survive an immediate StoreKit/Safari handoff.
    /// It bypasses performance sampling and queues a durable snapshot before returning to the caller.
    private func enqueueCritical(_ event: TelemetryEvent) {
        lock.lock()
        guard isEnabled else { lock.unlock(); return }
        var event = event
        event.sampleRate = sampleRate
        buffer.append(event)
        while buffer.count > maxBuffer { buffer.removeFirst(); droppedCount += 1 }
        if recoveryCompleted { persistAsync(snapshotLocked()) }
        lock.unlock()
        debugLog?(formatForLog(event))
        requestImmediateFlush()
    }

    /// Runs after every persistence item currently queued. A click caller records synchronously,
    /// then uses this barrier before leaving the app, without blocking the UI thread.
    func afterPendingPersistence(
        timeout: TimeInterval,
        completion: @escaping @Sendable () -> Void
    ) {
        let gate = BoundedCompletion(completion)
        persistQueue.async { gate.complete() }
        timeoutScheduler.schedule(after: timeout) { gate.complete() }
    }

    func afterPendingPersistence(_ completion: @escaping @Sendable () -> Void) {
        afterPendingPersistence(timeout: 0.35, completion: completion)
    }

    /// Buffer + aggregated errors as one list for persistence / recovery. Caller holds `lock`.
    private func snapshotLocked() -> [TelemetryEvent] {
        buffer + Array(errorAgg.values) + Array(metaAgg.values)
    }

    private func mergeCountedEvent(
        _ incoming: TelemetryEvent,
        into aggregate: inout [String: TelemetryEvent],
        key: String
    ) {
        guard var existing = aggregate[key] else {
            aggregate[key] = incoming
            return
        }
        let existingCount = max(1, existing.count ?? 1)
        let incomingCount = max(1, incoming.count ?? 1)
        existing.count = existingCount >= Int.max - incomingCount ? Int.max : existingCount + incomingCount
        aggregate[key] = existing
    }

    /// Enqueue while holding `lock` so queue order matches the state transitions that produced
    /// each snapshot. The returned work item lets explicit durability paths wait off the lock.
    @discardableResult
    private func persistAsync(_ events: [TelemetryEvent]) -> DispatchWorkItem {
        let persistence = DispatchWorkItem { [store] in store.save(events) }
        persistQueue.async(execute: persistence)
        return persistence
    }

    /// One flush attempt: claim + snapshot under lock, enrich + encode and send off lock, then
    /// reconcile under lock. The claim remains active while providers run so only one flush is in flight.
    private func flush() async {
        await launchGate.waitUntilSettled()
        guard !Task.isCancelled else { return }
        guard let claim = beginFlush() else { return }
        let batch = buildFlushBatch(from: claim)
        let ack: TelemetryAck = batch.body.isEmpty ? .retry : await sender.send(batch.body)
        let outcome = completeFlush(ack: ack, batch: batch)
        if outcome.needRetry { scheduleRetry() } else if outcome.reFlush { await flush() }
    }

    private struct FlushBatch {
        let body: Data
        let pendingBuffer: [TelemetryEvent]
        /// Internal aggregation key → count. The wire `name` may intentionally be shared by
        /// different crash fingerprints/builds, so it cannot reconcile the dictionary safely.
        let pendingErrors: [String: Int]
        let pendingMeta: [String: CountedEventClaim]
        let droppedSnap: Int
    }

    private struct CountedEventClaim {
        let eventId: String
        let count: Int
    }

    private struct FlushContextSnapshot {
        let experimentId: String?
        let variantId: String?
        let sampleRate: Double
    }

    private struct FlushClaim {
        let pendingBuffer: [TelemetryEvent]
        let pendingErrorEntries: [(key: String, value: TelemetryEvent)]
        let pendingMetaEntries: [(key: String, value: TelemetryEvent)]
        let droppedSnap: Int
        let context: FlushContextSnapshot
    }

    /// Claims one flush and snapshots manager-owned mutable state. No provider or encoder is called
    /// here because either may block or re-enter a record API.
    private func beginFlush() -> FlushClaim? {
        lock.lock(); defer { lock.unlock() }
        if !recoveryCompleted || !isEnabled || retryScheduled || isFlushing
            || (buffer.isEmpty && errorAgg.isEmpty && metaAgg.isEmpty) { return nil }
        isFlushing = true
        return FlushClaim(
            pendingBuffer: buffer,
            pendingErrorEntries: Array(errorAgg),
            pendingMetaEntries: Array(metaAgg),
            droppedSnap: droppedCount,
            context: FlushContextSnapshot(
                experimentId: experimentId,
                variantId: variantId,
                sampleRate: sampleRate
            )
        )
    }

    /// Resolves external state and JSON-encodes entirely outside `lock`. Buffered originals remain
    /// untouched; age stamps and the dropped meta event exist only in this claimed wire batch.
    private func buildFlushBatch(from claim: FlushClaim) -> FlushBatch {
        let pendingBuffer = claim.pendingBuffer
        let pendingErrorEntries = claim.pendingErrorEntries
        let pendingErrorEvents = pendingErrorEntries.map { $0.value }
        let pendingMetaEvents = claim.pendingMetaEntries.map { $0.value }
        var pendingErrors: [String: Int] = [:]
        for (key, event) in pendingErrorEntries { pendingErrors[key] = event.count ?? 1 }
        var pendingMeta: [String: CountedEventClaim] = [:]
        for (key, event) in claim.pendingMetaEntries {
            pendingMeta[key] = CountedEventClaim(eventId: event.eventId, count: event.count ?? 1)
        }
        let droppedSnap = claim.droppedSnap
        var events = pendingBuffer + pendingErrorEvents + pendingMetaEvents
        if droppedSnap > 0 {
            var meta = newEvent(type: TelemetryType.meta, name: "dropped")
            meta.count = droppedSnap
            meta.sampleRate = claim.context.sampleRate
            events.append(meta)
        }
        // Stamp wall-clock staleness per event at flush time (copies leave buffered originals intact).
        let stampClock = now()
        events = events.map { e in
            guard e.eventAgeMs == nil else { return e }
            var c = e
            let age = stampClock - e.timestamp
            if !age.isFinite || age >= Double(Int.max / 2) {
                c.eventAgeMs = Int.max
            } else if age <= 0 {
                c.eventAgeMs = 0
            } else {
                c.eventAgeMs = Int(age)
            }
            return c
        }
        let body = (try? JSONEncoder().encode(buildEnvelope(events: events, context: claim.context))) ?? Data()
        return FlushBatch(
            body: body,
            pendingBuffer: pendingBuffer,
            pendingErrors: pendingErrors,
            pendingMeta: pendingMeta,
            droppedSnap: droppedSnap
        )
    }

    /// Reconciles the buffer with the send outcome under `lock`; returns whether to re-drain
    /// immediately (accepted) or schedule a backoff retry (transient failure).
    private func completeFlush(ack: TelemetryAck, batch: FlushBatch) -> (reFlush: Bool, needRetry: Bool) {
        // Reconcile + enqueue the snapshot under the lock so a newer recording cannot submit its
        // snapshot first. The serial queue performs the actual persistence after the lock is released.
        lock.lock()
        let snapshot: [TelemetryEvent]
        let result: (reFlush: Bool, needRetry: Bool)
        switch ack {
        case .accepted, .drop:
            let ids = Set(batch.pendingBuffer.map { $0.eventId })
            buffer.removeAll { ids.contains($0.eventId) }
            for (key, cnt) in batch.pendingErrors {
                if var e = errorAgg[key] {
                    let remaining = (e.count ?? 0) - cnt
                    if remaining <= 0 { errorAgg[key] = nil } else { e.count = remaining; errorAgg[key] = e }
                }
            }
            for (key, claim) in batch.pendingMeta {
                if var event = metaAgg[key] {
                    let remaining = (event.count ?? 0) - claim.count
                    if remaining <= 0 { metaAgg[key] = nil }
                    else if event.eventId == claim.eventId {
                        var remainder = newEvent(type: TelemetryType.meta, name: event.name)
                        remainder.count = remaining
                        metaAgg[key] = remainder
                    } else {
                        event.count = remaining
                        metaAgg[key] = event
                    }
                }
            }
            droppedCount = max(0, droppedCount - batch.droppedSnap)
            retryCount = 0
            snapshot = snapshotLocked()
            isFlushing = false
            // Re-drain summaries that arrived during this send even below the normal threshold;
            // their caller may have observed this in-flight flush and cannot drain them itself.
            let hasPendingSummary = buffer.contains {
                $0.type == TelemetryType.operation && ($0.name == "funnel_summary" || $0.name == "diagnostics")
            }
            result = (
                buffer.count >= flushThreshold || !errorAgg.isEmpty || !metaAgg.isEmpty || hasPendingSummary,
                false
            )
        case .retry:
            snapshot = snapshotLocked()
            if retryCount < Int.max { retryCount += 1 }
            isFlushing = false
            result = (false, true)
        }
        persistAsync(snapshot)
        lock.unlock()
        return result
    }

    /// Builds a flush envelope from immutable manager state plus fresh external-provider values.
    /// Called without `lock`; providers may safely block briefly or re-enter telemetry recording.
    private func buildEnvelope(events: [TelemetryEvent], context: FlushContextSnapshot) -> TelemetryEnvelope {
        var env = TelemetryEnvelope(
            sdkVersion: ctx.sdkVersion,
            platform: ctx.platform,
            osVersion: ctx.osVersion,
            deviceModel: ctx.deviceModel,
            hostAppId: ctx.hostAppId,
            devMode: ctx.devMode,
            events: events
        )
        // Resolve both identity fields once so an envelope can never mix different sources or
        // different moments from the same source. The facade provider applies live consent.
        let identity = identityProvider()
        env.sessionId = identity.sessionId
        env.primaryUserId = identity.primaryUserId
        env.advertisingId = identity.advertisingId
        env.connectionType = connectionTypeProvider()
        env.experimentId = context.experimentId
        env.variantId = context.variantId
        let eventRates = events.compactMap(\.sampleRate)
        if eventRates.count == events.count, let first = eventRates.first,
           eventRates.allSatisfy({ $0 == first }) {
            env.sampleRate = first
        } else {
            env.sampleRate = nil
        }
        // Always-on device diagnostics: statics from ctx + flush-time battery/carrier providers.
        env.manufacturer = ctx.manufacturer
        env.locale = ctx.locale
        env.deviceRamMb = ctx.deviceRamMb
        env.buildType = ctx.buildType
        let battery = batteryProvider()
        env.batteryLevel = battery?.level
        env.batteryCharging = battery?.charging
        let carrier = carrierProvider()
        env.carrier = carrier?.carrier
        env.radio = carrier?.radio
        return env
    }

    // Task-shape note: every `Task {}` in this SDK keeps its closure body to a single call
    // into a named method, with no `try?`-wrapped awaits inside the closure — affected Swift
    // toolchains miscompile richer shapes into task-teardown aborts in host apps. Before
    // changing any Task closure, read .cursor/skills/swift-concurrency-task-shape/SKILL.md.

    private func scheduleTimedFlush() {
        guard claimFlushSchedule() else { return }
        Task { [weak self] in await self?.timedFlush() }
    }

    /// Timed-flush task body (named method — see the task-shape note above).
    private func timedFlush() async {
        await timedFlushSleep(flushInterval)
        releaseFlushSchedule()
        emitSummaries()
        await flush()
    }

    private func scheduleRetry() {
        lock.lock()
        if retryScheduled || !isEnabled {
            lock.unlock()
            return
        }
        retryScheduled = true
        let rc = retryCount
        lock.unlock()
        Task { [weak self] in await self?.retryFlush(after: rc) }
    }

    /// Retry-flush task body (named method — see the task-shape note above).
    private func retryFlush(after retryCount: Int) async {
        await retrySleep(backoff(retryCount))
        releaseRetrySchedule()
        await flush()
    }

    private func requestImmediateFlush() {
        guard claimImmediateFlushSchedule() else { return }
        Task { [weak self] in await self?.runImmediateFlush() }
    }

    private func runImmediateFlush() async {
        await flush()
        finishImmediateFlush()
    }

    private func claimImmediateFlushSchedule() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if immediateFlushScheduled || retryScheduled || !recoveryCompleted || !isEnabled { return false }
        immediateFlushScheduled = true
        return true
    }

    private func finishImmediateFlush() {
        lock.lock()
        immediateFlushScheduled = false
        let needsAnotherFlush = isEnabled && !retryScheduled && !isFlushing
            && (!errorAgg.isEmpty || !metaAgg.isEmpty || buffer.count >= flushThreshold)
        let waiters = needsAnotherFlush ? [] : immediateFlushIdleWaiters
        if !needsAnotherFlush { immediateFlushIdleWaiters.removeAll() }
        lock.unlock()
        waiters.forEach { $0.resume() }
        if needsAnotherFlush { requestImmediateFlush() }
    }

    func waitForImmediateFlushIdleForTests() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !immediateFlushScheduled {
                lock.unlock()
                continuation.resume()
            } else {
                immediateFlushIdleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func waitForRecoveryForTests() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if recoveryCompleted {
                lock.unlock()
                continuation.resume()
            } else {
                recoveryWaiters.append(continuation)
                lock.unlock()
            }
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

    private func releaseRetrySchedule() { lock.lock(); retryScheduled = false; lock.unlock() }

    private static let defaultSleep: @Sendable (TimeInterval) async -> Void = { delay in
        do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) } catch { return }
    }
}

/// Exponential backoff for failed telemetry batches: 2s, 4s, 8s … capped at 60s.
func telemetryBackoff(retryCount: Int) -> TimeInterval {
    guard retryCount > 0 else { return 0 }
    return min(pow(2.0, Double(retryCount)), 60.0)
}
