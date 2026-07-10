import Foundation

// MARK: - SimulaRewardedAdDelegate

/// Receives lifecycle events for a `SimulaRewardedAd`.
///
/// Method names follow the SDK's full-screen-ad conventions (shared with the
/// interstitial). The canonical cross-platform event names are noted on each
/// method. All methods have default no-op implementations, so conformers implement
/// only the events they care about. Events are delivered on the main thread.
public protocol SimulaRewardedAdDelegate: AnyObject {
    /// `LOADED` — a rewarded minigame was preloaded and is ready to `show`.
    func rewardedDidLoad(_ ad: SimulaRewardedAd)

    /// `LOAD_FAILED` — `load()` could not produce a ready ad.
    func rewardedDidFailToLoad(_ ad: SimulaRewardedAd, error: SimulaAdError)

    /// `DISPLAYED` — the rewarded surface was presented full-screen (the "shown" signal).
    func rewardedDidDisplay(_ ad: SimulaRewardedAd)

    /// `IMPRESSION` — a billable impression was recorded (the billable-impression signal), fired
    /// ~2 seconds after the playable begins to render, independent of the reward gate. Distinct from
    /// `DISPLAYED`; followed immediately by `PAID`.
    func rewardedDidRecordImpression(_ ad: SimulaRewardedAd)

    /// `PAID` — the estimated revenue for this impression (the paid event). Fired together
    /// with `IMPRESSION`; `value` is already on-device from load time (no network round-trip). Use it
    /// for your own analytics — the backend's impression confirmation remains the source of truth for
    /// billing.
    func rewardedDidPay(_ ad: SimulaRewardedAd, value: AdValue)

    /// `DISPLAY_FAILED` — `show()` could not present the ad.
    func rewardedDidFailToDisplay(_ ad: SimulaRewardedAd, error: SimulaAdError)

    /// `EARNED_REWARD` — the user played for at least `ad_behavior.close.delay_seconds`
    /// before dismissing. Fires on close, before server verification completes.
    func rewardedDidEarnReward(_ ad: SimulaRewardedAd)

    /// `REWARD_VERIFIED` — the server verified the play and fired the publisher's
    /// SSV postback. `token` is the publisher-facing reward token (may be `nil` when
    /// the call was an idempotent re-verification of an already-claimed reward).
    func rewardedDidVerifyReward(_ ad: SimulaRewardedAd, token: String?)

    /// `REWARD_VERIFICATION_FAILED` — verification could not be completed (it may
    /// still be retried in the background from the persistent queue).
    func rewardedRewardVerificationDidFail(_ ad: SimulaRewardedAd, error: Error)

    /// `CLICKED` — the user tapped the playable's CTA or the mid-ad store prompt. A
    /// gesture-initiated tap only (pixels and JS/meta auto-redirects don't fire it). Mirrors
    /// the interstitial's `interstitialDidClick`.
    func rewardedDidClick(_ ad: SimulaRewardedAd)

    /// `CLOSED` — the rewarded surface was fully dismissed.
    func rewardedDidClose(_ ad: SimulaRewardedAd)
}

public extension SimulaRewardedAdDelegate {
    func rewardedDidLoad(_ ad: SimulaRewardedAd) {}
    func rewardedDidFailToLoad(_ ad: SimulaRewardedAd, error: SimulaAdError) {}
    func rewardedDidDisplay(_ ad: SimulaRewardedAd) {}
    func rewardedDidRecordImpression(_ ad: SimulaRewardedAd) {}
    func rewardedDidPay(_ ad: SimulaRewardedAd, value: AdValue) {}
    func rewardedDidFailToDisplay(_ ad: SimulaRewardedAd, error: SimulaAdError) {}
    func rewardedDidEarnReward(_ ad: SimulaRewardedAd) {}
    func rewardedDidVerifyReward(_ ad: SimulaRewardedAd, token: String?) {}
    func rewardedRewardVerificationDidFail(_ ad: SimulaRewardedAd, error: Error) {}
    func rewardedDidClick(_ ad: SimulaRewardedAd) {}
    func rewardedDidClose(_ ad: SimulaRewardedAd) {}
}

// MARK: - SimulaRewardedAd

