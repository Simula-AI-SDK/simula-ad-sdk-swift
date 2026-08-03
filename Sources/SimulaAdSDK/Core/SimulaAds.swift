import Foundation

// MARK: - SimulaAds

/// Global entry point for the imperative ad API.
///
/// Call `SimulaAds.initialize(apiKey:)` once at app launch before creating any
/// imperative ad (e.g. `SimulaInterstitialAd`). This follows the common one-time
/// SDK initialization pattern used by mediated ad SDKs.
///
/// The initializer builds a single shared `SimulaProvider` that owns the API key,
/// the server session, and the ad cache. Imperative ads read it via
/// `SimulaAds.shared`. The declarative components (`MiniGameMenu`,
/// `MiniGameButton`, `MiniGameInvitation`) continue to use `SimulaProviderView`
/// and are unaffected by this entry point.
///
/// Usage:
/// ```swift
/// SimulaAds.initialize(apiKey: "YOUR_API_KEY", devMode: true)
///
/// let interstitial = SimulaInterstitialAd(adUnitId: "placement_id")
/// interstitial.delegate = self
/// interstitial.load()
/// ```
///
/// Main-actor isolated: the shared mutable state (`shared`) is only ever touched
/// on the main thread, which keeps it free of data races under strict concurrency.
///
/// `initialize` is deliberately cheap: it only builds the provider and kicks the deferred
/// startup (`SimulaProvider.start()`), which moves IDFV/UA syscalls, the shared URLSession
/// build, telemetry install, the version check, session warm-up, and the WebView prewarm off
/// the caller's critical path. Safe to call inline at app launch.
///
/// IMPORTANT: every member here — including `initialize` — is `@MainActor`-isolated, so it MUST be
/// called on the main thread. App launch (`application(_:didFinishLaunching…)`, SwiftUI `App.init`)
/// already runs on the main actor, so the common path needs nothing extra. Under Swift 6 strict
/// concurrency a background-thread call is a compile error; from an older/back-thread context, hop
/// first: `await MainActor.run { SimulaAds.initialize(...) }`.
@MainActor
public enum SimulaAds {
    /// The shared provider built by `initialize`. `nil` until initialization.
    /// Imperative ads read the session and API key from here.
    public private(set) static var shared: SimulaProvider?

    /// Whether the SDK has been initialized with a valid API key. Imperative ads
    /// use this for fail-fast behavior (e.g. `load()` reporting LOAD_FAILED before
    /// any network call when the host forgot to initialize).
    public static var isInitialized: Bool { shared != nil }

    /// The custom User-Agent the SDK sets on its native HTTP requests (PRD). Exposed so a React
    /// Native bridge can retrieve the native string rather than reconstructing it in JS.
    public static var userAgent: String { SimulaUserAgent.value }

    /// The device identifier the SDK sends as the `X-Device-Id` header on its native HTTP requests
    /// (`identifierForVendor`). nil when the platform supplies none. Exposed so a React Native bridge
    /// can retrieve the native value.
    public static var deviceId: String? { SimulaDeviceId.value }

    // Character context is no longer global: pass charId/charName/charImage/charDesc
    // to each `SimulaInterstitialAd.load()` / `SimulaRewardedAd.load()` call instead.

