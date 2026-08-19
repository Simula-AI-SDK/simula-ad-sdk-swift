import Foundation

// MARK: - SimulaInterstitialAdDelegate

/// Receives lifecycle events for a `SimulaInterstitialAd`.
///
/// Method names follow standard full-screen-ad conventions. The canonical
/// cross-platform event names (shared with Android and the React Native bridge)
/// are noted on each method. All methods have default no-op implementations, so
/// conformers implement only the events they care about.
///
/// Events are delivered on the main thread.
public protocol SimulaInterstitialAdDelegate: AnyObject {
    /// `LOADED` — an ad was preloaded and is ready to `show`.
    func interstitialDidLoad(_ ad: SimulaInterstitialAd)

    /// `LOAD_FAILED` — `load()` could not produce a ready ad.
    func interstitialDidFailToLoad(_ ad: SimulaInterstitialAd, error: SimulaAdError)

    /// `DISPLAYED` — the ad surface was presented full-screen (the "shown" signal).
    func interstitialDidDisplay(_ ad: SimulaInterstitialAd)

    /// `IMPRESSION` — a billable impression was recorded (the billable-impression signal), fired
    /// ~2 seconds after the creative begins to render. Distinct from `DISPLAYED`; followed
    /// immediately by `PAID`.
    func interstitialDidRecordImpression(_ ad: SimulaInterstitialAd)

    /// `PAID` — the estimated revenue for this impression (the paid event). Fired
    /// together with `IMPRESSION`; `value` is already on-device from load time (no network
    /// round-trip). Use it for your own analytics — the backend's impression confirmation remains
    /// the source of truth for billing.
    func interstitialDidPay(_ ad: SimulaInterstitialAd, value: AdValue)

    /// `DISPLAY_FAILED` — `show()` could not present the ad.
    func interstitialDidFailToDisplay(_ ad: SimulaInterstitialAd, error: SimulaAdError)

    /// `CLICKED` — the user tapped the CTA, which opens the advertiser destination.
    func interstitialDidClick(_ ad: SimulaInterstitialAd)

    /// `CLOSED` — the ad surface was fully dismissed.
    func interstitialDidClose(_ ad: SimulaInterstitialAd)
}

public extension SimulaInterstitialAdDelegate {
    func interstitialDidLoad(_ ad: SimulaInterstitialAd) {}
    func interstitialDidFailToLoad(_ ad: SimulaInterstitialAd, error: SimulaAdError) {}
    func interstitialDidDisplay(_ ad: SimulaInterstitialAd) {}
    func interstitialDidRecordImpression(_ ad: SimulaInterstitialAd) {}
    func interstitialDidPay(_ ad: SimulaInterstitialAd, value: AdValue) {}
    func interstitialDidFailToDisplay(_ ad: SimulaInterstitialAd, error: SimulaAdError) {}
    func interstitialDidClick(_ ad: SimulaInterstitialAd) {}
    func interstitialDidClose(_ ad: SimulaInterstitialAd) {}
}

// MARK: - SimulaAdError

