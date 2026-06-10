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
/// Call `initialize` from the main thread (app launch is already on it).
@MainActor
public enum SimulaAds {
    /// The shared provider built by `initialize`. `nil` until initialization.
    /// Imperative ads read the session and API key from here.
    public private(set) static var shared: SimulaProvider?

    /// Whether the SDK has been initialized with a valid API key. Imperative ads
    /// use this for fail-fast behavior (e.g. `load()` reporting LOAD_FAILED before
    /// any network call when the host forgot to initialize).
    public static var isInitialized: Bool { shared != nil }

    // MARK: - Character context

    /// Character context attached to every imperative interstitial
    /// (`/ads/load/interstitial`) request. Seed it via `initialize`; update it on the
    /// fly by assigning these directly or calling `setCharacter(...)`. The next
    /// `SimulaInterstitialAd.load()` reads the current values, so there is no stale
    /// per-ad copy to keep in sync.
    public static var charId: String?
    /// Character name sent on the imperative `/ads/load/interstitial` request.
    public static var charName: String?
    /// Character avatar URL sent on the imperative `/ads/load/interstitial` request.
    public static var charImage: String?
    /// Character description sent on the imperative `/ads/load/interstitial` request.
    public static var charDesc: String?

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
    ///   - charId/charName/charImage/charDesc: Optional initial character context for
    ///     the imperative interstitial. Update later via `setCharacter(...)` or by
    ///     assigning the `charId`/`charName`/`charImage`/`charDesc` properties.
    ///   - telemetryEnabled: Opt out of in-house SDK telemetry (handled-error + performance
    ///     metrics sent to Simula). Default `true`. PII in telemetry is consent-gated exactly
    ///     like ad tracking; pass `false` to disable the pipeline entirely.
    ///   - openMeasurementEnabled: Opt out of IAB Open Measurement (OMID) viewability/verification
    ///     measurement. Default `true`. When `false`, OMID is never activated and ads render
    ///     identically, just unmeasured. Measurement failures never affect ad delivery.
    public static func initialize(
        apiKey: String,
        devMode: Bool = false,
        primaryUserID: String? = nil,
        hasPrivacyConsent: Bool = true,
        privacy: SimulaPrivacyConfig? = nil,
        charId: String? = nil,
        charName: String? = nil,
        charImage: String? = nil,
        charDesc: String? = nil,
        telemetryEnabled: Bool = true,
        openMeasurementEnabled: Bool = true
    ) {
        // Fail fast on a missing API key — do not register a shared provider so
        // that subsequent `load()` calls report LOAD_FAILED(.notInitialized).
        do {
            try validateSimulaProviderProps(apiKey: apiKey)
        } catch {
            assertionFailure("[SimulaSDK] \(error.localizedDescription)")
            return
        }

        // First valid initialization wins so already-created ads keep their session.
        guard shared == nil else { return }

        // Seed the character context (changeable later via setCharacter()).
        Self.charId = charId
        Self.charName = charName
        Self.charImage = charImage
        Self.charDesc = charDesc

        let provider = SimulaProvider(
            apiKey: apiKey,
            devMode: devMode,
            primaryUserID: primaryUserID,
            hasPrivacyConsent: hasPrivacyConsent,
            privacy: privacy,
            telemetryEnabled: telemetryEnabled
        )
        shared = provider

        // Activate OMID (cheap, main thread; the service-script read is deferred to a
        // background Task inside activate). Guarded — a failure here never affects ads.
        OpenMeasurement.activate(enabled: openMeasurementEnabled)

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
    }

    /// Replaces the character context used for subsequent interstitial loads. Call
    /// this when the active character changes; the next `SimulaInterstitialAd.load()`
    /// sends the new values. Omitted arguments are cleared, so a character switch
    /// never carries a stale field. For a single-field tweak, assign the property
    /// directly (e.g. `SimulaAds.charName = "Luna"`). Safe to call before `initialize`.
    public static func setCharacter(
        charId: String? = nil,
        charName: String? = nil,
        charImage: String? = nil,
        charDesc: String? = nil
    ) {
        Self.charId = charId
        Self.charName = charName
        Self.charImage = charImage
        Self.charDesc = charDesc
    }
}