    /// Initializes the SDK with the given API key. Safe to call more than once;
    /// the first valid call wins and subsequent calls are ignored so existing ad
    /// instances keep their session.
    ///
    /// Fails fast on a missing/empty API key: in that case `shared` stays `nil`
    /// and `isInitialized` remains `false` (an assertion fires in debug builds,
    /// matching `SimulaProvider`'s own validation behavior).
    ///
    /// - Parameters:
    ///   - apiKey: The API key for authenticating with Simula services.
    ///   - devMode: Whether the SDK runs in development mode.
    ///   - primaryUserID: Optional primary user identifier (suppressed when
    ///     `hasPrivacyConsent` is `false` or COPPA applies).
    ///   - hasPrivacyConsent: Legacy coarse consent flag. When `false`, suppresses
    ///     collection of PII. Seeds `privacy` when no explicit config is given.
    ///   - privacy: Granular privacy / consent configuration (GDPR/TCF/CCPA/GPP/COPPA
    ///     + IDFA opt-in). When provided it takes precedence over `hasPrivacyConsent`;
    ///     when `nil` the SDK seeds a config from `hasPrivacyConsent` and still
    ///     auto-reads IAB-standard CMP keys. Mirrors `SimulaProviderView`'s `privacy`.
    ///   - telemetryEnabled: Opt out of in-house SDK telemetry (handled-error + performance
    ///     metrics sent to Simula). Default `true`. PII in telemetry is consent-gated exactly
    ///     like ad tracking; pass `false` to disable the pipeline entirely.
    /// - Returns: `true` if this call initialized the SDK; `false` if it was rejected (invalid API
    ///   key) or ignored (already initialized). The result is discardable — the common call site can
    ///   ignore it — but it lets an integrator detect a misconfiguration instead of only discovering
    ///   it later via `.notInitialized` ad failures.
    @discardableResult
    public static func initialize(
        apiKey: String,
        devMode: Bool = false,
        primaryUserID: String? = nil,
        hasPrivacyConsent: Bool = true,
        privacy: SimulaPrivacyConfig? = nil,
        telemetryEnabled: Bool = true,
        adContext: SimulaAdContext? = nil
    ) -> Bool {
        // Fail fast on a missing API key — do not register a shared provider so
        // that subsequent `load()` calls report LOAD_FAILED(.notInitialized).
        do {
            try validateSimulaProviderProps(apiKey: apiKey)
        } catch {
            // Debug: trap loudly. Release: return false so the host gets a signal at the call site
            // rather than only via later `.notInitialized` ad failures.
            assertionFailure("[SimulaSDK] \(error.localizedDescription)")
            return false
        }

        // First valid initialization wins so already-created ads keep their session.
        guard shared == nil else {
            return false
        }

        // Keep this call cheap: it runs on the main thread, typically during app launch. The
        // one-time heavy lifting (IDFV/UA syscalls, shared URLSession build, telemetry install,
        // version check, session warm-up, WebView prewarm) is deferred to `provider.start()`.
        let provider = SimulaProvider(
            apiKey: apiKey,
            devMode: devMode,
            primaryUserID: primaryUserID,
            hasPrivacyConsent: hasPrivacyConsent,
            privacy: privacy,
            telemetryEnabled: telemetryEnabled,
            adContext: adContext
        )
        shared = provider

        // Publish readiness so observers (e.g. the React Native host views waiting to mount a
        // native ad) can react once instead of polling `shared` on a timer.
        NotificationCenter.default.post(name: .simulaAdsDidInitialize, object: nil)

        // Deferred startup: telemetry install + UA/IDFV/session warm-up + WebView prewarm,
        // off this call's critical path. `ensureSession` awaits it, so no request can race
        // ahead of privacy/telemetry setup. Reward-verification recovery and the beacon-queue
        // drain also run there: the first touch of those singletons constructs a `SimulaAPI`,
        // which would otherwise build the shared `URLSession` (UA/IDFV headers) on the main
        // thread right here.
        provider.start()

        return true
    }

    // MARK: - Native ad targeting context + preloading

    /// Replace the native-ad targeting context at runtime (e.g. when the feed category changes).
    /// A full replacement, not a merge (PRD). No-op before `initialize`.
    public static func updateContext(_ context: SimulaAdContext?) {
        shared?.updateContext(context)
    }

    /// Update the primary user id (PPID) mid-session — e.g. after a login, a logout, or a first login
    /// that happened only after the session was created. Mirrors `updateContext`. A nil/empty id clears
    /// the PPID (logout). No-op before `initialize`. The next `session/create` carries the new value,
    /// telemetry reports it, and a live session is PATCHed server-side when consent allows.
    public static func updatePrimaryUserID(_ id: String?) {
        shared?.updatePrimaryUserID(id)
    }