/// Reasons a `SimulaInterstitialAd` failed to load or display.
public enum SimulaAdError: LocalizedError, Sendable {
    /// `SimulaAds.initialize(apiKey:)` was not called (or the key was invalid).
    case notInitialized
    /// A server session could not be created.
    case noSession
    /// No creative was returned to show (no-fill).
    case noFill
    /// `show()` was called before an ad was loaded.
    case notReady
    /// `show()` was called on an ad that loaded more than an hour ago (expired).
    case stale
    /// `load()` was blocked because a matching ad is already loaded or in flight
    /// (same ad unit id, character id, character name, session id) within the
    /// 5-minute dedup window. When the matching ad is already loaded,
    /// `retryInSeconds` carries the time left in that window (after which `load()`
    /// unblocks); while it is still loading, `retryInSeconds` is `nil`.
    case duplicateRequest(retryInSeconds: Int?)
    /// `show()` was called while an ad was already showing.
    case alreadyShowing
    /// No active window scene was available to present in.
    case noPresentationContext
    /// Imperative presentation is unavailable on this platform (iOS-only).
    case unsupportedPlatform
    /// An underlying networking error.
    case network(SimulaAPIError)
    /// The backend rejected the requested ad unit id — it isn't registered for this app
    /// (wrong id, or it belongs to a different app/publisher). Non-retryable: fix the ad
    /// unit id. Surfaced through the same `didFailToLoad` delegate callback as other failures.
    case adUnitNotFound

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "SimulaAds is not initialized — call SimulaAds.initialize() first."
        case .noSession:
            return "Could not create a session. Check the API key and network connection."
        case .noFill:
            return "No ad available to show right now (no fill)."
        case .notReady:
            return "Ad not ready — call load() first and wait for the loaded callback before show()."
        case .stale:
            return "The loaded ad has expired (1 hour limit) and can no longer be shown. "
                + "Call load() to request a new ad."
        case .duplicateRequest(let retryInSeconds):
            if let retryInSeconds {
                return "An ad for this placement is already loaded. Call show() to display it, "
                    + "or load() again in \(retryInSeconds) seconds."
            }
            return "An ad for this placement is already loading. "
                + "Wait for the didLoad delegate callback before calling load() again."
        case .alreadyShowing:
            return "An interstitial is already showing."
        case .noPresentationContext:
            return "No active window scene is available to present the ad."
        case .unsupportedPlatform:
            return "The imperative interstitial is only supported on iOS."
        case .network:
            // Shared, descriptive copy (matches the Android SDK). The underlying `SimulaAPIError`
            // stays available on the associated value for programmatic inspection / debugging.
            return "Network error while loading the ad — check the connection and call load() again."
        case .adUnitNotFound:
            // Public contract — shared verbatim with the Android SDK's SimulaAdError.AdUnitNotFound.
            return "Ad unit id is not registered for this app — check the ad unit id in your Simula dashboard."
        }
    }
}

extension SimulaAdError {
    /// Stable, low-cardinality code for this error, used as the `error_code` on telemetry events.
    var telemetryCode: String {
        switch self {
        case .notInitialized: return "not_initialized"
        case .noSession: return "no_session"
        case .noFill: return "no_fill"
        case .notReady: return "not_ready"
        case .stale: return "stale"
        case .duplicateRequest: return "duplicate_request"
        case .alreadyShowing: return "already_showing"
        case .noPresentationContext: return "no_presentation_context"
        case .unsupportedPlatform: return "unsupported_platform"
        case .network: return "network"
        case .adUnitNotFound: return "ad_unit_not_found"
        }
    }
}

// MARK: - SimulaInterstitialAd

/// An imperative, preloadable full-screen interstitial ad.
///
/// Lifecycle follows the standard mediated full-screen ad pattern: configure
/// once, `load()` to preload, then `show(...)` to present. Events are delivered
/// to `delegate`.
///
/// - A single load is in flight per instance; calling `load()` while loading or
///   while an ad is ready is a no-op.
/// - After the ad closes, the next ad is preloaded automatically.
/// - `load()` fails fast with `.notInitialized` when `SimulaAds.initialize` has
///   not been called.
///
/// `show()` presents a native full-screen creative (`DISPLAYED`): the
/// server-rendered HTML creative (`rendered_html`) in a web view, which owns its
/// own CTA. A user-initiated link tap inside it fires `CLICKED` and opens the
/// advertiser's App Store or web destination. A close button dismisses the ad.
///
/// Usage:
/// ```swift
/// let ad = SimulaInterstitialAd(adUnitId: "placement_id")
/// ad.delegate = self
/// ad.load()
/// // later, once LOADED:
/// ad.show()
/// ```
@MainActor
public final class SimulaInterstitialAd {
    // MARK: - Configuration

    /// The placement identifier for this ad instance.
    public let adUnitId: String

    /// Receives lifecycle events.
    public weak var delegate: SimulaInterstitialAdDelegate?

    private let metadataStore = ExtraParametersStore()

    // Character context is passed per `load()` call (see below); there is no global
    // character state to keep in sync.

    /// A loaded ad expires this long after it became ready (staleness).
    private static let staleAfter: TimeInterval = 60 * 60 // 1 hour
    /// Re-loads of the same dedup key are blocked for this long.
    private static let dedupWindow: TimeInterval = 5 * 60 // 5 minutes

    // MARK: - State

    private enum State {
        case idle
        case loading
        /// `metadata` is the immutable load-time snapshot used by the billable `/seen` beacon;
        /// `loadedAt` is when the creative became ready (used for staleness).
        case ready(AdLoadResponse, metadata: [String: String]?, loadedAt: Date)
        case showing(AdLoadResponse, metadata: [String: String]?)
    }

