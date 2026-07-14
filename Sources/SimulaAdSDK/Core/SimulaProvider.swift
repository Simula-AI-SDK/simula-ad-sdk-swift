import Foundation
import SwiftUI
import Combine
#if os(iOS)
import AppTrackingTransparency
#endif

// MARK: - SimulaProvider

/// The central state manager for the Simula Ad SDK.
/// Translates the React Context pattern from SimulaProvider.tsx.
///
/// Usage:
/// ```swift
/// SimulaProviderView(apiKey: "your-key") {
///     ContentView()
/// }
/// ```
///
/// Inside child views:
/// ```swift
/// @EnvironmentObject var simula: SimulaProvider
/// ```
public final class SimulaProvider: ObservableObject {
    // MARK: - Configuration (set once at init)

    /// The API key for authenticating with Simula services
    public let apiKey: String

    /// Whether the SDK is in development mode
    public let devMode: Bool

    /// Optional primary user identifier. Mutable mid-session via `updatePrimaryUserID(_:)`; stored in a
    /// thread-safe box so the telemetry flush (a background task) reads it without a data race.
    public var primaryUserID: String? { ppidStore.current }
    private let ppidStore: PPIDStore

    /// Legacy coarse consent flag. When false, suppresses collection of PII.
    /// Retained as a convenience alias for `privacyConfig.hasPrivacyConsent`.
    public let hasPrivacyConsent: Bool

    /// Resolved privacy / consent configuration. Pushed into the process-wide
    /// `SimulaPrivacy` store, which also auto-reads IAB-standard CMP keys.
    public let privacyConfig: SimulaPrivacyConfig

    /// Native-ad targeting context attached to every `POST /load/native` under this provider.
    /// Set at init and replaceable wholesale at runtime via `updateContext(_:)` (PRD). Read on the
    /// main thread by `NativeAdSlot` / the preload path.
    public private(set) var adContext: SimulaAdContext?

    // MARK: - Session State

    /// The server session ID, set after successful session creation
    @Published public private(set) var sessionId: String? {
        didSet { Telemetry.shared.setSessionId(sessionId) } // correlate telemetry to the session
    }

    /// The in-flight session-creation task, if any. Lets concurrent callers
    /// coalesce onto a single request instead of each firing their own.
    /// Touched only from `@MainActor` methods.
    private var sessionTask: Task<String?, Never>?

    /// Monotonic tag bumped on every session creation. A creation task captures its generation and
    /// only publishes its (sessionId, sessionUserID) pair if that generation is still current — so a
    /// creation abandoned by `resyncSession` (consent change) can't clobber the newer session when it
    /// finishes late with a now-stale privacy snapshot / ppid. Touched only on the main actor.
    private var sessionGeneration = 0

    /// The PPID the current *server* session actually represents — set to the value the session was
    /// created with, and advanced only when a `PATCH …/ppid` succeeds. This can lag `primaryUserID`
    /// after a mid-session login/logout/switch (the local id updates immediately; the server session
    /// reconciles asynchronously, and a logout can't be pushed at all). Consumers that must evaluate
    /// for a specific identity (e.g. the frequency-cap check) compare the two and drop the session id
    /// when they diverge. Touched only on the main actor, like `sessionTask`.
    private(set) var sessionUserID: String?

    /// Serializes PPID reconciliation: each `reconcileServerPpid()` chains after this task so PATCHes
    /// run strictly one at a time (the server applies them in order, and no out-of-order PATCH can
    /// leave `sessionUserID` disagreeing with the real server identity). Touched only on the main actor.
    private var ppidSyncTask: Task<Void, Never>?

    // MARK: - Ad Caching Infrastructure (matching Flutter/React SDK)
    // Host-facing legacy cache API (getCachedAd/cacheAd/…). No internal callers, but a host using it
    // across many distinct slots would grow these without bound — so each is a size-capped store.

    /// Cache of fetched ads keyed by "slot:position"
    private var adCache = BoundedStore<AdData>(maxEntries: 64)