    /// Checks whether the user has hit their frequency cap for `adUnitId` — a read-only check
    /// against the backend that records no impression (PRD). Publishers can call this before
    /// rendering an ad-gated surface to skip it entirely when no ad would serve.
    ///
    /// - Parameters:
    ///   - adUnitId: required.
    ///   - primaryUserID: optional; falls back to the SDK's current PPID (set at `initialize` or
    ///     via `updatePrimaryUserID`) when omitted, and ultimately to the backend's IP/device/
    ///     session signals when neither is available.
    /// - Returns: `true` if the cap has been reached (skip the surface); `false` if the user is
    ///   still eligible, before `initialize`, or on any network/server failure (fails open so a
    ///   transport hiccup can never hide an ad surface that would otherwise have served).
    ///
    /// A `true` result is cached for the rest of the local day (reset at local midnight, per the
    /// PRD) so repeated checks for the same ad unit + user don't re-hit the network.
    public static func checkFrequencyCap(adUnitId: String, primaryUserID: String? = nil) async -> Bool {
        guard let provider = shared, !adUnitId.isEmpty else { return false }
        // An explicit id passed by the caller is fixed for the whole call; only the SDK fallback
        // tracks the provider's live PPID (resolved below, after the session await).
        let explicitPPID = (primaryUserID?.isEmpty == false) ? primaryUserID : nil
        // Capture the local day at the START of the check and attribute the result to it. The network
        // round-trip can cross local midnight; stamping the cache with the completion time would file
        // a prior-day capped result under the new day and keep hiding surfaces after the backend's
        // daily reset. The start time is the day the result actually reflects.
        let now = Date()

        // Warm/ensure the session, then read the effective ppid, session id, and session identity
        // TOGETHER in one synchronous main-actor step (no await between the reads). Resolving the ppid
        // here rather than at entry is what keeps this call coherent: ensureSession() suspends, and a
        // mid-call updatePrimaryUserID (which runs on the same main actor) can switch the active user
        // during that suspension. Reading it afterwards means the cache lookup, the consistentSessionId
        // identity gate, the network request, and markCapped all use one snapshot of the same user
        // instead of a value pinned before the switch — this matters for the SDK fallback, where an
        // omitted primaryUserID would otherwise be checked (and cached) against a now-stale user.
        // Pairing sessionId with sessionUserID in the same step is likewise required: a coalesced
        // waiter can observe the id before the creator sets the identity, and a consent-driven resync
        // can clear the id after ensureSession() returned it. Only attach the id when it represents the
        // same identity we're checking; otherwise drop it and let the backend fall back to the
        // ppid + device-id/IP signals.
        await provider.ensureSession()
        let ppid = explicitPPID ?? provider.primaryUserID
        let sessionId = consistentSessionId(provider.sessionId, sessionUserID: provider.sessionUserID, ppid: ppid)

        if FrequencyCapCache.shared.isCapped(adUnitId: adUnitId, ppid: ppid, now: now) { return true }

        let capped = await SimulaAPI.shared.checkFrequencyCap(
            apiKey: provider.apiKey,
            adUnitId: adUnitId,
            ppid: ppid,
            sessionId: sessionId
        )
        if capped { FrequencyCapCache.shared.markCapped(adUnitId: adUnitId, ppid: ppid, now: now) }
        return capped
    }

    /// Returns `sessionId` only when the session's identity (`sessionUserID`) matches the `ppid`
    /// being checked; otherwise nil (drop the stale session). Pure/testable; `nonisolated` so it can
    /// be exercised without the main actor. Both-nil (anonymous) counts as a match.
    nonisolated static func consistentSessionId(_ sessionId: String?, sessionUserID: String?, ppid: String?) -> String? {
        sessionUserID == ppid ? sessionId : nil
    }

    /// Completion-based variant of `checkFrequencyCap` for callers that must not create Swift
    /// Concurrency tasks themselves — e.g. the React Native bridge, whose source is compiled by
    /// host toolchains affected by the task-teardown miscompile (see the
    /// swift-concurrency-task-shape skill). The task lives INSIDE the SDK binary, which release
    /// builds compile with the pinned pre-regression toolchain. `completion` fires on the main
    /// actor with the same fail-open semantics as the async variant.
    public static func checkFrequencyCap(
        adUnitId: String,
        primaryUserID: String? = nil,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        // Single-call task closure into a named method — see the swift-concurrency-task-shape skill.
        Task { await runCheckFrequencyCap(adUnitId: adUnitId, primaryUserID: primaryUserID, completion: completion) }
    }

    /// Task body for the completion-based `checkFrequencyCap` (named method — see the skill).
    private static func runCheckFrequencyCap(
        adUnitId: String,
        primaryUserID: String?,
        completion: @escaping @MainActor (Bool) -> Void
    ) async {
        completion(await checkFrequencyCap(adUnitId: adUnitId, primaryUserID: primaryUserID))
    }