    private var state: State = .idle
    private var loadTask: Task<Void, Never>?
    // Lazy, mirroring SimulaProvider.api: hosts construct the ad at launch right after
    // SimulaAds.initialize, and an eager SimulaAPI() would build the one-time `defaultSession`
    // static (URLSession + UA/IDFV headers) on the main thread before the deferred startup's
    // off-main prewarm can run — re-introducing the launch hitch the startup moved off-main.
    // First touch is then load(), after the prewarm already built the static. @MainActor, so
    // the lazy initialization is race-free.
    private lazy var api = SimulaAPI()

    // Dedup: the (ad unit, character, session) key of the load currently in flight or
    // ready, and when that load was initiated. Re-loads of the same key are blocked for
    // `dedupWindow`. Main-actor isolated.
    private var currentKey: String?
    private var currentKeyAt: Date = .distantPast

    // Character context of the last load(), replayed by the post-close auto-preload.
    private var lastCharId: String?
    private var lastCharName: String?
    private var lastCharImage: String?
    private var lastCharDesc: String?

    // Monotonic stage markers for telemetry latencies (0 = not yet started).
    private var loadStartNanos: UInt64 = 0
    private var showStartNanos: UInt64 = 0
    private nonisolated static let adFormat = "interstitial"

    #if os(iOS)
    private var presenter: InterstitialPresenter?
    /// Holds the post-close fallback ad window while it's on screen (parity with the minigame's
    /// post-game ad flow).
    private var fallbackPresenter: FallbackAdPresenter?
    /// Background prefetch of the post-close fallback screens, kicked off while the primary ad is
    /// on screen so they present instantly on close (no fetch-after-close flash). Consumed once in
    /// `presentFallbackAds`.
    private var fallbackPrefetch: Task<[FallbackAd], Never>?
    /// The prefetch result once it lands, so the close path can present the fallback window
    /// synchronously (before the primary window is torn down) rather than awaiting.
    private var prefetchedFallbacks: [FallbackAd]?
    #endif

    // MARK: - Init

    public init(adUnitId: String) {
        self.adUnitId = adUnitId
    }

    /// Upserts one publisher metadata entry for future loads. Invalid entries are ignored safely.
    /// Calling this after `load()` does not change the ready ad: each load snapshots its metadata for
    /// both the load request and that impression's billable `/seen` beacon.
    public func setMetadata(_ key: String, _ value: String) {
        metadataStore.set(key: key, value: value)
    }

    /// Replaces publisher metadata for future loads. Passing an empty dictionary clears it. At most
    /// 10 non-empty keys are accepted (64 Unicode scalars per key and 256 per value); keys beginning
    /// with `$` or containing `.` are ignored. A ready ad retains its load-time snapshot.
    public func setMetadata(_ metadata: [String: String]) {
        metadataStore.replace(with: metadata)
    }

    // MARK: - Load

    /// Preloads an ad for the given character context.
    ///
    /// The character fields are sent on the `/load/interstitial` request so the
    /// backend can target the creative; all are optional. Behavior:
    ///
    /// - **Single in-flight load.** While a load for the same ad is in flight or
    ///   ready, calling `load()` again with the **same** key — (ad unit id, `charId`,
    ///   `charName`, session id) — is blocked for 5 minutes and fires `LOAD_FAILED`
    ///   with `.duplicateRequest`. A **different** ad unit or character is treated as
    ///   new and supersedes the pending/ready ad.
    /// - **Staleness.** A loaded ad expires after 1 hour; `show()` then fires
    ///   `DISPLAY_FAILED` with `.stale`.
    /// - **No-op while showing.** Ignored while an ad is on screen; the next ad is
    ///   preloaded automatically on close.
    public func load(
        charId: String? = nil,
        charName: String? = nil,
        charImage: String? = nil,
        charDesc: String? = nil
    ) {
        guard SimulaAds.isInitialized, let provider = SimulaAds.shared else {
            failLoad(.notInitialized)
            return
        }

        // Replay the same character context on the post-close auto-preload.
        lastCharId = charId
        lastCharName = charName
        lastCharImage = charImage
        lastCharDesc = charDesc

        let key = Self.dedupKey(adUnitId: adUnitId, charId: charId, charName: charName, sessionId: provider.sessionId)
        let now = Date()

        switch state {
        case .showing:
            return // an ad is on screen; the next one preloads on close
        case .loading, .ready:
            // A matching ad is already loading/ready: block a same-key re-load within
            // the dedup window; a different key falls through and supersedes it.
            if currentKey == key, now.timeIntervalSince(currentKeyAt) < Self.dedupWindow {
                reportLoadBlocked()
                return
            }
        case .idle:
            break // nothing held — proceed
        }

        // Supersede any in-flight load / discard any ready ad, then start fresh.
        loadTask?.cancel()
        currentKey = key
        currentKeyAt = now
        state = .loading
        loadStartNanos = DispatchTime.now().uptimeNanoseconds
        let metadata = metadataStore.snapshot()
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        loadTask = Task { [weak self] in
            await self?.runLoad(
                provider: provider,
                charId: charId,
                charName: charName,
                charImage: charImage,
                charDesc: charDesc,
                metadata: metadata
            )
        }
    }

