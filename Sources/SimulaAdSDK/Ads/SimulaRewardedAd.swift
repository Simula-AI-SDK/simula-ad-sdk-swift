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

    /// `DISPLAYED` — the rewarded surface was presented full-screen.
    func rewardedDidDisplay(_ ad: SimulaRewardedAd)

    /// `DISPLAY_FAILED` — `show()` could not present the ad.
    func rewardedDidFailToDisplay(_ ad: SimulaRewardedAd, error: SimulaAdError)

    /// `EARNED_REWARD` — the user played for at least `duration_seconds` before
    /// dismissing. Fires on close, before server verification completes.
    func rewardedDidEarnReward(_ ad: SimulaRewardedAd)

    /// `REWARD_VERIFIED` — the server verified the play and fired the publisher's
    /// SSV postback. `token` is the publisher-facing reward token (may be `nil` when
    /// the call was an idempotent re-verification of an already-claimed reward).
    func rewardedDidVerifyReward(_ ad: SimulaRewardedAd, token: String?)

    /// `REWARD_VERIFICATION_FAILED` — verification could not be completed (it may
    /// still be retried in the background from the persistent queue).
    func rewardedRewardVerificationDidFail(_ ad: SimulaRewardedAd, error: Error)

    /// `CLOSED` — the rewarded surface was fully dismissed.
    func rewardedDidClose(_ ad: SimulaRewardedAd)
}

public extension SimulaRewardedAdDelegate {
    func rewardedDidLoad(_ ad: SimulaRewardedAd) {}
    func rewardedDidFailToLoad(_ ad: SimulaRewardedAd, error: SimulaAdError) {}
    func rewardedDidDisplay(_ ad: SimulaRewardedAd) {}
    func rewardedDidFailToDisplay(_ ad: SimulaRewardedAd, error: SimulaAdError) {}
    func rewardedDidEarnReward(_ ad: SimulaRewardedAd) {}
    func rewardedDidVerifyReward(_ ad: SimulaRewardedAd, token: String?) {}
    func rewardedRewardVerificationDidFail(_ ad: SimulaRewardedAd, error: Error) {}
    func rewardedDidClose(_ ad: SimulaRewardedAd) {}
}

// MARK: - SimulaRewardedAd

