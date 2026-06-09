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

    /// `DISPLAYED` — the ad surface was presented full-screen.
    func interstitialDidDisplay(_ ad: SimulaInterstitialAd)

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
    /// `show()` was called while an ad was already showing.
    case alreadyShowing
    /// No active window scene was available to present in.
    case noPresentationContext
    /// Imperative presentation is unavailable on this platform (iOS-only).
    case unsupportedPlatform
    /// An underlying networking error.
    case network(SimulaAPIError)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "SimulaAds is not initialized. Call SimulaAds.initialize(apiKey:) first."
        case .noSession:
            return "Could not create a session. Check the API key and network connection."
        case .noFill:
            return "No ad available to show right now (no fill)."
        case .notReady:
            return "No ad is ready. Call load() and wait for LOADED before show()."
        case .alreadyShowing:
            return "An interstitial is already being shown."
        case .noPresentationContext:
            return "No active window scene is available to present the ad."
        case .unsupportedPlatform:
            return "The imperative interstitial is only supported on iOS."
        case .network(let underlying):
            return underlying.errorDescription
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
        case .alreadyShowing: return "already_showing"
        case .noPresentationContext: return "no_presentation_context"
        case .unsupportedPlatform: return "unsupported_platform"
        case .network: return "network"
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

    // Character context is global: set it on `SimulaAds` (via `initialize` or
    // `setCharacter`), and every `load()` reads the current values from there.

    // MARK: - State

    private enum State {
        case idle
        case loading
        case ready(AdLoadResponse)
        case showing(AdLoadResponse)
    }

    private var state: State = .idle
    private var loadTask: Task<Void, Never>?
    private let api = SimulaAPI()

    // Monotonic stage markers for telemetry latencies (0 = not yet started).
    private var loadStartNanos: UInt64 = 0
    private var showStartNanos: UInt64 = 0
    private nonisolated static let adFormat = "interstitial"

    #if os(iOS)
    private var presenter: InterstitialPresenter?
    /// Holds the post-close fallback ad window while it's on screen (parity with the minigame's
    /// post-game ad flow).
    private var fallbackPresenter: FallbackAdPresenter?
    #endif

    // MARK: - Init

    public init(adUnitId: String) {
        self.adUnitId = adUnitId
    }

    // MARK: - Load

    /// Preloads an ad. Fires `LOADED` on success or `LOAD_FAILED` on failure.
    ///
    /// No-op while a load is already in flight or an ad is ready (single
    /// in-flight load per instance). Fails fast with `.notInitialized` when the
    /// SDK has not been initialized.
    public func load() {
        switch state {
        case .loading, .ready, .showing:
            return // single in-flight load; don't disturb a ready/showing ad
        case .idle:
            break
        }

        guard SimulaAds.isInitialized, let provider = SimulaAds.shared else {
            failLoad(.notInitialized)
            return
        }

        state = .loading
        loadStartNanos = DispatchTime.now().uptimeNanoseconds
        loadTask = Task { [weak self] in
            guard let self else { return }

            let sessionId = await provider.ensureSession()
            if Task.isCancelled { return }
            guard let sessionId, !sessionId.isEmpty else {
                self.failLoad(.noSession)
                return
            }

            do {
                let response = try await self.api.loadAd(
                    adUnitId: self.adUnitId,
                    sessionId: sessionId,
                    charId: SimulaAds.charId,
                    charName: SimulaAds.charName,
                    charImage: SimulaAds.charImage,
                    charDesc: SimulaAds.charDesc
                )
                if Task.isCancelled { return }
                // Fillable only when the payload carries a non-blank `rendered_html`
                // creative (whitespace-only HTML trims to nil → no-fill).
                guard response.adInserted, response.htmlCreative != nil else {
                    self.failLoad(.noFill)
                    return
                }
                #if os(iOS)
                // Warm a WKWebView so the first spin-up is off the present() critical path.
                WebViewPool.shared.prewarm()
                #endif
                Telemetry.shared.recordLifecycle(
                    stage: "load_success", adFormat: Self.adFormat, adUnitId: self.adUnitId,
                    adId: response.adId, serveId: nil, durationMs: self.msSince(self.loadStartNanos), errorCode: nil
                )
                self.state = .ready(response)
                self.delegate?.interstitialDidLoad(self)
            } catch let apiError as SimulaAPIError {
                // Genuine exception — always-sent, deduped handled error (the sampled `load_fail`
                // lifecycle event comes from failLoad()).
                Telemetry.shared.recordError(signature: "interstitial:load", errorCode: "\(apiError)", message: apiError.errorDescription, breadcrumb: "SimulaInterstitialAd.load")
                self.failLoad(.network(apiError))
            } catch {
                Telemetry.shared.recordError(signature: "interstitial:load", errorCode: "\(type(of: error))", message: error.localizedDescription, breadcrumb: "SimulaInterstitialAd.load")
                self.failLoad(.network(.invalidResponse))
            }
        }
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
        switch state {
        case .ready(let loaded):
            response = loaded
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
                Telemetry.shared.recordLifecycle(stage: "click", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.adId)
                self.delegate?.interstitialDidClick(self)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.presenter = nil
                self.state = .idle
                Telemetry.shared.recordLifecycle(stage: "closed", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.adId)
                self.delegate?.interstitialDidClose(self)
                // Show a fallback ad on close (parity with the minigame post-game flow).
                self.presentFallbackAd(adId: response.adId)
                // Preload the next ad after close.
                self.load()
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
        state = .showing(response)
        self.presenter = presenter
        Telemetry.shared.recordLifecycle(
            stage: "displayed", adFormat: Self.adFormat, adUnitId: adUnitId,
            adId: response.adId, serveId: nil, durationMs: msSince(showStartNanos), errorCode: nil
        )
        delegate?.interstitialDidDisplay(self)
        // Fire the impression once, only after the present succeeded.
        let api = self.api
        let apiKey = provider.apiKey
        let adId = response.adId
        let experiment = response.experiment
        Task { await api.trackImpression(adId: adId, apiKey: apiKey, experiment: experiment) }
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
        // Mirror the server's collision rule: render the store-prompt badge opposite the close button.
        let storePromptPosition: ClosePosition = close.position == .topRight ? .topLeft : .topRight
        let behavior = AdBehavior(
            close: close,
            storePrompt: storePrompt ? StorePrompt(enabled: true, position: storePromptPosition, platform: .ios) : nil,
            skoverlay: skOverlay ? SKOverlayConfig(enabled: true, timing: .duringPlay) : nil
        )
        let response = AdLoadResponse(
            adId: "",                     // empty → no impression is ever tracked for a preview
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
        state = .showing(response)
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

    private func failDisplay(_ error: SimulaAdError) {
        Telemetry.shared.recordLifecycle(stage: "show_fail", adFormat: Self.adFormat, adUnitId: adUnitId, errorCode: error.telemetryCode)
        delegate?.interstitialDidFailToDisplay(self, error: error)
    }

    /// Monotonic ms since the given marker (nil if not started).
    private func msSince(_ startNanos: UInt64) -> Int? {
        guard startNanos != 0 else { return nil }
        return Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000)
    }

    // MARK: - Fallback ad (post-close)

    /// After the creative closes, fetch a fallback ad for `adId` and — when one is returned —
    /// present it full-screen, mirroring the minigame's post-game ad flow. Best-effort: a missing
    /// id, network error, or empty/no-fill response simply shows nothing.
    private func presentFallbackAd(adId: String) {
        #if os(iOS)
        guard !adId.isEmpty else { return }
        let api = self.api
        Task { [weak self] in
            let url = try? await api.fetchAdForMinigame(aid: adId)
            guard let self, let url, !url.isEmpty else { return }
            let presenter = FallbackAdPresenter()
            let didPresent = presenter.present(adId: adId, iframeUrl: url) { [weak self] in
                self?.fallbackPresenter = nil
            }
            if didPresent { self.fallbackPresenter = presenter }
        }
        #endif
    }
}