    /// Load task body (named method — see the task-shape note in TelemetryManager).
    private func runLoad(
        provider: SimulaProvider,
        charId: String?,
        charName: String?,
        charImage: String?,
        charDesc: String?,
        metadata: [String: String]?
    ) async {
        let sessionId = await provider.ensureSession()
        if Task.isCancelled { return }
        guard let sessionId, !sessionId.isEmpty else {
            failLoad(.noSession)
            return
        }
        // The real session id is now known. Refresh the dedup key — the
        // synchronous gate at load() time may have keyed on an empty session
        // during cold-start warm-up — so a subsequent same-key load() still
        // deduplicates. `currentKeyAt` intentionally stays at the original load time.
        currentKey = Self.dedupKey(adUnitId: adUnitId, charId: charId, charName: charName, sessionId: sessionId)

        do {
            let response = try await api.loadAd(
                adUnitId: adUnitId,
                sessionId: sessionId,
                charId: charId,
                charName: charName,
                charImage: charImage,
                charDesc: charDesc,
                // AdContext (contextual targeting) now rides on the full-screen request too, read
                // from the same provider-level store the native surface uses.
                context: provider.adContext,
                metadata: metadata
            )
            if Task.isCancelled { return }
            // Fillable only when the payload carries a non-blank `rendered_html`
            // creative (whitespace-only HTML trims to nil → no-fill).
            guard response.adInserted, response.htmlCreative != nil else {
                failLoad(.noFill)
                return
            }
            Telemetry.shared.setExperiment(experimentId: response.experiment?.experimentId, variantId: response.experiment?.variantId)
            Telemetry.shared.recordLifecycle(
                stage: "load_success", adFormat: Self.adFormat, adUnitId: adUnitId,
                adId: response.impressionId, serveId: nil, durationMs: msSince(loadStartNanos), errorCode: nil
            )
            state = .ready(response, metadata: metadata, loadedAt: Date())
            delegate?.interstitialDidLoad(self)
        } catch let apiError as SimulaAPIError {
            // Genuine exception — always-sent, deduped handled error (the sampled `load_fail`
            // lifecycle event comes from failLoad()).
            Telemetry.shared.recordError(signature: "interstitial:load", errorCode: "\(apiError)", message: apiError.errorDescription, breadcrumb: "SimulaInterstitialAd.load")
            // ad_unit_not_found is a distinct, non-retryable misconfiguration — surface it as its
            // own case rather than burying it in the generic .network bucket.
            if case .adUnitNotFound = apiError {
                failLoad(.adUnitNotFound)
            } else {
                failLoad(.network(apiError))
            }
        } catch {
            Telemetry.shared.recordError(signature: "interstitial:load", errorCode: "\(type(of: error))", message: error.localizedDescription, breadcrumb: "SimulaInterstitialAd.load")
            failLoad(.network(.invalidResponse))
        }
    }

    /// Dedup key: (ad unit id, character id, character name, current session id),
    /// joined with a NUL separator so values containing spaces can't collide.
    private static func dedupKey(adUnitId: String, charId: String?, charName: String?, sessionId: String?) -> String {
        [adUnitId, charId ?? "", charName ?? "", sessionId ?? ""].joined(separator: "\u{0}")
    }

    // MARK: - Show

