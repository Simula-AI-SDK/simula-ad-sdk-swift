import Foundation

/// IPv4 resolution beacon.
///
/// WHY: most device IPs the SDK sees are IPv6, but our identity-resolution partners (5x5 /
/// LiveRamp) match on IPv4. Firing a lightweight GET to a host configured with ONLY A records
/// (no AAAA) forces the OS to resolve over IPv4, so the backend captures the device's public
/// IPv4 from that request and links it to the session that loads ads.
///
/// Replaces the stop-gap that lived in the React Native wrapper's JS layer. Living natively it
/// can carry the server session id (`sid`), which the JS layer could never reach — the backend
/// resolves the capture by `sid` first and falls back to `ppid` only when `sid` is absent.
///
/// SAFETY: fire-and-forget. Never throws, never blocks init or session creation, and no-ops
/// when no beacon URL is configured. It is intentionally NOT consent-gated — parity with the
/// prior RN implementation (ensure this is covered by privacy policy / publisher agreements).
///
/// BACKEND CONTRACT: a GET to `defaultURLString` with query params:
///   k    — apiKey
///   sid  — server session id   (omitted if session creation failed)
///   ppid — primary user id     (omitted if absent)
///   did  — native X-Device-Id  (omitted if unavailable)
///   p    — platform ("ios" from this SDK)
///   r    — reason ("init" | "ppid_update")
///   t    — client timestamp in ms (cache-buster)
/// The endpoint reads the client IPv4 from `x-forwarded-for` and stores it keyed by `sid`,
/// falling back to `ppid` (then `did`) when absent. The response body is ignored.
///
/// DEDUP: one successful capture per (apiKey, sessionId, ppid) identity, with in-flight
/// coalescing; failures stay retryable. A new session id (e.g. a consent-driven resync) or a
/// new ppid is a new identity and re-fires. `onLogout()` clears the bookkeeping so a re-login —
/// even with the same ppid — gets a fresh capture for the new session.
///
/// `@unchecked Sendable` is safe: all mutable state is guarded by `lock`, and the injected
/// collaborators are `@Sendable` closures.
final class Ipv4Beacon: @unchecked Sendable {

    static let shared = Ipv4Beacon(launchGate: LaunchSettledGate.shared)

    /// The A-record-only host to beacon. MUST be a domain configured with ONLY A records (no
    /// AAAA) so the request is forced to resolve over IPv4. Empty = DISABLED.
    static let defaultURLString = "https://ip4.simula.ad/px"

    static let reasonInit = "init"
    static let reasonPpidUpdate = "ppid_update"

    private let urlString: String
    private let send: @Sendable (URL) async -> Bool
    private let deviceId: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private let launchGate: LaunchSettling

    private let lock = NSLock()
    /// Identities whose beacon has SUCCESSFULLY fired this process (failures stay retryable).
    private var captured = Set<String>()
    /// Identities with a beacon in flight — claimed under `lock` so parallel fires coalesce.
    private var inFlight = Set<String>()
    /// Fire tasks that have been launched but may still be waiting on the launch gate. Kept
    /// separately from `inFlight`, which logout intentionally clears before those tasks resume.
    private var runningTasks = 0
    /// Bumped on every `onLogout()`. A fire captures the generation it started with and
    /// re-checks it before recording; a mismatch means the session moved on mid-flight, so the
    /// completion is discarded instead of resurrecting stale dedup state after a logout reset.
    private var generation = 0

    /// Collaborators are injectable so tests run with fakes — no network, no wall clock.
    init(
        urlString: String = Ipv4Beacon.defaultURLString,
        send: @escaping @Sendable (URL) async -> Bool = Ipv4Beacon.defaultSend,
        deviceId: @escaping @Sendable () -> String? = { SimulaDeviceId.value },
        now: @escaping @Sendable () -> Date = { Date() },
        launchGate: LaunchSettling = ImmediateLaunchSettledGate.shared
    ) {
        self.urlString = urlString
        self.send = send
        self.deviceId = deviceId
        self.now = now
        self.launchGate = launchGate
    }