    /// Cache of measured heights keyed by "slot:position"
    private var heightCache = BoundedStore<CGFloat>(maxEntries: 64)

    /// "slot:position" keys that returned no-fill
    private var noFillCache = BoundedStore<Bool>(maxEntries: 64)

    // MARK: - Internal

    private let api: SimulaAPI

    /// Subscriptions to the consent store (re-sync session on CMP refresh).
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    public init(
        apiKey: String,
        devMode: Bool = false,
        primaryUserID: String? = nil,
        hasPrivacyConsent: Bool = true,
        privacy: SimulaPrivacyConfig? = nil,
        telemetryEnabled: Bool = true,
        adContext: SimulaAdContext? = nil
    ) {
        // Validate at init (matches React's validateSimulaProviderProps call)
        do {
            try validateSimulaProviderProps(apiKey: apiKey)
        } catch {
            // In React, this throws and prevents render. In Swift, we assert in debug.
            assertionFailure("[SimulaSDK] \(error.localizedDescription)")
        }

        self.apiKey = apiKey
        self.devMode = devMode
        self.ppidStore = PPIDStore(primaryUserID)
        self.hasPrivacyConsent = hasPrivacyConsent
        self.adContext = adContext

        // When an explicit `privacy` config is given it wins; otherwise the legacy
        // `hasPrivacyConsent` flag seeds the config so existing call sites behave
        // exactly as before.
        var resolved = privacy ?? SimulaPrivacyConfig()
        if privacy == nil { resolved.hasPrivacyConsent = hasPrivacyConsent }
        self.privacyConfig = resolved
        self.api = SimulaAPI()

        // Start the connection-type monitor before the first request so `X-Connection-Type` is
        // live from `session/create` onward. Idempotent — safe if a host recreates the provider.
        // Independent of `telemetryEnabled`: the header is a first-party-request signal, not a
        // telemetry one.
        SimulaConnectionType.shared.start()

        // Start device-signal collection so the `X-*` device headers are populated before the first
        // request. Idempotent and independent of telemetry, like the connection-type monitor.
        SimulaDeviceSignals.shared.start()

        // Install telemetry before the first request so the /session/create call (and every
        // subsequent SDK request) is captured. First call wins, so a re-created provider
        // doesn't churn it; the facade re-gates PII on the live consent snapshot.
        Telemetry.shared.initialize(
            apiKey: apiKey,
            devMode: devMode,
            enabled: telemetryEnabled,
            // Read the PPID live so a mid-session updatePrimaryUserID is honored; the box is Sendable.
            primaryUserIDProvider: { [ppidStore = self.ppidStore] in ppidStore.current }
        )

        // Capture uncaught SDK crashes (+ Swift traps / signals / hangs via MetricKit on iOS 14+)
        // into telemetry. Gated by the same telemetry opt-out; chains to the host's existing
        // exception handler and only reports crashes that involve SDK code. Installed right after the
        // pipeline so the replay of any prior-process crash has somewhere to land.
        SimulaCrashGuard.shared.install(enabled: telemetryEnabled)

        // Feed the process-wide store, then re-sync the session whenever consent
        // changes (host CMP refresh or ATT result) so the backend sees current signals.
        SimulaPrivacy.shared.apply(resolved)
        SimulaPrivacy.shared.$snapshot
            .dropFirst()
            .removeDuplicates()
            // CMPs write the IAB keys in a burst; coalesce so a settled consent
            // state triggers exactly one /session/create instead of a race.
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                // Single-call task closure — see the task-shape note in TelemetryManager.
                Task { @MainActor in await self?.handleConsentChange() }
            }
            .store(in: &cancellables)
    }

    /// Task body for the consent-change reaction (named method — see the task-shape note in
    /// TelemetryManager): drop consent-scoped web views, then re-sync the session.
    @MainActor
    private func handleConsentChange() async {
        #if os(iOS)
        // The storage policy may have flipped (TCF Purpose 1 / GDPR); drop prewarmed web
        // views so the next game/ad is built with a data store matching the new consent.
        // (`acquire` also guards this lazily; this just frees stale views proactively.)
        WebViewPool.shared.clear()
        // Retained native-ad views baked the previous data store in at creation too: destroy the
        // idle ones now and flag on-screen ones so they're destroyed on scroll-out instead of
        // being retained/reattached under stale consent.
        NativeAdWebViewStore.shared.invalidateAllSessions()
        #endif
        await resyncSession()
    }

    // MARK: - Session Management

    /// Completion-based variant of `createSession` for callers that must not create Swift
    /// Concurrency tasks themselves — e.g. the React Native bridge, whose source is compiled by
    /// host toolchains affected by the task-teardown miscompile (see the
    /// swift-concurrency-task-shape skill). The task lives INSIDE the SDK binary. `completion`
    /// fires on the main actor once the session is ready (or failed — same semantics as awaiting
    /// `createSession()`).
    @MainActor
    public func createSession(completion: @escaping @MainActor () -> Void) {
        // Single-call task closure into a named method — see the swift-concurrency-task-shape skill.
        Task { await self.runCreateSession(completion: completion) }
    }

    /// Task body for the completion-based `createSession` (named method — see the skill).
    @MainActor
    private func runCreateSession(completion: @escaping @MainActor () -> Void) async {
        await ensureSession()
        completion()
    }

    /// Creates a session with the server. Called automatically by `SimulaProviderView`.
    /// Translates the `useEffect(() => { ensureSession() }, [...])` from SimulaProvider.tsx.
    @MainActor
    public func createSession() async {
        _ = await ensureSession()
    }

    /// Returns a valid session id, creating one on demand if needed.
    ///
    /// - Returns the existing id immediately if a session already exists.
    /// - Coalesces concurrent callers onto a single in-flight request, so a
    ///   fast game tap during launch awaits the same session creation instead
    ///   of racing it (previously this surfaced as "Session invalid").
    /// - Retries on the next call after a failed attempt (the failed task is
    ///   cleared), so a transient network error at launch no longer disables
    ///   minigames for the whole app session.
    @MainActor
    @discardableResult
    public func ensureSession() async -> String? {
        // Loop so a caller that coalesces onto (or starts) a creation which is then superseded by a
        // resync retries onto the replacement, instead of returning a premature nil while a session
        // is still being created.
        while true {
            if let sessionId, !sessionId.isEmpty { return sessionId }

            // Await the in-flight creation — an existing one (coalesce) or a fresh one we start.
            // `awaitedGeneration` is that creation's generation: sessionTask and sessionGeneration are
            // only ever set together (in startSessionCreation / resyncSession, synchronously), so
            // reading them here with no intervening await yields a consistent pair.
            let taskToAwait: Task<String?, Never>
            let awaitedGeneration: Int
            if let existing = sessionTask {
                taskToAwait = existing
                awaitedGeneration = sessionGeneration
            } else {
                let created = startSessionCreation()
                taskToAwait = created.task
                awaitedGeneration = created.generation
            }

            _ = await taskToAwait.value

            // Superseded mid-await (a resync bumped the generation and started a replacement): retry
            // so we await/observe the replacement rather than this abandoned creation's nil.
            if sessionGeneration != awaitedGeneration { continue }

            // The creation we awaited is still current and has settled. Clear the handle so a failed
            // attempt is retried by the NEXT call, and return whatever it published (a genuine nil on
            // failure is never re-created within this same call).
            sessionTask = nil
            return sessionId
        }
    }

    /// Starts a session-creation task (bumps the generation and stores the in-flight handle) and
    /// returns it with its generation. The task publishes the `(sessionId, sessionUserID)` pair
    /// itself — guarded by the generation so a creation superseded by a resync can't overwrite the
    /// current session — so every awaiter observes consistent state the moment it resolves.
    @MainActor
    private func startSessionCreation() -> (task: Task<String?, Never>, generation: Int) {
        let snapshot = SimulaPrivacy.shared.currentSnapshot
        // Capture the ppid this session is created with so `sessionUserID` tracks the server
        // session's true identity (used to detect a stale session after a mid-session change).
        // Deliberately read at scheduling (not when the task runs): the created session represents
        // THIS identity, and `createAndPublishSession` reconciles any change that lands mid-flight.
        let ppidAtCreation = ppidStore.current
        sessionGeneration &+= 1
        let generation = sessionGeneration
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        let task = Task<String?, Never> { @MainActor [weak self] in await self?.createAndPublishSession(generation: generation, ppidAtCreation: ppidAtCreation, snapshot: snapshot) ?? nil }
        sessionTask = task
        return (task, generation)
    }

    /// Session-creation task body (named method — see the task-shape note in TelemetryManager):
    /// runs the network call + telemetry (`runSessionCreation`), then publishes the
    /// (sessionId, sessionUserID) pair INSIDE the task — so every awaiter, the creating caller AND
    /// any coalesced waiters, observes a consistent pair the moment `task.value` resolves. Guarded
    /// on the generation: a creation superseded by a resync must NOT overwrite the current session
    /// with its stale pair.
    @MainActor
    private func createAndPublishSession(
        generation: Int,
        ppidAtCreation: String?,
        snapshot: ConsentSnapshot
    ) async -> String? {
        let resolved = await Self.runSessionCreation(
            api: api, apiKey: apiKey, devMode: devMode, ppid: ppidAtCreation, snapshot: snapshot
        )
        if let resolved, sessionGeneration == generation {
            sessionId = resolved
            sessionUserID = ppidAtCreation
            // A login/switch that fired WHILE this session was being created couldn't reconcile
            // (sessionId was still nil when updatePrimaryUserID ran, so reconcileServerPpid
            // no-oped). Now that the session exists, drive it to the current ppid if it diverged
            // from the one it was created with — otherwise the server session would stay on the
            // old ppid until the host happened to call updatePrimaryUserID again.
            if ppidStore.current != ppidAtCreation {
                reconcileServerPpid()
            }
        }
        if sessionGeneration == generation, ppidStore.current == ppidAtCreation {
            // IPv4 capture for this session (fire-and-forget, deduped per identity). Fired even
            // when creation failed (sid omitted) so the backend can still key on ppid/did —
            // parity with the RN-layer beacon this replaces. Skipped when superseded:
            //   • by a resync (generation moved on) — the replacement creation fires for its
            //     own (current) session id;
            //   • by a mid-creation login/switch/logout (ppidStore.current diverged from
            //     ppidAtCreation) — beaconing the stale ppid would misattribute the capture;
            //     a login/switch is instead captured by the reconcile convergence beacon once
            //     the server session actually represents the new user, and a logout must not
            //     re-enter the dedup memory it just reset.
            Ipv4Beacon.shared.fire(
                apiKey: apiKey, sessionId: resolved, ppid: ppidAtCreation, reason: Ipv4Beacon.reasonInit
            )
        }
        return resolved
    }

    /// Session-creation task body (named method — see the task-shape note in TelemetryManager).
    /// Emits session_created/session_failed once per creation attempt (callers coalesce onto the
    /// single task). Best-effort telemetry; never affects session creation. Static so the task
    /// keeps the prior capture semantics (no strong `self`). `@MainActor` preserves the closure's
    /// inherited isolation.
    @MainActor
    private static func runSessionCreation(
        api: SimulaAPI,
        apiKey: String,
        devMode: Bool,
        ppid: String?,
        snapshot: ConsentSnapshot
    ) async -> String? {
        let startNanos = DispatchTime.now().uptimeNanoseconds
        func durationMs() -> Int { Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000) }
        do {
            let id = try await api.createSession(
                apiKey: apiKey,
                devMode: devMode,
                primaryUserID: ppid,
                privacy: snapshot
            )
            let resolved = (id?.isEmpty == false) ? id : nil
            if resolved != nil {
                Telemetry.shared.recordOperation(name: "session_created", durationMs: durationMs(), success: true)
            } else {
                Telemetry.shared.recordOperation(name: "session_failed", durationMs: durationMs(), success: false, failureClass: "no_session")
            }
            return resolved
        } catch {
            Telemetry.shared.recordOperation(name: "session_failed", durationMs: durationMs(), success: false, failureClass: "no_session")
            return nil
        }
    }

    /// Invalidates the current session and recreates it so the backend sees the
    /// latest consent signals. Triggered when the consent store changes.
    @MainActor
    private func resyncSession() async {
        sessionId = nil
        // Clear the tracked identity together with the id it belonged to, so a frequency-cap check
        // during the resync window never pairs the (now-invalidated) old id with a stale identity —
        // the recreated session sets both again atomically.
        sessionUserID = nil
        // Invalidate any in-flight creation UP FRONT (bump before cancel): a task already past its
        // network call would otherwise still satisfy its generation guard and publish a session built
        // from the now-stale consent snapshot. Bumping first guarantees that guard fails. Cancelling
        // additionally aborts the wasted request; `ensureSession` below starts a fresh creation.
        sessionGeneration &+= 1
        sessionTask?.cancel()
        sessionTask = nil
        await ensureSession()
    }

    // MARK: - Consent Updates

    /// Replace the privacy configuration at runtime (e.g. after the host CMP
    /// gathers or refreshes consent). Forwarded to the process-wide store; the
    /// session re-syncs automatically.
    public func updateConsent(_ config: SimulaPrivacyConfig) {
        SimulaPrivacy.shared.apply(config)
    }

    // MARK: - Native Ad Context

    /// Replace the native-ad targeting context at runtime (e.g. when the feed category changes).
    /// A full replacement, not a merge (PRD); all subsequent `POST /load/native` calls use the new
    /// value. Ads already preloaded under the old context are unaffected.
    public func updateContext(_ context: SimulaAdContext?) {
        adContext = context
    }

    // MARK: - Primary User ID (PPID)

    /// Update the primary user id (PPID) mid-session — after a login, a logout, or a first login that
    /// happened only after the session was created. Mirrors `updateContext`. A nil/empty id clears the
    /// PPID (logout).
    ///
    /// Effects: (1) the value the next `session/create` carries is updated; (2) telemetry reports the
    /// new value; (3) when a session already exists, the live session is PATCHed server-side. Clearing
    /// (nil) updates local + telemetry state only — the backend's `PATCH …/ppid/{ppid}` path can't
    /// express an empty id. The network call is best-effort.
    @MainActor
    public func updatePrimaryUserID(_ id: String?) {
        let normalized = (id?.isEmpty == false) ? id : nil
        ppidStore.set(normalized)
        // Reconcile the live server session toward the new id (serialized + single-flight). No-op
        // when there's no session yet (the next createSession carries the value) or on logout (which
        // can't be pushed server-side; the session is then treated as stale).
        reconcileServerPpid()
        // IPv4 capture on a login/switch fires from INSIDE the reconcile loop, once the server
        // session has converged to the new ppid — so the sid it carries (the backend keys the
        // capture by sid first) genuinely represents the new user, never the previous one the
        // session still holds pre-PATCH (the same stale-identity gate consistentSessionId
        // applies for the frequency-cap check). A login with no session yet is covered by the
        // session-creation init beacon. Only the logout dedup reset lives here.
        if normalized == nil {
            Ipv4Beacon.shared.onLogout()
        }
    }

    /// Drive the server session's PPID toward the current `ppidStore` value and, on success, advance
    /// `sessionUserID` to match — but only while that value is still the desired identity. Each call
    /// chains after the previous (`ppidSyncTask`), so reconciles run strictly serially: at most one
    /// PATCH is in flight, the server applies them in order, and a late/out-of-order PATCH can never
    /// mark an identity the server didn't converge to. Rapid switches collapse (a chained run finds
    /// the value already synced and no-ops). A logout (nil) or not-yet-created session is a
    /// deliberate no-op that leaves `sessionUserID` stale, so a frequency-cap check drops the
    /// now-mismatched session id rather than trusting it.
    @MainActor
    private func reconcileServerPpid() {
        let previous = ppidSyncTask
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        ppidSyncTask = Task { @MainActor [weak self] in await self?.runPpidReconcile(after: previous) }
    }

    /// PPID-reconcile task body (named method — see the task-shape note in TelemetryManager):
    /// waits for the previous reconcile (strict serialization), then drives the server session's
    /// PPID toward the current `ppidStore` value.
    @MainActor
    private func runPpidReconcile(after previous: Task<Void, Never>?) async {
        _ = await previous?.value
        while true {
            let target = ppidStore.current
            guard let target, let sid = sessionId, !sid.isEmpty else { break }
            if target == sessionUserID {
                // Converged: the server session now genuinely represents `target`. Fire the
                // IPv4 capture HERE — not from updatePrimaryUserID — so the sid it carries
                // (the backend keys the capture by sid first) no longer represents the
                // PREVIOUS user (pre-PATCH it still does; the same stale-identity concern
                // consistentSessionId guards for the frequency-cap check). `target` is the
                // live ppid: it was read this iteration with no suspension since, and this
                // whole method is main-actor-isolated, so a logout can't interleave between
                // the read and this fire. Deduped per (apiKey, sid, ppid) inside the beacon,
                // so the steady-state reconcile is free; a post-logout re-login with the same
                // ppid lands here without needing a PATCH and re-captures because the logout
                // cleared the dedup memory.
                Ipv4Beacon.shared.fire(
                    apiKey: apiKey, sessionId: sid, ppid: target, reason: Ipv4Beacon.reasonPpidUpdate
                )
                break
            }
            let ok = await api.updatePpid(apiKey: apiKey, sessionId: sid, ppid: target)
            if !ok { break }
            // The PATCH just moved server session `sid` to `target` (reconciles are serialized, so
            // no other PATCH interleaves). Record that truth even if the desired identity has
            // already moved on — so sessionUserID always reflects the server's real state and can
            // never falsely match a newer ppid — but ONLY while `sid` is still the current session.
            // A consent resync that replaced the session mid-PATCH makes this result stale: it
            // describes the OLD session, and writing it would pair the NEW sessionId with an
            // identity its server session never held — falsely satisfying the convergence check
            // above (misattributing the IPv4 capture and skipping the PATCH the new session still
            // needs) and poisoning the consistentSessionId frequency-cap gate. Discarding it is
            // safe: the next iteration re-reads the live sessionId/sessionUserID pair and
            // re-PATCHes the replacement session if it hasn't converged.
            if sessionId == sid {
                sessionUserID = target
            }
        }
    }

    /// Merge a partial consent update at runtime. Only the supplied fields change.
    public func updateConsent(
        hasPrivacyConsent: Bool? = nil,
        tcString: String? = nil,
        uspString: String? = nil,
        gppString: String? = nil,
        gppSid: String? = nil,
        gdprApplies: Bool? = nil,
        tcfPurpose1Consent: Bool? = nil,
        coppaApplies: Bool? = nil,
        enableAdvertisingId: Bool? = nil
    ) {
        SimulaPrivacy.shared.update(
            hasPrivacyConsent: hasPrivacyConsent,
            tcString: tcString,
            uspString: uspString,
            gppString: gppString,
            gppSid: gppSid,
            gdprApplies: gdprApplies,
            tcfPurpose1Consent: tcfPurpose1Consent,
            coppaApplies: coppaApplies,
            enableAdvertisingId: enableAdvertisingId
        )
    }

    /// Clears the named explicit consent overrides (the store then falls back to any
    /// auto-read IAB value). Use to *remove* a signal you previously set — `update`
    /// can only change or leave fields, not clear them.
    public func clearConsent(
        tcString: Bool = false,
        uspString: Bool = false,
        gppString: Bool = false,
        gppSid: Bool = false,
        gdprApplies: Bool = false,
        tcfPurpose1Consent: Bool = false
    ) {
        SimulaPrivacy.shared.clearConsent(
            tcString: tcString,
            uspString: uspString,
            gppString: gppString,
            gppSid: gppSid,
            gdprApplies: gdprApplies,
            tcfPurpose1Consent: tcfPurpose1Consent
        )
    }

    #if os(iOS)
    /// Presents the App Tracking Transparency prompt and, when advertising-id
    /// collection is enabled (and COPPA does not apply), begins forwarding the
    /// IDFA on authorization. Call from the host's launch flow or a post-CMP
    /// callback. Requires `NSUserTrackingUsageDescription` in the app's Info.plist.
    @MainActor
    @discardableResult
    public func requestTrackingAuthorization() async -> ATTrackingManager.AuthorizationStatus {
        await SimulaPrivacy.shared.requestTrackingAuthorization()
    }
    #endif

    // MARK: - Cache Key Helper

    /// Creates a cache key from slot and position (translates `getCacheKey` from SimulaProvider.tsx)
    private func cacheKey(slot: String, position: Int) -> String {
        "\(slot):\(position)"
    }

    // MARK: - Ad Cache Methods

    /// Get cached ad for a slot/position (translates `getCachedAd`)
    public func getCachedAd(slot: String, position: Int) -> AdData? {
        adCache[cacheKey(slot: slot, position: position)]
    }

    /// Cache an ad for a slot/position (translates `cacheAd`)
    public func cacheAd(slot: String, position: Int, ad: AdData) {
        adCache[cacheKey(slot: slot, position: position)] = ad
    }

    /// Get cached height for a slot/position (translates `getCachedHeight`)
    public func getCachedHeight(slot: String, position: Int) -> CGFloat? {
        heightCache[cacheKey(slot: slot, position: position)]
    }

    /// Cache height for a slot/position (translates `cacheHeight`)
    public func cacheHeight(slot: String, position: Int, height: CGFloat) {
        heightCache[cacheKey(slot: slot, position: position)] = height
    }

    /// Check if a slot/position has no fill (translates `hasNoFill`)
    public func hasNoFill(slot: String, position: Int) -> Bool {
        noFillCache.contains(cacheKey(slot: slot, position: position))
    }

    /// Mark a slot/position as having no fill (translates `markNoFill`)
    public func markNoFill(slot: String, position: Int) {
        noFillCache[cacheKey(slot: slot, position: position)] = true
    }
}