    /// Presents the loaded creative full-screen. Fires `DISPLAYED` on success or
    /// `DISPLAY_FAILED` when no ad is ready / one is already showing / the platform
    /// is unsupported. Tapping the CTA fires `CLICKED` and opens the advertiser
    /// destination.
    ///
    /// On close, fires `CLOSED` and automatically preloads the next ad.
    public func show() {
        let response: AdLoadResponse
        let metadata: [String: String]?
        switch state {
        case .ready(let loaded, let loadMetadata, let loadedAt):
            // A loaded ad expires after 1 hour. Drop it (back to idle so the host can
            // load() again — the dedup window is long gone) and report stale.
            if Date().timeIntervalSince(loadedAt) > Self.staleAfter {
                state = .idle
                failDisplay(.stale)
                return
            }
            response = loaded
            metadata = loadMetadata
        case .showing:
            failDisplay(.alreadyShowing)
            return
        case .idle, .loading:
            failDisplay(.notReady)
            return
        }

        #if os(iOS)
        guard let provider = SimulaAds.shared else {
            failDisplay(.notInitialized)
            return
        }

        let presenter = InterstitialPresenter()
        showStartNanos = DispatchTime.now().uptimeNanoseconds

        let didPresent = presenter.present(
            apiKey: provider.apiKey,
            response: response,
            onClick: { [weak self] in
                guard let self else { return }
                Telemetry.shared.recordLifecycle(stage: "click", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.impressionId)
                self.delegate?.interstitialDidClick(self)
            },
            onImpression: { [weak self] in
                guard let self else { return }
                // IMPRESSION + PAID (the billable impression + paid event), fired together ~2s
                // after begin-to-render by the presenter (foreground-aware). The `/seen` beacon is the
                // billing source of truth; `didPay` is local analytics (value already on-device).
                Telemetry.shared.recordLifecycle(stage: "impression", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.impressionId)
                Telemetry.shared.recordLifecycle(stage: "paid", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.impressionId)
                self.delegate?.interstitialDidRecordImpression(self)
                self.delegate?.interstitialDidPay(self, value: response.adValue)
                // Durable billable-impression beacon (was a fire-and-forget trackImpression).
                AdBeaconManager.shared.enqueue(
                    impressionId: response.impressionId,
                    action: "seen",
                    adFormat: Self.adFormat,
                    adUnitId: self.adUnitId,
                    metadata: metadata
                )
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.presenter = nil
                self.state = .idle
                Telemetry.shared.recordLifecycle(stage: "closed", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.impressionId)
                // Show the fallback ad screens on close (parity with the minigame post-game flow).
                // Uses the background prefetch started at display time, so there's no fetch-after-close gap.
                // END_SCREEN_N auto_store_redirect opens the primary ad's store at the matching index.
                // CLOSED fires from onAllClosed — after the LAST fallback screen, not the playable close.
                self.presentFallbackAds(
                    response: response,
                    autoStoreRedirect: response.adBehavior?.autoStoreRedirect,
                    onAutoStoreRedirect: {
                        CreativeCTARouter.open(
                            trackingUrl: response.trackingUrl,
                            destination: response.destinationKind,
                            storeOpen: response.adBehavior?.storeOpen ?? .skstoreproduct,
                            storeUrl: response.iosStoreUrl,
                            attribution: response.skanAttribution
                        )
                    },
                    onAllClosed: { [weak self] in
                        guard let self else { return }
                        self.delegate?.interstitialDidClose(self)
                        // Auto-preload the next ad only now that the WHOLE unit is closed (Android
                        // parity). Preloading at creative close made the next LOADED land BEFORE
                        // CLOSED whenever fallback screens were up — inverting the publisher-visible
                        // event order and stranding a ready ad behind any "loaded" mirror the host
                        // keeps (e.g. the React Native hook). Skipped when the host already started
                        // its own load during the fallback phase.
                        if case .idle = self.state {
                            self.load(
                                charId: self.lastCharId,
                                charName: self.lastCharName,
                                charImage: self.lastCharImage,
                                charDesc: self.lastCharDesc
                            )
                        }
                    }
                )
            }
        )

        guard didPresent else {
            // Couldn't present (no window scene). Keep the loaded ad so the host
            // can retry; report DISPLAY_FAILED without a bogus DISPLAYED/CLOSED.
            // `state` was never moved off `.ready`, so the ad stays showable.
            failDisplay(.noPresentationContext)
            return
        }

        // Only now is the ad actually on screen.
        state = .showing(response, metadata: metadata)
        self.presenter = presenter
        // Prefetch the post-close fallback screens now, in the background, so they're ready the
        // instant the user closes — fetching after close left a gap that flashed the screen behind.
        // GET /load/fallbacks is side-effect-free (no impression tracking), so this reports nothing early.
        startFallbackPrefetch(impressionId: response.impressionId)
        Telemetry.shared.recordLifecycle(
            stage: "displayed", adFormat: Self.adFormat, adUnitId: adUnitId,
            adId: response.impressionId, serveId: nil, durationMs: msSince(showStartNanos), errorCode: nil
        )
        delegate?.interstitialDidDisplay(self)
        // SHOWN — the `/shown` beacon, fired at present. The
        // billable IMPRESSION + PAID fire ~2s later via the presenter's `onImpression` (above).
        // Durable beacon (was a fire-and-forget trackShown).
        AdBeaconManager.shared.enqueue(impressionId: response.impressionId, action: "shown", adFormat: Self.adFormat, adUnitId: adUnitId)
        #else
        failDisplay(.unsupportedPlatform)
        #endif
    }

