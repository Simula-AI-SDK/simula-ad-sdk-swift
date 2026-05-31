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

    /// `CLICKED` — the user selected a game in the menu.
    func interstitialDidClick(_ ad: SimulaInterstitialAd)

    /// `EARNED_REWARD` — reserved for a future reward feature. Not emitted yet.
    func interstitialDidEarnReward(_ ad: SimulaInterstitialAd)

    /// `REWARD_VERIFICATION_FAILED` — reserved for a future reward feature. Not emitted yet.
    func interstitialRewardVerificationDidFail(_ ad: SimulaInterstitialAd)

    /// `CLOSED` — the ad surface was fully dismissed.
    func interstitialDidClose(_ ad: SimulaInterstitialAd)
}

public extension SimulaInterstitialAdDelegate {
    func interstitialDidLoad(_ ad: SimulaInterstitialAd) {}
    func interstitialDidFailToLoad(_ ad: SimulaInterstitialAd, error: SimulaAdError) {}
    func interstitialDidDisplay(_ ad: SimulaInterstitialAd) {}
    func interstitialDidFailToDisplay(_ ad: SimulaInterstitialAd, error: SimulaAdError) {}
    func interstitialDidClick(_ ad: SimulaInterstitialAd) {}
    func interstitialDidEarnReward(_ ad: SimulaInterstitialAd) {}
    func interstitialRewardVerificationDidFail(_ ad: SimulaInterstitialAd) {}
    func interstitialDidClose(_ ad: SimulaInterstitialAd) {}
}

// MARK: - SimulaAdError

/// Reasons a `SimulaInterstitialAd` failed to load or display.
public enum SimulaAdError: LocalizedError, Sendable {
    /// `SimulaAds.initialize(apiKey:)` was not called (or the key was invalid).
    case notInitialized
    /// A server session could not be created.
    case noSession
    /// The catalog returned no playable games (no-fill).
    case noFill
    /// `show()` was called before an ad was loaded.
    case notReady
    /// `show()` was called while an ad was already showing.
    case alreadyShowing
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
            return "No games available to show right now (no fill)."
        case .notReady:
            return "No ad is ready. Call load() and wait for LOADED before show()."
        case .alreadyShowing:
            return "An interstitial is already being shown."
        case .unsupportedPlatform:
            return "The imperative interstitial is only supported on iOS."
        case .network(let underlying):
            return underlying.errorDescription
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
/// `show(...)` presents an invite teaser first (`DISPLAYED`); tapping its CTA
/// (`CLICKED`) opens the game catalog menu → game → post-game-ad. The teaser +
/// menu + game + ad together are the ad unit. Reward events (`EARNED_REWARD` /
/// `REWARD_VERIFICATION_FAILED`) and `minPlayThreshold` are reserved for a future
/// reward feature and are not active yet.
///
/// Usage:
/// ```swift
/// let ad = SimulaInterstitialAd(adUnitId: "placement_id")
/// ad.delegate = self
/// ad.load()
/// // later, once LOADED:
/// ad.show(charID: "char_123", charName: "Luna", charImage: "https://.../a.png")
/// ```
@MainActor
public final class SimulaInterstitialAd {
    // MARK: - Configuration

    /// The placement identifier for this ad instance.
    public let adUnitId: String

    /// Minimum play time (seconds) before a reward is earned. Reserved for a
    /// future reward feature; currently stored but unused.
    public let minPlayThreshold: TimeInterval

    /// Receives lifecycle events.
    public weak var delegate: SimulaInterstitialAdDelegate?

    // MARK: - Optional menu configuration
    //
    // `show(...)` keeps the spec's four-argument shape, so menu-level options are
    // configured on the instance instead.

    /// Theme applied to the presented game menu.
    public var theme: MiniGameTheme = MiniGameTheme()
    /// Conversation context forwarded for contextual targeting.
    public var messages: [Message] = []
    /// Maximum number of games shown in the menu grid.
    public var maxGamesToShow: MaxGamesToShow = .six
    /// Whether the character delegates play to the game.
    public var delegateChar: Bool = true