// MARK: - Non-observing provider environment key

/// Carries the `SimulaProvider` down the view tree WITHOUT subscribing readers to its
/// `objectWillChange`. `NativeAdSlot` reads this (via `@Environment(\.simulaProvider)`) instead of
/// `@EnvironmentObject`, so a `@Published` change on the provider — e.g. `sessionId` after session
/// create/refresh — doesn't invalidate and re-render every ad slot in a feed at once. Injected by
/// `SimulaProviderView` alongside the existing `.environmentObject(provider)` (which the menu
/// components still use).
private struct SimulaProviderKey: EnvironmentKey {
    static let defaultValue: SimulaProvider? = nil
}

extension EnvironmentValues {
    var simulaProvider: SimulaProvider? {
        get { self[SimulaProviderKey.self] }
        set { self[SimulaProviderKey.self] = newValue }
    }
}

// MARK: - PPIDStore

/// Thread-safe holder for the mutable PPID. `Sendable` so the telemetry flush closure and the
/// session-create task read the live value off the main thread without a data race.
final class PPIDStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ initial: String?) { value = initial }
    var current: String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: String?) { lock.lock(); value = newValue; lock.unlock() }
}

// MARK: - BoundedStore

/// A tiny insertion-ordered, size-capped key→value store backing the legacy host-facing ad caches.
/// Evicts the oldest entry once past `maxEntries`. Not internally synchronized — used exactly where
/// the raw dictionaries were (the public cache methods), so it inherits their single-threaded contract.
private struct BoundedStore<Value> {
    private let maxEntries: Int
    private var storage: [String: Value] = [:]
    private var order: [String] = []