/// An imperative, preloadable full-screen rewarded minigame ad.
///
/// Lifecycle mirrors `SimulaInterstitialAd`: configure once, `load()` to preload,
/// then `show()` to present. `show()` renders the playable minigame iframe full
/// screen. The reward is earned by playing for at least `duration_seconds` (returned
/// by the server at load); the close button is available throughout, and an exit
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

    /// Optional minimum play time (seconds) requested from the server. When `> 0`
    /// it is sent as `min_play_threshold`; the server's returned `duration_seconds`
    /// is what the SDK actually enforces.
    public var minPlayThreshold: TimeInterval

    /// Receives lifecycle events.
    public weak var delegate: SimulaRewardedAdDelegate?

    // MARK: - State

    private enum State {
        case idle
        case loading
        case ready(RewardedInitResponse)
        case showing(RewardedInitResponse)
    }

    private var state: State = .idle
    private var loadTask: Task<Void, Never>?
    private var sessionId: String?
    private let api = SimulaAPI()

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
    #endif

    // MARK: - Init

    public init(adUnitId: String, minPlayThreshold: TimeInterval = 0) {
        self.adUnitId = adUnitId
        self.minPlayThreshold = minPlayThreshold
    }

    // MARK: - Load

    /// Preloads a rewarded minigame. Fires `LOADED` on success or `LOAD_FAILED` on
    /// failure. No-op while a load is in flight or an ad is ready. Fails fast with
    /// `.notInitialized` when `SimulaAds.initialize` has not been called.
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
            self.sessionId = sessionId

            do {
                let threshold = self.minPlayThreshold > 0 ? Int(self.minPlayThreshold) : nil
                let response = try await self.api.loadRewarded(
                    adUnitId: self.adUnitId,
                    sessionId: sessionId,
                    minPlayThreshold: threshold,
                    charId: SimulaAds.charId,
                    charName: SimulaAds.charName,
                    charImage: SimulaAds.charImage,
                    charDesc: SimulaAds.charDesc
                )
                if Task.isCancelled { return }
                // A rewarded ad with no iframe to render is a no-fill.
                guard !response.iframeUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.failLoad(.noFill)
                    return
                }
                #if os(iOS)
                // Warm a web view so `show()` doesn't pay WebView cold-start on the
                // critical path.
                WebViewPool.shared.prewarm()
                #endif
                Telemetry.shared.recordLifecycle(
                    stage: "load_success", adFormat: Self.adFormat, adUnitId: self.adUnitId,
                    adId: response.adId, serveId: response.serveId, durationMs: self.msSince(self.loadStartNanos), errorCode: nil
                )
                self.state = .ready(response)
                self.delegate?.rewardedDidLoad(self)
            } catch let apiError as SimulaAPIError {
                Telemetry.shared.recordError(signature: "rewarded:load", errorCode: "\(apiError)", message: apiError.errorDescription, breadcrumb: "SimulaRewardedAd.load")
                self.failLoad(.network(apiError))
            } catch {
                Telemetry.shared.recordError(signature: "rewarded:load", errorCode: "\(type(of: error))", message: error.localizedDescription, breadcrumb: "SimulaRewardedAd.load")
                self.failLoad(.network(.invalidResponse))
            }
        }
    }

    // MARK: - Show

    /// Presents the loaded minigame full-screen. Fires `DISPLAYED` on success or
    /// `DISPLAY_FAILED` when no ad is ready / one is already showing / the platform
    /// is unsupported. On a qualifying dismiss, `EARNED_REWARD` fires and the play is
    /// verified server-side. On close, fires `CLOSED` and preloads the next ad.
    public func show() {
        let response: RewardedInitResponse
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

        let presenter = RewardedPresenter()
        showStartNanos = DispatchTime.now().uptimeNanoseconds
        let didPresent = presenter.present(
            adId: response.adId,
            apiKey: provider.apiKey,
            iframeUrl: response.iframeUrl,
            durationSeconds: response.durationSeconds,
            adVerifications: response.adVerifications,
            onClose: { [weak self] earned, elapsedPlayTime in
                guard let self else { return }
                self.presenter = nil
                self.state = .idle
                self.handleClose(response: response, earned: earned, elapsedPlayTime: elapsedPlayTime)
                Telemetry.shared.recordLifecycle(stage: "closed", adFormat: Self.adFormat, adUnitId: self.adUnitId, adId: response.adId, serveId: response.serveId)
                self.delegate?.rewardedDidClose(self)
                // Show a fallback ad on close (parity with the minigame post-game flow).
                self.presentFallbackAd(adId: response.adId)
                // Preload the next ad after close (parity with the interstitial).
                self.load()
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
        Telemetry.shared.recordLifecycle(
            stage: "displayed", adFormat: Self.adFormat, adUnitId: adUnitId,
            adId: response.adId, serveId: response.serveId, durationMs: msSince(showStartNanos), errorCode: nil
        )
        delegate?.rewardedDidDisplay(self)
        // Fire the impression once, only after the present succeeded.
        if !response.adId.isEmpty {
            let api = self.api
            let apiKey = provider.apiKey
            let adId = response.adId
            Task { await api.trackImpression(adId: adId, apiKey: apiKey) }
        }
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

        Telemetry.shared.recordLifecycle(stage: "reward_earned", adFormat: Self.adFormat, adUnitId: adUnitId, adId: response.adId, serveId: response.serveId)
        delegate?.rewardedDidEarnReward(self)

        // Captured as values so the verification callback (off-main, possibly after retries)
        // records telemetry without touching `self`. End-to-end latency includes queue backoff.
        let adUnitId = self.adUnitId
        let adId = response.adId
        let serveId = response.serveId
        let verifyStartNanos = DispatchTime.now().uptimeNanoseconds

        RewardVerificationManager.shared.queueVerification(
            serveId: response.serveId,
            sessionId: sessionId,
            elapsedPlayTime: elapsedPlayTime
        ) { [weak self] result in
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
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let token):
                    self.delegate?.rewardedDidVerifyReward(self, token: token)
                case .failure(let error):
                    self.delegate?.rewardedRewardVerificationDidFail(self, error: error)
                }
            }
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

    private func failDisplay(_ error: SimulaAdError) {
        Telemetry.shared.recordLifecycle(stage: "show_fail", adFormat: Self.adFormat, adUnitId: adUnitId, errorCode: error.telemetryCode)
        delegate?.rewardedDidFailToDisplay(self, error: error)
    }

    /// Monotonic ms since the given marker (nil if not started).
    private func msSince(_ startNanos: UInt64) -> Int? {
        guard startNanos != 0 else { return nil }
        return Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000)
    }

    // MARK: - Fallback ad (post-close)

    /// After the minigame closes, fetch a fallback ad for `adId` and — when one is returned —
    /// present it full-screen, mirroring the minigame menu's post-game ad flow. Best-effort: a
    /// missing id, network error, or empty/no-fill response simply shows nothing.
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