    // MARK: - Preview (debug / QA)

    /// A self-contained placeholder creative so `showPreview` can render the close-button A/B
    /// chrome over a visible surface without fetching a network creative.
    private static let previewCreativeHTML = """
    <!doctype html><html><head><meta name="viewport" \
    content="width=device-width, initial-scale=1, viewport-fit=cover"></head>\
    <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;\
    background:linear-gradient(160deg,#1e3a8a,#7c3aed);\
    font-family:-apple-system,system-ui,sans-serif;color:#fff;text-align:center">\
    <div><div style="font-size:22px;font-weight:700">A/B Close Button Preview</div>\
    <div style="opacity:.8;margin-top:8px;font-size:15px">Hardcoded ad_behavior — no network</div></div>\
    </body></html>
    """

    /// A real App Store URL used only by `showPreview` so the SKOverlay path can resolve a numeric
    /// adamId (`SKOverlay.AppConfiguration(appIdentifier:)` requires one) without a network round-trip,
    /// and so a store-prompt-badge tap routes somewhere. Without this the preview's SKOverlay no-ops.
    private static let previewTrackingURL = "https://apps.apple.com/app/id375380948"

    /// Presents the interstitial with a **hardcoded** `ad_behavior` and a placeholder creative —
    /// no network call and no impression tracked. Lets a host/sample app preview the A/B
    /// close-button treatments without the backend assigning the variant.
    ///
    /// Parameters take the same wire strings the server would send; unknown values fall back
    /// exactly as a real payload would (e.g. an unknown treatment → `hidden`). iOS only.
    ///
    /// - Parameters:
    ///   - closeTreatment: `hidden` / `countdown_circle` / `progress_bar` / `reward_or_close_label`.
    ///   - closePosition: `top_right` / `top_left` / `bottom_left`.
    ///   - delaySeconds: the pre-tap close delay the treatment animates over.
    ///   - progressBarColor: 6-digit hex (optional leading `#`) tinting the ring / bar fill.
    ///   - adUnitType: `interstitial` / `rewarded` — drives the `reward_or_close_label` copy.
    ///   - storePrompt: also show the mid-ad store-prompt badge.
    ///   - skOverlay: also present the SKOverlay install banner (needs a resolvable store id).
    public func showPreview(
        closeTreatment: String,
        closePosition: String = "top_right",
        delaySeconds: Int = 5,
        progressBarColor: String = "#FFFFFF",
        adUnitType: String = "interstitial",
        storePrompt: Bool = false,
        skOverlay: Bool = false
    ) {
        #if os(iOS)
        if case .showing = state {
            failDisplay(.alreadyShowing)
            return
        }
        guard let provider = SimulaAds.shared else {
            failDisplay(.notInitialized)
            return
        }

        let close = CloseBehavior(
            delaySeconds: delaySeconds,
            treatment: CloseTreatment.from(closeTreatment),
            position: ClosePosition.from(closePosition),
            progressBarColor: validatedHexColor(progressBarColor)
        )
        // Mirror the server's collision rule: place the store-prompt badge opposite the close button.
        // top_right → top_left; top_left → top_right; bottom_left → top_left (the default position,
        // since a bottom-left close doesn't occupy either top corner).
        let storePromptPosition: ClosePosition
        switch close.position {
        case .topRight: storePromptPosition = .topLeft
        case .topLeft: storePromptPosition = .topRight
        case .bottomLeft: storePromptPosition = .topLeft
        }
        let behavior = AdBehavior(
            close: close,
            storePrompt: storePrompt ? StorePrompt(enabled: true, position: storePromptPosition, platform: .ios) : nil,
            skoverlay: skOverlay ? SKOverlayConfig(enabled: true, timing: .duringPlay) : nil
        )
        let response = AdLoadResponse(
            impressionId: "",             // empty → no impression is ever tracked for a preview
            adInserted: true,
            adUnitId: adUnitId,
            trackingUrl: Self.previewTrackingURL,  // lets SKOverlay resolve an adamId + store taps route
            renderedHtml: Self.previewCreativeHTML,
            adBehavior: behavior,
            creative: Creative(type: "preview", adUnitType: AdUnitType.from(adUnitType))
        )

        let presenter = InterstitialPresenter()
        let didPresent = presenter.present(
            apiKey: provider.apiKey,
            response: response,
            onClick: { [weak self] in
                guard let self else { return }
                self.delegate?.interstitialDidClick(self)
            },
            onImpression: { [weak self] in
                guard let self else { return }
                // Preview is local-only: surface the callbacks (with a $0 estimate) but no beacon.
                self.delegate?.interstitialDidRecordImpression(self)
                self.delegate?.interstitialDidPay(self, value: response.adValue)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.presenter = nil
                self.state = .idle
                self.delegate?.interstitialDidClose(self)
            }
        )

        guard didPresent else {
            failDisplay(.noPresentationContext)
            return
        }
        state = .showing(response, metadata: nil)
        self.presenter = presenter
        delegate?.interstitialDidDisplay(self)
        // Preview is local-only: deliberately no `trackImpression`.
        #else
        failDisplay(.unsupportedPlatform)
        #endif
    }