    init(maxEntries: Int) { self.maxEntries = maxEntries }

    subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            guard let newValue else {
                if storage.removeValue(forKey: key) != nil, let i = order.firstIndex(of: key) {
                    order.remove(at: i)
                }
                return
            }
            if storage[key] == nil { order.append(key) }
            storage[key] = newValue
            while storage.count > maxEntries, let oldest = order.first {
                order.removeFirst()
                storage.removeValue(forKey: oldest)
            }
        }
    }

    func contains(_ key: String) -> Bool { storage[key] != nil }
}

// MARK: - SimulaProviderView

/// A SwiftUI wrapper view that provides `SimulaProvider` to its children via EnvironmentObject.
/// This is the direct equivalent of `<SimulaProvider apiKey="...">` in React.
///
/// Usage:
/// ```swift
/// SimulaProviderView(apiKey: "your-api-key", devMode: true) {
///     MyAppContent()
/// }
/// ```
public struct SimulaProviderView<Content: View>: View {
    @StateObject private var provider: SimulaProvider
    private let content: () -> Content
    /// The resolved config, kept so prop changes can be pushed to the store —
    /// `@StateObject` is initialized only once and ignores later init args.
    private let resolvedConfig: SimulaPrivacyConfig
    /// Native-ad targeting context, kept so prop changes can be pushed to the (possibly reused)
    /// provider — like `resolvedConfig`, the `@StateObject` ignores later init args.
    private let adContext: SimulaAdContext?