    // Invite teaser — the first screen `show()` presents, before the menu.

    /// Headline shown on the invite teaser.
    public var invitationText: String = "Want to play a game?"
    /// CTA button label on the invite teaser.
    public var ctaText: String = "Play a Game"
    /// Optional background image URL for the teaser. `nil` uses the bundled default.
    public var backgroundImage: String?
    /// Theme applied to the invite teaser.
    public var inviteTheme: MiniGameInterstitialTheme = MiniGameInterstitialTheme()

    // MARK: - State

    private enum State {
        case idle
        case loading
        case ready(CatalogResponse)
        case showing
    }

    private var state: State = .idle
    private var loadTask: Task<Void, Never>?
    private let api = SimulaAPI()

    #if os(iOS)
    private var presenter: InterstitialPresenter?
    #endif

    // MARK: - Init

    public init(adUnitId: String, minPlayThreshold: TimeInterval = 0) {
        self.adUnitId = adUnitId
        self.minPlayThreshold = minPlayThreshold
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
        loadTask = Task { [weak self] in
            guard let self else { return }

            let sessionId = await provider.ensureSession()
            if Task.isCancelled { return }
            guard let sessionId, !sessionId.isEmpty else {
                self.failLoad(.noSession)
                return
            }

            do {
                let catalog = try await self.api.fetchCatalog()
                if Task.isCancelled { return }
                guard !catalog.games.isEmpty else {
                    self.failLoad(.noFill)
                    return
                }
                #if os(iOS)
                WebViewPool.shared.prewarm()
                #endif
                self.state = .ready(catalog)
                self.delegate?.interstitialDidLoad(self)
            } catch let apiError as SimulaAPIError {
                self.failLoad(.network(apiError))
            } catch {
                self.failLoad(.network(.invalidResponse))
            }
        }
    }

    // MARK: - Show

    /// Presents the loaded ad's invite teaser. Fires `DISPLAYED` on success or
    /// `DISPLAY_FAILED` when no ad is ready / one is already showing / the platform
    /// is unsupported. Tapping the teaser CTA fires `CLICKED` and opens the menu.
    ///
    /// On close, fires `CLOSED` and automatically preloads the next ad.
    ///
    /// - Parameters:
    ///   - charID: Character identifier used to contextualize the games.
    ///   - charName: Character display name shown in the menu header.
    ///   - charImage: Character avatar URL.
    ///   - charDesc: Optional character description forwarded for targeting.
    public func show(
        charID: String,
        charName: String,
        charImage: String,
        charDesc: String? = nil
    ) {
        let catalog: CatalogResponse
        switch state {
        case .ready(let loaded):
            catalog = loaded
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
        self.presenter = presenter
        state = .showing

        presenter.present(
            provider: provider,
            preloadedCatalog: catalog,
            charID: charID,
            charName: charName,
            charImage: charImage,
            charDesc: charDesc,
            invitationText: invitationText,
            ctaText: ctaText,
            backgroundImage: backgroundImage,
            inviteTheme: inviteTheme,
            menuTheme: theme,
            messages: messages,
            maxGamesToShow: maxGamesToShow,
            delegateChar: delegateChar,
            onClick: { [weak self] in
                guard let self else { return }
                self.delegate?.interstitialDidClick(self)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.presenter = nil
                self.state = .idle
                self.delegate?.interstitialDidClose(self)
                // Preload the next ad after close.
                self.load()
            }
        )

        delegate?.interstitialDidDisplay(self)
        #else
        failDisplay(.unsupportedPlatform)
        #endif
    }

    // MARK: - Failure helpers

    private func failLoad(_ error: SimulaAdError) {
        state = .idle
        delegate?.interstitialDidFailToLoad(self, error: error)
    }

    private func failDisplay(_ error: SimulaAdError) {
        delegate?.interstitialDidFailToDisplay(self, error: error)
    }
}