/// An imperative, preloadable full-screen rewarded minigame ad.
///
/// Lifecycle mirrors `SimulaInterstitialAd`: configure once, `load()` to preload,
/// then `show()` to present. `show()` renders the playable minigame iframe full
/// screen. The reward is earned by playing for at least `ad_behavior.close.delay_seconds`
/// (returned by the server at load), the same gate that ungates the close button; an exit
/// confirmation appears if the user tries to leave before the threshold.
///
/// On a qualifying dismiss, `EARNED_REWARD` fires and the SDK verifies the play
/// server-side (`/minigames/verify-reward`) off the UI path via a durable, idempotent
/// retry queue — the backend fires the publisher's SSV postback. `REWARD_VERIFIED`
/// (with the token) or `REWARD_VERIFICATION_FAILED` follows.
///
/// Usage:
/// ```swift
/// let ad = SimulaRewardedAd(adUnitId: "placement_id")
/// ad.delegate = self
/// ad.load()
/// // later, once LOADED:
/// ad.show()
/// ```
@MainActor
public final class SimulaRewardedAd {
    // MARK: - Configuration

    /// The placement identifier for this ad instance.
    public let adUnitId: String

    /// Receives lifecycle events.
    public weak var delegate: SimulaRewardedAdDelegate?

    /// A loaded ad expires this long after it became ready (staleness).
    private static let staleAfter: TimeInterval = 60 * 60 // 1 hour
    /// Re-loads of the same dedup key are blocked for this long.
    private static let dedupWindow: TimeInterval = 5 * 60 // 5 minutes

    // MARK: - State

    private enum State {
        case idle
        case loading
        /// `loadedAt` is when the ad became ready (used for staleness).
        case ready(RewardedInitResponse, loadedAt: Date)
        case showing(RewardedInitResponse)
    }

    private var state: State = .idle
    private var loadTask: Task<Void, Never>?
    private var sessionId: String?
    private let api = SimulaAPI()

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
    // nonisolated so the (off-main, @Sendable) reward-verification callback can read it.
    private nonisolated static let adFormat = "rewarded"

    #if os(iOS)
    private var presenter: RewardedPresenter?
    /// Holds the post-close fallback ad window while it's on screen (parity with the minigame's
    /// post-game ad flow).
    private var fallbackPresenter: FallbackAdPresenter?
    /// Background prefetch of the post-close fallback screens, kicked off while the minigame is on
    /// screen so they present instantly on close (no fetch-after-close flash). Consumed once in
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

    // MARK: - Load