    /// Fire (fire-and-forget) for the given identity. Deduped per (apiKey, sessionId, ppid) —
    /// see the type doc. Never throws.
    func fire(apiKey: String, sessionId: String?, ppid: String?, reason: String) {
        let base = urlString.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !apiKey.isEmpty else { return }
        guard let url = Self.buildURL(
            base: base,
            apiKey: apiKey,
            sessionId: sessionId,
            ppid: ppid,
            deviceId: deviceId(),
            reason: reason,
            timestamp: now()
        ) else { return }

        // NUL-joined with a distinct nil marker (not naive concatenation) so distinct
        // identities can never collide onto the same key.
        let key = [apiKey, sessionId ?? "\u{1}nil", ppid ?? "\u{1}nil"].joined(separator: "\u{0}")

        lock.lock()
        if captured.contains(key) || inFlight.contains(key) {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        runningTasks += 1
        let gen = generation
        lock.unlock()

        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        Task { [weak self] in await self?.runFire(key: key, generation: gen, url: url) }
    }

    /// Logout ends the capture session: clear the dedup bookkeeping (and invalidate anything
    /// still in flight via the generation bump) so a later re-login — even with the same ppid —
    /// runs a fresh capture instead of being skipped by stale state.
    func onLogout() {
        lock.lock()
        generation += 1
        captured.removeAll()
        inFlight.removeAll()
        lock.unlock()
    }

    /// Fire task body (named method — see the task-shape note in TelemetryManager).
    private func runFire(key: String, generation gen: Int, url: URL) async {
        await launchGate.waitUntilSettled()
        guard isStillInFlight(key: key, generation: gen) else {
            finishTask()
            return
        }
        let ok = await send(url)
        complete(key: key, generation: gen, ok: ok)
    }

    private func isStillInFlight(key: String, generation gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen == generation && inFlight.contains(key)
    }

    /// Synchronous (no `await`) so `NSLock` use stays out of async contexts (Swift 6) — same
    /// pattern as TelemetryManager.recover().
    private func complete(key: String, generation gen: Int, ok: Bool) {
        lock.lock()
        defer { lock.unlock() }
        runningTasks = max(0, runningTasks - 1)
        // A logout while in flight already cleared this key; bail instead of resurrecting a
        // stale captured/in-flight entry into the new session.
        if gen != generation { return }
        inFlight.remove(key)
        if ok { captured.insert(key) }
    }

    private func finishTask() {
        lock.lock()
        runningTasks = max(0, runningTasks - 1)
        lock.unlock()
    }

    /// True when no beacon is in flight. Test-only synchronization hook.
    var isIdleForTests: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.isEmpty && runningTasks == 0
    }

    /// Pure URL construction — exposed for tests. Blank sid/ppid/did are omitted.
    static func buildURL(
        base: String,
        apiKey: String,
        sessionId: String?,
        ppid: String?,
        deviceId: String?,
        reason: String,
        timestamp: Date
    ) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "k", value: apiKey))
        if let sessionId, !sessionId.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "sid", value: sessionId))
        }
        if let ppid, !ppid.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "ppid", value: ppid))
        }
        if let deviceId, !deviceId.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "did", value: deviceId))
        }
        items.append(URLQueryItem(name: "p", value: "ios"))
        items.append(URLQueryItem(name: "r", value: reason))
        items.append(URLQueryItem(name: "t", value: String(Int64(timestamp.timeIntervalSince1970 * 1000))))
        components.queryItems = items
        return components.url
    }

    /// Dedicated session for the beacon (never `URLSession.shared` — SDK hard rule). Ephemeral:
    /// a pixel needs no cookie/cache/credential storage. Timeouts bounded like the CTA / redirect
    /// sessions, so a stalled connection can't hold resources for the 7-day system default.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    /// Production sender: a short-timeout GET whose response body is ignored. Returns whether
    /// the beacon landed (2xx). Explicit do/catch (never `try?` around an `await` — see the
    /// task-shape note in TelemetryManager); any transport failure is a plain `false` so the
    /// identity stays retryable.
    @Sendable
    static func defaultSend(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
