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
            // Debug: trap loudly. Release: log + return false (was a silent no-op) so the host gets
            // a signal at the call site rather than only via later `.notInitialized` ad failures.
            assertionFailure("[SimulaSDK] \(error.localizedDescription)")
            print("[SimulaSDK] initialize() failed: \(error.localizedDescription). The SDK is NOT initialized — ad calls will report .notInitialized.")
            return false
        }

        // First valid initialization wins so already-created ads keep their session.
        guard shared == nil else {
            print("[SimulaSDK] initialize() ignored — the SDK is already initialized; the first valid configuration wins.")
            return false
        }

        // Monotonic start marker for the sdk_init telemetry duration (emitted once setup completes).
        let startNanos = DispatchTime.now().uptimeNanoseconds

        // Construct the custom User-Agent + device id at init. They're lazy `static let`s, so
        // touching them here forces them before the shared SimulaAPI session reads them for
        // httpAdditionalHeaders.
        _ = SimulaUserAgent.value
        _ = SimulaDeviceId.value

        // Begin device-signal collection so the `X-*` device headers are populated before the first
        // request. Idempotent (also started by `SimulaProvider.init` below); starting it here keeps
        // the first snapshot off the critical path.
        SimulaDeviceSignals.shared.start()

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

        // Warm the session so the first `load()` doesn't pay session creation.
        // Inherits the main actor from the enclosing `@MainActor` context.
        Task {
            await provider.createSession()
        }

        // Independently of session warm-up (each queued verification carries its own
        // session), recover any reward verifications a prior launch left pending (e.g. a
        // crash/kill before a verify could land) so their server-side SSV postbacks fire
        // without waiting for the next rewarded play. This kicks off its own Task, so a
        // slow/failed session create can't delay or skip recovery.
        RewardVerificationManager.shared.triggerProcessQueue()

        // Durable impression/click beacon queue: configure it and drain any beacons a prior process
        // left undelivered (offline/killed). Off the telemetry pipeline; off the critical path.
        AdBeaconManager.shared.configure(apiKey: apiKey)
        AdBeaconManager.shared.triggerProcessQueue()

        // SDK-init beacon, now that telemetry is installed (no-op when telemetry is disabled). Only the
        // first valid initialize reaches here. Best-effort; the config summary carries no PII.
        let initMs = Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000)
        let snap = SimulaPrivacy.shared.currentSnapshot
        let configSummary = "dev=\(devMode) tel=\(telemetryEnabled) consent=\(snap.hasPrivacyConsent) " +
            "coppa=\(snap.coppaApplies) adid=\(snap.advertisingId != nil) ctx=\(adContext != nil)"
        Telemetry.shared.recordOperation(name: "sdk_init", durationMs: initMs, success: true, breadcrumb: configSummary)

        // SDK-upgrade beacon: compare the last-seen version to the current one. A first install just
        // records the version (no event); a changed version emits sdk_upgrade. Best-effort.
        let versionKey = "simula_sdk_last_version"
        let lastVersion = UserDefaults.standard.string(forKey: versionKey)
        if let lastVersion, lastVersion != SIMULA_SDK_VERSION {
            Telemetry.shared.recordOperation(name: "sdk_upgrade", durationMs: 0, success: true, breadcrumb: "from=\(lastVersion);to=\(SIMULA_SDK_VERSION)")
        }
        if lastVersion != SIMULA_SDK_VERSION {
            UserDefaults.standard.set(SIMULA_SDK_VERSION, forKey: versionKey)
        }
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
        let ppid = (primaryUserID?.isEmpty == false) ? primaryUserID : provider.primaryUserID
        if FrequencyCapCache.shared.isCapped(adUnitId: adUnitId, ppid: ppid) { return true }

        // Warm/ensure the session, but only attach its id when it represents the same identity we're
        // checking. After a mid-session login/logout/switch the server session can still reflect the
        // prior user (the PATCH is async, and logout can't be pushed at all); sending that stale id
        // could make the backend evaluate the cap for the wrong user. When it diverges we drop the id
        // and let the backend fall back to the ppid + device-id/IP signals.
        let sessionId = consistentSessionId(await provider.ensureSession(), sessionUserID: provider.sessionUserID, ppid: ppid)
        let capped = await SimulaAPI.shared.checkFrequencyCap(
            apiKey: provider.apiKey,
            adUnitId: adUnitId,
            ppid: ppid,
            sessionId: sessionId
        )
        if capped { FrequencyCapCache.shared.markCapped(adUnitId: adUnitId, ppid: ppid) }
        return capped
    }

    /// Returns `sessionId` only when the session's identity (`sessionUserID`) matches the `ppid`
    /// being checked; otherwise nil (drop the stale session). Pure/testable; `nonisolated` so it can
    /// be exercised without the main actor. Both-nil (anonymous) counts as a match.
    nonisolated static func consistentSessionId(_ sessionId: String?, sessionUserID: String?, ppid: String?) -> String? {
        sessionUserID == ppid ? sessionId : nil
    }

    #if os(iOS)
    /// Imperatively preload one native ad before its slot scrolls into view. Fires a single
    /// `POST /load/native` using the current provider context, caches the full response, and returns
    /// a `preloadedAdId` to pass into a `NativeAdSlot` (which then renders from cache with no live
    /// network call). The entry is evicted once consumed; release any unconsumed id with
    /// `destroyPreloadedAd`. At most 5 ads are kept (excess is dropped with an internal warning).
    /// Returns `nil` before `initialize` or when the cap is reached.
    ///
    /// `theme` is `"dark"`, `"light"`, `"system"`, or `nil`. `"system"` resolves to dark/light from
    /// the current `UITraitCollection` (no SwiftUI environment in the imperative path); `nil` is
    /// omitted from the request (backend defaults to light).
    @discardableResult
    public static func preloadNativeAd(adUnitId: String? = nil, position: Int = 0, theme: String? = nil) async -> String? {
        guard let provider = shared else { return nil }
        return NativeAdPreloadCache.shared.preload(provider: provider, adUnitId: adUnitId, position: position, theme: theme)
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
        NativeAdCache.shared.invalidate(adUnitId, position)
    }

    /// Clear every cached native ad (all slots).
    public static func invalidateNativeAds() {
        NativeAdCache.shared.invalidateAll()
    }
    #endif
}