    /// Preloads a rewarded minigame for the given character context.
    ///
    /// The character fields are sent on the `/load/rewarded` request so the backend
    /// can target the creative; all are optional. Behavior:
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
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        loadTask = Task { [weak self] in await self?.runLoad(provider: provider, charId: charId, charName: charName, charImage: charImage, charDesc: charDesc) }
    }

    /// Load task body (named method — see the task-shape note in TelemetryManager).
    private func runLoad(
        provider: SimulaProvider,
        charId: String?,
        charName: String?,
        charImage: String?,
        charDesc: String?
    ) async {
        let sessionId = await provider.ensureSession()
        if Task.isCancelled { return }
        guard let sessionId, !sessionId.isEmpty else {
            failLoad(.noSession)
            return
        }
        self.sessionId = sessionId
        // The real session id is now known. Refresh the dedup key — the
        // synchronous gate at load() time may have keyed on an empty session
        // during cold-start warm-up — so a subsequent same-key load() still
        // deduplicates. `currentKeyAt` intentionally stays at the original load time.
        currentKey = Self.dedupKey(adUnitId: adUnitId, charId: charId, charName: charName, sessionId: sessionId)

        do {
            let response = try await api.loadRewarded(
                adUnitId: adUnitId,
                sessionId: sessionId,
                charId: charId,
                charName: charName,
                charImage: charImage,
                charDesc: charDesc,
                // AdContext (contextual targeting) now rides on the rewarded request too, read from
                // the same provider-level store the native surface uses.
                context: provider.adContext
            )
            if Task.isCancelled { return }
            // A rewarded ad with no iframe to render is a no-fill.
            guard !response.iframeUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failLoad(.noFill)
                return
            }
            #if os(iOS)
            // Warm a web view so `show()` doesn't pay WebView cold-start on the
            // critical path.
            WebViewPool.shared.prewarm()
            #endif
            Telemetry.shared.recordLifecycle(
                stage: "load_success", adFormat: Self.adFormat, adUnitId: adUnitId,
                adId: response.impressionId, serveId: nil, durationMs: msSince(loadStartNanos), errorCode: nil
            )
            state = .ready(response, loadedAt: Date())
            delegate?.rewardedDidLoad(self)
        } catch let apiError as SimulaAPIError {
            Telemetry.shared.recordError(signature: "rewarded:load", errorCode: "\(apiError)", message: apiError.errorDescription, breadcrumb: "SimulaRewardedAd.load")
            // ad_unit_not_found is a distinct, non-retryable misconfiguration — surface it as its
            // own case rather than burying it in the generic .network bucket.
            if case .adUnitNotFound = apiError {
                failLoad(.adUnitNotFound)
            } else {
                failLoad(.network(apiError))
            }
        } catch {
            Telemetry.shared.recordError(signature: "rewarded:load", errorCode: "\(type(of: error))", message: error.localizedDescription, breadcrumb: "SimulaRewardedAd.load")
            failLoad(.network(.invalidResponse))
        }
    }

    /// Dedup key: (ad unit id, character id, character name, current session id),
    /// joined with a NUL separator so values containing spaces can't collide.
    private static func dedupKey(adUnitId: String, charId: String?, charName: String?, sessionId: String?) -> String {
        [adUnitId, charId ?? "", charName ?? "", sessionId ?? ""].joined(separator: "\u{0}")
    }

    // MARK: - Show

    /// Presents the loaded minigame full-screen. Fires `DISPLAYED` on success or
    /// `DISPLAY_FAILED` when no ad is ready / one is already showing / the platform
    /// is unsupported. On a qualifying dismiss, `EARNED_REWARD` fires and the play is
    /// verified server-side. On close, fires `CLOSED` and preloads the next ad.
    public func show() {
        let response: RewardedInitResponse
        switch state {
        case .ready(let loaded, let loadedAt):
            // A loaded ad expires after 1 hour. Drop it (back to idle so the host can
            // load() again — the dedup window is long gone) and report stale.
            if Date().timeIntervalSince(loadedAt) > Self.staleAfter {
                state = .idle
                failDisplay(.stale)
                return
            }
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

        let presenter = RewardedPresenter()
        showStartNanos = DispatchTime.now().uptimeNanoseconds
        // Captured by value for the teardown salvage: the presenters self-retain while on
        // screen, so the close flow below can run after the host destroyed this ad object —
        // with `self == nil` — and must still be able to enqueue an earned reward.
        let salvageSessionId = sessionId
        let salvageAdUnitId = adUnitId
        let didPresent = presenter.present(
            impressionId: response.impressionId,
            apiKey: provider.apiKey,
            iframeUrl: response.iframeUrl,
            renderedHtml: response.renderedHtml,
            close: response.adBehavior?.close,
            storePrompt: response.adBehavior?.storePrompt,
            trackingUrl: response.trackingUrl,
            destination: response.destinationKind,
            storeOpen: response.adBehavior?.storeOpen ?? .skstoreproduct,
            storeUrl: response.iosStoreUrl,
            attribution: response.skanAttribution,
            autoStoreRedirect: response.adBehavior?.autoStoreRedirect,
            onClick: { [weak self] in
                guard let self else { return }
                // CLICKED — a user-gesture CTA / store-prompt tap (parity with the interstitial).
                Telemetry.shared.recordLifecycle(stage: "click", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.impressionId, serveId: nil)
                self.delegate?.rewardedDidClick(self)
            },
            onImpression: { [weak self] in
                guard let self else { return }
                // IMPRESSION + PAID (the billable impression + paid event), fired together ~2s
                // after begin-to-render by the presenter (foreground-aware), independent of the reward
                // gate. The `/seen` beacon is the billing source of truth; `didPay` is local analytics.
                Telemetry.shared.recordLifecycle(stage: "impression", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.impressionId, serveId: nil)
                Telemetry.shared.recordLifecycle(stage: "paid", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.impressionId, serveId: nil)
                self.delegate?.rewardedDidRecordImpression(self)
                self.delegate?.rewardedDidPay(self, value: response.adValue)
                // Durable billable-impression beacon (was a fire-and-forget trackImpression).
                AdBeaconManager.shared.enqueue(impressionId: response.impressionId, action: "seen", adFormat: Self.adFormat, adUnitId: self.adUnitId)
            },
            onClose: { [weak self] earned, elapsedPlayTime in
                guard let self else {
                    // The host destroyed this ad object while the playable was up (the presenter
                    // self-retains, so the unit stayed on screen). Delegates and fallback screens
                    // die with the object, but an earned reward must not — enqueue the durable,
                    // idempotent verification directly (parity with Android's teardown salvage).
                    SimulaRewardedAd.salvageReward(
                        earned: earned,
                        impressionId: response.impressionId,
                        sessionId: salvageSessionId,
                        elapsedPlayTime: elapsedPlayTime,
                        adUnitId: salvageAdUnitId
                    )
                    return
                }
                self.presenter = nil
                self.state = .idle
                Telemetry.shared.recordLifecycle(stage: "closed", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.impressionId, serveId: nil)
                // Show the fallback ad screens on close (parity with the minigame post-game flow).
                // Uses the background prefetch started at display time, so there's no fetch-after-close gap.
                // END_SCREEN_N auto_store_redirect opens the primary ad's store at the matching index.
                //
                // Reward verification is deferred to `onAllClosed` — the reward is contingent on the
                // user completing the WHOLE ad unit (playable + every fallback screen), not just
                // closing the playable. With no fallback screens it fires immediately on close.
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
                        guard let self else {
                            // The host destroyed this ad object during the fallback screens (they
                            // self-retain and stay up): still salvage the earned reward.
                            SimulaRewardedAd.salvageReward(
                                earned: earned,
                                impressionId: response.impressionId,
                                sessionId: salvageSessionId,
                                elapsedPlayTime: elapsedPlayTime,
                                adUnitId: salvageAdUnitId
                            )
                            return
                        }
                        // CLOSE fires after the LAST fallback screen (not the playable close), then
                        // reward earn/verification (handleClose) — preserving the close → complete order.
                        self.delegate?.rewardedDidClose(self)
                        self.handleClose(response: response, earned: earned, elapsedPlayTime: elapsedPlayTime)
                        // Auto-preload the next ad only now that the WHOLE unit is closed (Android
                        // parity). Preloading at playable close made the next LOADED land BEFORE
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
            // Couldn't present (no window scene). Keep the loaded ad so the host can
            // retry; report DISPLAY_FAILED without a bogus DISPLAYED/CLOSED. `state`
            // never left `.ready`, so the ad stays showable.
            failDisplay(.noPresentationContext)
            return
        }

        state = .showing(response)
        self.presenter = presenter
        // Prefetch the post-close fallback screens now, in the background, so they're ready the
        // instant the minigame closes — fetching after close left a gap that flashed the screen behind.
        // GET /load/fallbacks is side-effect-free (no impression tracking), so this reports nothing early.
        startFallbackPrefetch(impressionId: response.impressionId)
        Telemetry.shared.recordLifecycle(
            stage: "displayed", adFormat: Self.adFormat, adUnitId: adUnitId,
            adId: response.impressionId, serveId: nil, durationMs: msSince(showStartNanos), errorCode: nil
        )
        delegate?.rewardedDidDisplay(self)
        // SHOWN — the `/shown` beacon, fired at present. The
        // billable IMPRESSION + PAID fire ~2s later via the presenter's `onImpression` (above).
        // Durable beacon (was a fire-and-forget trackShown).
        AdBeaconManager.shared.enqueue(impressionId: response.impressionId, action: "shown", adFormat: Self.adFormat, adUnitId: self.adUnitId)
        #else
        failDisplay(.unsupportedPlatform)
        #endif
    }

    // MARK: - Preview (debug / QA)

    /// A real App Store URL so a store-prompt tap from `showPreview` routes somewhere.
    private static let previewTrackingURL = "https://apps.apple.com/app/id375380948"

    /// A self-contained placeholder "playable" so `showPreview` can render the play-to-earn gate +
    /// store-prompt chrome over a visible surface without loading a network iframe.
    private static let previewMinigameHTML = """
    <!doctype html><html><head><meta name="viewport" \
    content="width=device-width, initial-scale=1, viewport-fit=cover"></head>\
    <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;\
    background:linear-gradient(160deg,#0f766e,#7c3aed);\
    font-family:-apple-system,system-ui,sans-serif;color:#fff;text-align:center">\
    <div><div style="font-size:22px;font-weight:700">Rewarded Minigame Preview</div>\
    <div style="opacity:.8;margin-top:8px;font-size:15px">Mid-ad store prompt — no network</div></div>\
    </body></html>
    """

    /// Present the rewarded minigame with a **hardcoded** placeholder playable and a mid-ad store
    /// prompt — no network call and no impression tracked. Lets a host/sample app preview the
    /// store-prompt badge timing: it appears at half the play-to-earn duration (`durationSeconds / 2`)
    /// and is removed the moment the reward unlocks. iOS only.
    ///
    /// - Parameters:
    ///   - durationSeconds: the play-to-earn gate; the badge shows at `durationSeconds / 2`.
    ///   - storePrompt: whether to show the mid-ad store-prompt badge.
    ///   - storePromptPlatform: `.ios` (▶| App Store) / `.android` (▶| Google Play).
    public func showPreview(
        durationSeconds: Int = 8,
        storePrompt: Bool = true,
        storePromptPlatform: StorePromptPlatform = .ios
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
        // The reward/close pill always sits top-right, so the badge defaults to the opposite
        // corner (top-left) — matching the server's collision resolution for a rewarded play.
        let prompt = storePrompt
            ? StorePrompt(enabled: true, position: .topLeft, platform: storePromptPlatform)
            : nil
        // The play-to-earn gate now lives on `ad_behavior.close.delay_seconds`; preview drives it directly.
        let duration = max(0, durationSeconds)

        let presenter = RewardedPresenter()
        let didPresent = presenter.present(
            impressionId: "", // empty → no impression is ever tracked for a preview
            apiKey: provider.apiKey,
            iframeUrl: "",
            close: CloseBehavior(delaySeconds: duration),
            storePrompt: prompt,
            trackingUrl: Self.previewTrackingURL,
            destination: .appstore,
            storeOpen: .skstoreproduct,
            previewHTML: Self.previewMinigameHTML,
            onClick: { [weak self] in
                // Preview is local-only: surface the click callback, no telemetry.
                guard let self else { return }
                self.delegate?.rewardedDidClick(self)
            },
            onImpression: { [weak self] in
                guard let self else { return }
                // Preview is local-only: surface the callbacks (with a $0 estimate) but no beacon.
                self.delegate?.rewardedDidRecordImpression(self)
                self.delegate?.rewardedDidPay(self, value: AdValue.fromBidCpm(0))
            },
            onClose: { [weak self] earned, _ in
                guard let self else { return }
                self.presenter = nil
                self.state = .idle
                if earned { self.delegate?.rewardedDidEarnReward(self) }
                self.delegate?.rewardedDidClose(self)
                // Preview is local-only: no reward verification, no fallback, no auto-preload.
            }
        )

        guard didPresent else {
            failDisplay(.noPresentationContext)
            return
        }
        // Track a synthetic showing state so a second showPreview is a no-op.
        state = .showing(RewardedInitResponse(impressionId: "", iframeUrl: ""))
        self.presenter = presenter
        delegate?.rewardedDidDisplay(self)
        // Preview is local-only: deliberately no `trackImpression`.
        #else
        failDisplay(.unsupportedPlatform)
        #endif
    }

    // MARK: - Close / verify

    /// On a qualifying dismiss: fire EARNED_REWARD, then enqueue a durable, idempotent
    /// server verification. The completion routes the token / failure back to the
    /// delegate on the main thread.
    private func handleClose(response: RewardedInitResponse, earned: Bool, elapsedPlayTime: Double) {
        guard earned, let sessionId = self.sessionId, !sessionId.isEmpty else { return }

        Telemetry.shared.recordLifecycle(stage: "reward_earned", adFormat: Self.adFormat, adUnitId: adUnitId, adId: response.impressionId, serveId: nil)
        delegate?.rewardedDidEarnReward(self)

        Self.enqueueVerification(
            impressionId: response.impressionId,
            sessionId: sessionId,
            elapsedPlayTime: elapsedPlayTime,
            adUnitId: adUnitId,
            ad: self
        )
    }

    /// Teardown salvage (parity with Android's `reward_salvaged_on_teardown`): the ad object
    /// was destroyed while its unit was still on screen, so the normal completion path
    /// (`handleClose`) can never run. The earned reward must not be lost with it — enqueue the
    /// durable, idempotent verification directly so the server-side SSV postback still fires;
    /// only the delegate callbacks die with the object.
    private static func salvageReward(
        earned: Bool,
        impressionId: String,
        sessionId: String?,
        elapsedPlayTime: Double,
        adUnitId: String
    ) {
        guard earned, let sessionId, !sessionId.isEmpty, !impressionId.isEmpty else { return }
        Telemetry.shared.recordLifecycle(stage: "reward_salvaged_on_teardown", adFormat: adFormat, adUnitId: adUnitId, adId: impressionId, serveId: nil)
        enqueueVerification(
            impressionId: impressionId,
            sessionId: sessionId,
            elapsedPlayTime: elapsedPlayTime,
            adUnitId: adUnitId,
            ad: nil
        )
    }

    /// Enqueues the durable server verification for an earned play and records its telemetry.
    /// Static and value-typed so the teardown salvage can reuse it after the ad object is gone
    /// (`ad == nil` → the SSV postback still fires; only the delegate dispatch is skipped).
    private static func enqueueVerification(
        impressionId: String,
        sessionId: String,
        elapsedPlayTime: Double,
        adUnitId: String,
        ad: SimulaRewardedAd?
    ) {
        // Captured as values so the verification callback (off-main, possibly after retries)
        // records telemetry without touching the ad. End-to-end latency includes queue backoff.
        // The consolidated `impressionId` is the single id; the verify wire body still names it
        // `serve_id`, but telemetry carries it in `adId` (serve id is gone) for cross-format parity.
        let adId = impressionId
        let serveId: String? = nil
        let verifyStartNanos = DispatchTime.now().uptimeNanoseconds

        RewardVerificationManager.shared.queueVerification(
            serveId: impressionId,
            sessionId: sessionId,
            elapsedPlayTime: elapsedPlayTime,
            adUnitId: adUnitId
        ) { [weak ad] result in
            let verifyMs = Int((DispatchTime.now().uptimeNanoseconds &- verifyStartNanos) / 1_000_000)
            switch result {
            case .success:
                Telemetry.shared.recordOperation(name: "reward_verification", durationMs: verifyMs, success: true)
                Telemetry.shared.recordLifecycle(stage: "reward_verified", adFormat: SimulaRewardedAd.adFormat, adUnitId: adUnitId, adId: adId, serveId: serveId, durationMs: verifyMs, errorCode: nil)
            case .failure(let error):
                Telemetry.shared.recordOperation(name: "reward_verification", durationMs: verifyMs, success: false)
                Telemetry.shared.recordLifecycle(stage: "reward_verification_failed", adFormat: SimulaRewardedAd.adFormat, adUnitId: adUnitId, adId: adId, serveId: serveId, durationMs: verifyMs, errorCode: "verify_failed")
                Telemetry.shared.recordError(signature: "rewarded:verify", errorCode: "\(type(of: error))", message: error.localizedDescription, breadcrumb: "RewardVerificationManager.queueVerification")
            }
            // GCD main-queue hop, not `Task { @MainActor }` — the verification callback lands
            // off-main and only needs to deliver a delegate call on main (see the concurrency
            // note in TelemetryManager). The dispatch guarantees main before the isolation cast.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ad?.dispatchVerificationResult(result) }
            }
        }
    }

    /// Reward-verification delegate dispatch (named method, invoked via the guaranteed-main
    /// GCD hop above). `@MainActor` via the class, matching the prior explicit hop.
    private func dispatchVerificationResult(_ result: Result<String?, Error>) {
        switch result {
        case .success(let token):
            delegate?.rewardedDidVerifyReward(self, token: token)
        case .failure(let error):
            delegate?.rewardedRewardVerificationDidFail(self, error: error)
        }
    }

    // MARK: - Failure helpers

    private func failLoad(_ error: SimulaAdError) {
        state = .idle
        Telemetry.shared.recordLifecycle(
            stage: "load_fail", adFormat: Self.adFormat, adUnitId: adUnitId,
            adId: nil, serveId: nil, durationMs: msSince(loadStartNanos), errorCode: error.telemetryCode
        )
        delegate?.rewardedDidFailToLoad(self, error: error)
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
        delegate?.rewardedDidFailToLoad(self, error: error)
    }

    private func failDisplay(_ error: SimulaAdError) {
        Telemetry.shared.recordLifecycle(stage: "show_fail", adFormat: Self.adFormat, adUnitId: adUnitId, errorCode: error.telemetryCode)
        delegate?.rewardedDidFailToDisplay(self, error: error)
    }

    /// Monotonic ms since the given marker (nil if not started).
    private func msSince(_ startNanos: UInt64) -> Int? {
        guard startNanos != 0 else { return nil }
        return Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000)
    }

    // MARK: - Fallback ads (post-close)

    /// After the minigame closes, fetch the serve's fallback ad screens
    /// (`GET /load/fallbacks/{impressionId}`) and — when any are returned — present them
    /// full-screen in reveal order, mirroring the minigame menu's post-game ad flow.
    /// Best-effort: a missing id, network error, or empty response simply shows nothing.
    /// Starts a background prefetch of the serve's fallback ad screens
    /// (`GET /load/fallbacks/{impressionId}`) while the minigame is on screen, so they're ready the
    /// instant the user closes. Best-effort: a missing id / network error / empty response resolves
    /// to an empty list (nothing shown). The fetch is side-effect-free server-side.
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
    private static func runFallbackPrefetch(api: SimulaAPI, impressionId: String, ad: SimulaRewardedAd?) async -> [FallbackAd] {
        let ads: [FallbackAd]
        do { ads = try await api.fetchFallbacks(impressionId: impressionId) } catch { ads = [] }
        ad?.prefetchedFallbacks = ads
        return ads
    }
    #endif

    /// Presents the prefetched fallback ad screens on close. Synchronous when the prefetch has
    /// landed (the common case), so the fallback window is up before the minigame window is torn
    /// down (see the presenter's `dismiss`) — no handoff flash; awaits only if the user closed
    /// before the prefetch finished. Empty → nothing shown. `response` carries the serve's CTA
    /// routing context (destination / raw store link / attribution) into the end-screen WebViews.
    private func presentFallbackAds(
        response: RewardedInitResponse,
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
            // No prefetch ran (e.g. empty impression id) — nothing to show, so the ad unit is
            // already fully closed; verify immediately.
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
        ad: SimulaRewardedAd?,
        prefetch: Task<[FallbackAd], Never>,
        response: RewardedInitResponse,
        autoStoreRedirect: AutoStoreRedirect?,
        onAutoStoreRedirect: @escaping @MainActor () -> Void,
        onAllClosed: @escaping @MainActor () -> Void
    ) async {
        let ads = await prefetch.value
        guard let ad else { onAllClosed(); return }
        ad.presentFallbackWindow(ads, response: response, autoStoreRedirect: autoStoreRedirect, onAutoStoreRedirect: onAutoStoreRedirect, onAllClosed: onAllClosed)
    }
    #endif

    /// Presents the fallback ad window for `ads` (no-op if empty). Best-effort.
    private func presentFallbackWindow(
        _ ads: [FallbackAd],
        response: RewardedInitResponse,
        autoStoreRedirect: AutoStoreRedirect?,
        onAutoStoreRedirect: @escaping @MainActor () -> Void,
        onAllClosed: @escaping @MainActor () -> Void
    ) {
        #if os(iOS)
        // No fallback screens → the playable was the whole ad unit; it's already fully closed.
        guard !ads.isEmpty else { onAllClosed(); return }
        let presenter = FallbackAdPresenter()
        let didPresent = presenter.present(
            ads: ads,
            ctaDestination: response.destinationKind,
            ctaStoreUrl: response.iosStoreUrl,
            attribution: response.skanAttribution,
            autoStoreRedirect: autoStoreRedirect,
            onAutoStoreRedirect: onAutoStoreRedirect,
            onAdClick: { [weak self] in guard let self else { return }; self.delegate?.rewardedDidClick(self) }
        ) { [weak self] in
            self?.fallbackPresenter = nil
            onAllClosed()
        }
        if didPresent {
            self.fallbackPresenter = presenter
        } else {
            // Couldn't present the fallback window (no scene) — don't strand the reward; treat the
            // unit as fully closed so verification still runs.
            onAllClosed()
        }
        #endif
    }
}