    public init(
        apiKey: String,
        devMode: Bool = false,
        primaryUserID: String? = nil,
        hasPrivacyConsent: Bool = true,
        privacy: SimulaPrivacyConfig? = nil,
        telemetryEnabled: Bool = true,
        adContext: SimulaAdContext? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.adContext = adContext
        // Resolve the privacy config: an explicit `privacy` wins; otherwise the
        // legacy `hasPrivacyConsent` flag seeds it. Kept so prop changes can be
        // pushed into the store via `.task(id: resolvedConfig)` below.
        var resolved = privacy ?? SimulaPrivacyConfig()
        if privacy == nil { resolved.hasPrivacyConsent = hasPrivacyConsent }
        self.resolvedConfig = resolved

        // Reuse the process-wide provider when its core config matches, to avoid
        // recreating the session/store. A divergent privacy config on the shared
        // instance is reconciled by `updateConsent(resolvedConfig)` in the
        // `.task(id:)` below, so reuse stays safe.
        let provider: SimulaProvider
        if let shared = SimulaAds.shared,
           shared.apiKey == apiKey,
           shared.devMode == devMode,
           shared.primaryUserID == primaryUserID,
           shared.hasPrivacyConsent == hasPrivacyConsent {
            provider = shared
        } else {
            provider = SimulaProvider(
                apiKey: apiKey,
                devMode: devMode,
                primaryUserID: primaryUserID,
                hasPrivacyConsent: hasPrivacyConsent,
                privacy: privacy,
                telemetryEnabled: telemetryEnabled,
                adContext: adContext
            )
        }
        self._provider = StateObject(wrappedValue: provider)
        self.content = content
    }

    public var body: some View {
        content()
            .environmentObject(provider)
            // Also expose it non-observingly so NativeAdSlot can read it without re-rendering on
            // every @Published change (see EnvironmentValues.simulaProvider).
            .environment(\.simulaProvider, provider)
            // Single-call task closures into named methods — see the task-shape note in
            // TelemetryManager.
            .task { await provider.createSession() }
            // Push privacy-prop changes into the store. SwiftUI does not re-init
            // the @StateObject when the `privacy`/`hasPrivacyConsent` props change,
            // so without this a host updating them at render time would be ignored.
            .task(id: resolvedConfig) { provider.updateConsent(resolvedConfig) }
            // Push native-ad context prop changes onto the (possibly reused) provider. Only when a
            // value is supplied, so a host setting context imperatively via SimulaAds.updateContext
            // isn't clobbered by a nil prop.
            .task(id: adContext) { pushAdContext() }
    }

    /// Task body for the ad-context prop push (named method — see the task-shape note in
    /// TelemetryManager).
    private func pushAdContext() {
        if let adContext { provider.updateContext(adContext) }
    }
}