    // MARK: - Failure helpers

    private func failLoad(_ error: SimulaAdError) {
        state = .idle
        Telemetry.shared.recordLifecycle(
            stage: "load_fail", adFormat: Self.adFormat, adUnitId: adUnitId,
            adId: nil, serveId: nil, durationMs: msSince(loadStartNanos), errorCode: error.telemetryCode
        )
        delegate?.interstitialDidFailToLoad(self, error: error)
    }

    /// Report a dedup-blocked load without disturbing state — the in-flight or ready
    /// ad that triggered the block must survive (it stays loadable/showable). The error
    /// message reflects whether that ad is ready (with the seconds left in the dedup
    /// window) or still loading.
    private func reportLoadBlocked() {
        let retryInSeconds: Int?
        if case .ready = state {
            let remaining = Self.dedupWindow - Date().timeIntervalSince(currentKeyAt)
            retryInSeconds = Int(max(0, remaining).rounded(.up))
        } else {
            retryInSeconds = nil
        }
        let error = SimulaAdError.duplicateRequest(retryInSeconds: retryInSeconds)
        // Observable like any other rejected load() (sampled); no real load ran, so no duration.
        Telemetry.shared.recordLifecycle(
            stage: "load_fail", adFormat: Self.adFormat, adUnitId: adUnitId,
            adId: nil, serveId: nil, durationMs: nil, errorCode: error.telemetryCode
        )
        delegate?.interstitialDidFailToLoad(self, error: error)
    }

    private func failDisplay(_ error: SimulaAdError) {
        Telemetry.shared.recordLifecycle(stage: "show_fail", adFormat: Self.adFormat, adUnitId: adUnitId, errorCode: error.telemetryCode)
        delegate?.interstitialDidFailToDisplay(self, error: error)
    }