    #if os(iOS)
    /// Imperatively preload one native ad before its slot scrolls into view. Fires a single
    /// `POST /load/native` using the current provider context, caches the full response, and returns
    /// a `preloadedAdId` to pass into a `NativeAdSlot` (which then renders from cache with no live
    /// network call). The entry is evicted once consumed; release any unconsumed id with
    /// `destroyPreloadedAd`. At most 5 ads are kept (excess is dropped with sampled telemetry).
    /// Returns `nil` before `initialize` or when the cap is reached.
    ///
    /// `theme` is `"dark"`, `"light"`, `"system"`, or `nil`. `"system"` resolves to dark/light from
    /// the current `UITraitCollection` (no SwiftUI environment in the imperative path); `nil` is
    /// omitted from the request (backend defaults to light).
    @discardableResult
    public static func preloadNativeAd(adUnitId: String? = nil, position: Int = 0, theme: String? = nil) async -> String? {
        guard let provider = shared else { return nil }
        return NativeAdPreloadCache.shared.preload(
            provider: provider, adUnitId: adUnitId, position: position, theme: theme, metadata: nil
        )
    }

    /// Preload a native ad with publisher metadata snapshotted for its load and `/seen` beacon.
    /// Metadata supplied later to `NativeAdSlot` cannot override this preload-time snapshot.
    @discardableResult
    public static func preloadNativeAd(
        adUnitId: String? = nil,
        position: Int = 0,
        theme: String? = nil,
        metadata: [String: String]
    ) async -> String? {
        guard let provider = shared else { return nil }
        return NativeAdPreloadCache.shared.preload(
            provider: provider, adUnitId: adUnitId, position: position, theme: theme, metadata: metadata
        )
    }

    /// Completion-based variant of `preloadNativeAd` for callers that must not create Swift
    /// Concurrency tasks themselves (e.g. the React Native bridge — see the
    /// swift-concurrency-task-shape skill). The preload registration is synchronous under the
    /// hood, so this creates no task at all; `completion` fires inline on the main actor with
    /// the `preloadedAdId` (nil before `initialize`).
    public static func preloadNativeAd(
        adUnitId: String? = nil,
        position: Int = 0,
        theme: String? = nil,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let provider = shared else {
            completion(nil)
            return
        }
        completion(NativeAdPreloadCache.shared.preload(
            provider: provider, adUnitId: adUnitId, position: position, theme: theme, metadata: nil
        ))
    }

    /// Completion-based preload with an immutable publisher metadata snapshot.
    public static func preloadNativeAd(
        adUnitId: String? = nil,
        position: Int = 0,
        theme: String? = nil,
        metadata: [String: String],
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let provider = shared else {
            completion(nil)
            return
        }
        completion(NativeAdPreloadCache.shared.preload(
            provider: provider, adUnitId: adUnitId, position: position, theme: theme, metadata: metadata
        ))
    }

    /// Release a preloaded native ad that was never consumed, cancelling its request if in flight.
    public static func destroyPreloadedAd(_ preloadedAdId: String) {
        NativeAdPreloadCache.shared.destroy(preloadedAdId)
    }

    /// Drop the cached ad for a native slot so its next appearance fetches a fresh one. A
    /// `NativeAdSlot` caches its resolved ad per `(adUnitId, position)` so scrolling it out and back
    /// reuses the same serve (no duplicate request or impression); call this to force a refresh for
    /// that slot. Use `invalidateNativeAds()` to clear them all.
    public static func invalidateNativeAd(adUnitId: String? = nil, position: Int = 0) {
        // Drop the retained rendered web view for the invalidated serve too, so the refreshed slot
        // can't reattach the stale creative.
        if let impressionId = NativeAdCache.shared.invalidate(adUnitId, position) {
            NativeAdWebViewStore.shared.evict(impressionId: impressionId)
        }
    }

    /// Clear every cached native ad (all slots).
    public static func invalidateNativeAds() {
        NativeAdCache.shared.invalidateAll()
        // Idle retained views are destroyed; on-screen ones are flagged so scroll-out destroys
        // them — with every fill dropped, none may be reattached (parity with invalidateNativeAd).
        NativeAdWebViewStore.shared.invalidateAllSessions()
    }
    #endif
}

extension Notification.Name {
    /// Posted on the main thread once per process when `SimulaAds.initialize` succeeds — i.e.
    /// the moment `SimulaAds.shared != nil` and the imperative API is usable. A session may not
    /// exist yet (session warm-up is part of the deferred startup); ad loads gate on it
    /// internally. Observers that only need the provider (e.g. a host view waiting to mount a
    /// native ad) should use this instead of polling `SimulaAds.shared`.
    public static let simulaAdsDidInitialize = Notification.Name("ad.simula.sdk.didInitialize")
}