    /// Monotonic ms since the given marker (nil if not started).
    private func msSince(_ startNanos: UInt64) -> Int? {
        guard startNanos != 0 else { return nil }
        return Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000)
    }

    // MARK: - Fallback ads (post-close)

    /// Starts a background prefetch of the serve's fallback ad screens
    /// (`GET /load/fallbacks/{impressionId}`) while the primary ad is on screen, so they're ready
    /// the instant the user closes. Best-effort: a missing id / network error / empty response
    /// resolves to an empty list (nothing shown). The fetch is side-effect-free server-side.
    private func startFallbackPrefetch(impressionId: String) {
        #if os(iOS)
        fallbackPrefetch?.cancel()
        prefetchedFallbacks = nil
        guard !impressionId.isEmpty else { fallbackPrefetch = nil; return }
        // Single-call task closure (inherits @MainActor) — see the task-shape note in TelemetryManager.
        // `api` is captured strongly so the fetch still runs — and any awaiter still receives real
        // screens — even if this ad object is released before the task starts (parity with the
        // pre-refactor closure); `self` stays weak and only gates the state write.
        fallbackPrefetch = Task { [weak self, api] in await Self.runFallbackPrefetch(api: api, impressionId: impressionId, ad: self) }
        #endif
    }

    #if os(iOS)
    /// Task body for the fallback prefetch (named method — see the task-shape note in
    /// TelemetryManager). Static with a strongly captured `api` + optional `ad`, so the fetch never
    /// depends on the ad object's liveness; the `prefetchedFallbacks` write stays a main-actor
    /// write (and simply no-ops when the ad was released).
    @MainActor
    private static func runFallbackPrefetch(api: SimulaAPI, impressionId: String, ad: SimulaInterstitialAd?) async -> [FallbackAd] {
        let ads: [FallbackAd]
        do { ads = try await api.fetchFallbacks(impressionId: impressionId) } catch { ads = [] }
        ad?.prefetchedFallbacks = ads
        return ads
    }
    #endif

    /// After the creative closes, present the prefetched fallback ad screens full-screen in reveal
    /// order. When the prefetch has landed (the common case) it presents **synchronously**, so the
    /// fallback window is on screen before the primary window is torn down (see the presenter's
    /// `dismiss`) — no fetch-after-close gap and no handoff flash. If the user closed before the
    /// prefetch finished (rare), it awaits and presents on the next runloop. Empty → nothing shown.
    private func presentFallbackAds(
        response: AdLoadResponse,
        autoStoreRedirect: AutoStoreRedirect?,
        onAutoStoreRedirect: @escaping @MainActor () -> Void,
        onAllClosed: @escaping @MainActor () -> Void
    ) {
        #if os(iOS)
        let ready = prefetchedFallbacks
        let prefetch = fallbackPrefetch
        prefetchedFallbacks = nil
        fallbackPrefetch = nil
        if let ready {
            presentFallbackWindow(ready, response: response, autoStoreRedirect: autoStoreRedirect, onAutoStoreRedirect: onAutoStoreRedirect, onAllClosed: onAllClosed)
        } else if let prefetch {
            // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
            Task { [weak self] in await Self.awaitPrefetchAndPresent(ad: self, prefetch: prefetch, response: response, autoStoreRedirect: autoStoreRedirect, onAutoStoreRedirect: onAutoStoreRedirect, onAllClosed: onAllClosed) }
        } else {
            onAllClosed()
        }
        #else
        onAllClosed()
        #endif
    }

    #if os(iOS)
    /// Prefetch-await task body (named method — see the task-shape note in TelemetryManager):
    /// wait for the in-flight prefetch, then present. Static with an optional `ad` so a released
    /// ad object still completes the close flow via `onAllClosed`, as before.
    @MainActor
    private static func awaitPrefetchAndPresent(
        ad: SimulaInterstitialAd?,
        prefetch: Task<[FallbackAd], Never>,
        response: AdLoadResponse,
        autoStoreRedirect: AutoStoreRedirect?,
        onAutoStoreRedirect: @escaping @MainActor () -> Void,
        onAllClosed: @escaping @MainActor () -> Void
    ) async {
        let ads = await prefetch.value
        guard let ad else { onAllClosed(); return }
        ad.presentFallbackWindow(ads, response: response, autoStoreRedirect: autoStoreRedirect, onAutoStoreRedirect: onAutoStoreRedirect, onAllClosed: onAllClosed)
    }
    #endif

    /// Presents the fallback ad window for `ads` (fires `onAllClosed` immediately if empty). Best-effort.
    /// `response` threads the serve's CTA routing context (destination / raw store link /
    /// attribution) into the end-screen WebViews for the deterministic store route.
    private func presentFallbackWindow(
        _ ads: [FallbackAd],
        response: AdLoadResponse,
        autoStoreRedirect: AutoStoreRedirect?,
        onAutoStoreRedirect: @escaping @MainActor () -> Void,
        onAllClosed: @escaping @MainActor () -> Void
    ) {
        #if os(iOS)
        guard !ads.isEmpty else { onAllClosed(); return }
        let presenter = FallbackAdPresenter()
        let didPresent = presenter.present(
            ads: ads,
            ctaTrackingUrl: response.trackingUrl,
            ctaDestination: response.destinationKind,
            ctaStoreUrl: response.iosStoreUrl,
            attribution: response.skanAttribution,
            autoStoreRedirect: autoStoreRedirect,
            onAutoStoreRedirect: onAutoStoreRedirect,
            onAdClick: { [weak self] in guard let self else { return }; self.delegate?.interstitialDidClick(self) }
        ) { [weak self] in
            self?.fallbackPresenter = nil
            onAllClosed()
        }
        if didPresent { self.fallbackPresenter = presenter } else { onAllClosed() }
        #else
        onAllClosed()
        #endif
    }
}
