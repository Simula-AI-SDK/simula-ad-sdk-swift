import Foundation

enum FallbackOutcome: Equatable, Sendable {
    case completed
    case noContent
    case loadingTimeout
    case fetchFailure
    case presentationUnavailable
    case hostUnavailable

    var unavailableReason: String? {
        switch self {
        case .completed: return nil
        case .noContent: return "no_content"
        case .loadingTimeout: return "loading_timeout"
        case .fetchFailure: return "fetch_failure"
        case .presentationUnavailable: return "presentation_unavailable"
        case .hostUnavailable: return "host_unavailable"
        }
    }

    /// Fallback delivery is best-effort. Once the playable earned a reward, infrastructure/content
    /// unavailability must not revoke it; this keeps that policy explicit at the decision point.
    func shouldVerifyEarnedReward(_ earned: Bool) -> Bool { earned }
}

struct FallbackTelemetryIdentifiers: Equatable, Sendable {
    let adId: String
    let serveId: String?

    static func rewarded(impressionId: String) -> FallbackTelemetryIdentifiers {
        FallbackTelemetryIdentifiers(adId: impressionId, serveId: nil)
    }

    static func interstitial(impressionId: String) -> FallbackTelemetryIdentifiers {
        FallbackTelemetryIdentifiers(adId: impressionId, serveId: impressionId)
    }
}

enum FallbackFetchStatus: Equatable, Sendable {
    case content
    case noContent
    case failure
}

enum FallbackFetchResult: Sendable {
    case content([FallbackAd])
    case noContent
    case failure

    var status: FallbackFetchStatus {
        switch self {
        case .content: return .content
        case .noContent: return .noContent
        case .failure: return .failure
        }
    }
}

enum FallbackLoadingResolution: Equatable, Sendable {
    case presentContent
    case finish(FallbackOutcome)
    case stale
}

func canAdvanceFallback(renderedIndex: Int, currentIndex: Int, clickHandoffIndex: Int?) -> Bool {
    renderedIndex == currentIndex && clickHandoffIndex != renderedIndex
}

/// Pure one-presentation state machine. Generation ownership makes a timeout and a late fetch
/// mutually exclusive, while terminal transitions return an outcome only once.
struct FallbackPresentationCoordinator: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case loading(Int)
        case presenting(Int)
        case terminal(FallbackOutcome)
    }

    private(set) var generation = 0
    private(set) var phase = Phase.idle

    mutating func beginLoading() -> Int {
        generation += 1
        phase = .loading(generation)
        return generation
    }

    mutating func beginPresenting() -> Int {
        generation += 1
        phase = .presenting(generation)
        return generation
    }

    mutating func resolveLoading(
        generation expectedGeneration: Int,
        status: FallbackFetchStatus
    ) -> FallbackLoadingResolution {
        guard phase == .loading(expectedGeneration) else { return .stale }
        switch status {
        case .content:
            phase = .presenting(expectedGeneration)
            return .presentContent
        case .noContent:
            phase = .terminal(.noContent)
            return .finish(.noContent)
        case .failure:
            phase = .terminal(.fetchFailure)
            return .finish(.fetchFailure)
        }
    }

    mutating func loadingTimedOut(generation expectedGeneration: Int) -> FallbackOutcome? {
        guard phase == .loading(expectedGeneration) else { return nil }
        phase = .terminal(.loadingTimeout)
        return .loadingTimeout
    }

    mutating func completedPresentedContent() -> FallbackOutcome? {
        guard case .presenting = phase else { return nil }
        phase = .terminal(.completed)
        return .completed
    }

    mutating func presentationUnavailable() -> FallbackOutcome? {
        guard case .terminal = phase else {
            phase = .terminal(.presentationUnavailable)
            return .presentationUnavailable
        }
        return nil
    }
}

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - FallbackAdPresenter

/// Presents the post-close fallback ad screens (`AdOverlayView`) full-screen in a dedicated
/// `UIWindow`, mirroring the declarative minigame's post-game ad flow. Used by
/// `SimulaInterstitialAd` and `SimulaRewardedAd` after the primary creative is dismissed: the host
/// fetches the serve's fallback screens (`GET /load/fallbacks/{impressionId}`) and shows them here,
/// one per close tap, in reveal order.
///
/// The window is hosted above `.normal` (independent of the host's view-controller stack), the
/// same pattern as `InterstitialPresenter`. `onFinish` reports exactly why the window ended.
@MainActor
final class FallbackAdPresenter {
    private static let loadingDeadlineNanos: UInt64 = 2_000_000_000
    private var window: UIWindow?
    /// One opaque host survives loading and every screen swap. Replacing its root view lets SwiftUI
    /// dismantle the previous representable before creating the next one, so only one fallback
    /// WebView is owned at a time.
    private var hostingController: UIHostingController<AnyView>?
    private var onFinish: ((FallbackOutcome) -> Void)?
    private var presentationLease: FullscreenPresentationLease?
    private var ads: [FallbackAd] = []
    private var index = 0
    /// The host's key window, captured before we take key. Restored on dismiss so the host
    /// regains touch/keyboard focus.
    private weak var originalKeyWindow: UIWindow?
    /// Deliberate self-retention while the window is on screen. The end screens must survive
    /// their owning ad object: a host can release the ad mid-unit (e.g. React Native's
    /// `destroy()` on unmount, or an error handler reacting to the auto-preload's LOAD_FAILED —
    /// which lands exactly while an end screen is up), and since UIKit does not retain windows,
    /// dropping the last reference to this presenter would deallocate the window and skip the
    /// remaining screens (and, on the rewarded flow, the close/verification that follows them).
    /// Set on a successful `present`, released in `dismiss` (the only teardown path).
    private var retainedWhilePresenting: FallbackAdPresenter?

    /// auto_store_redirect END_SCREEN_N: routed once when the matching fallback screen is presented.
    private var autoStoreRedirect: AutoStoreRedirect?
    private let autoRedirectGuard = AutomaticRouteGuard()
    /// Fired when a user taps an end-screen CTA — surfaces the publisher click on the parent ad.
    private var onAdClick: ((ClickInteraction) -> Void)?
    /// The primary serve's CTA routing context, threaded into each end screen's WebView so its CTA
    /// opens deterministically (in-app store sheet from the raw `ios_store_url` + background tracker
    /// fire) instead of resolving the tracker's redirect chain. Defaults keep today's behavior.
    private var ctaTrackingUrl: String?
    private var ctaDestination: AdDestination = .appstore
    private var ctaStoreOpen: StoreOpen = .skstoreproduct
    private var ctaStoreUrl: String?
    private var attribution: AdAttribution?
    private var loadingDeadlineTask: Task<Void, Never>?
    private var onLoadingTimeout: (() -> Void)?
    private var isLoading = false
    private var presentationCoordinator = FallbackPresentationCoordinator()
    private var loadingGeneration: Int?
    private var clickHandoffIndex: Int?

    /// Presents the fallback ad screens in order. Returns `true` if they were presented; `false`
    /// when `ads` is empty or no window scene was available (`onFinish` is then never called).
    @discardableResult
    func present(
        ads: [FallbackAd],
        originalKeyWindow: UIWindow?,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil,
        attribution: AdAttribution? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        onAdClick: ((ClickInteraction) -> Void)? = nil,
        presentationLease: FullscreenPresentationLease,
        onFinish: @escaping (FallbackOutcome) -> Void
    ) -> Bool {
        guard !ads.isEmpty else { return false }
        presentationCoordinator.beginPresenting()
        return beginPresentation(
            ads: ads,
            startsLoading: false,
            originalKeyWindow: originalKeyWindow,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreOpen: ctaStoreOpen,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution,
            autoStoreRedirect: autoStoreRedirect,
            onAdClick: onAdClick,
            presentationLease: presentationLease,
            onFinish: onFinish
        )
    }

    /// Installs an SDK-owned opaque fallback window synchronously while fallback prefetch is still
    /// in flight. The same window and hosting controller are reused when `resolveLoading` supplies
    /// the screens, preventing the primary presenter from exposing the host app during handoff.
    func presentLoading(
        originalKeyWindow: UIWindow?,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil,
        attribution: AdAttribution? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        onAdClick: ((ClickInteraction) -> Void)? = nil,
        onLoadingTimeout: @escaping () -> Void,
        presentationLease: FullscreenPresentationLease,
        onFinish: @escaping (FallbackOutcome) -> Void
    ) -> Int? {
        let generation = presentationCoordinator.beginLoading()
        loadingGeneration = generation
        let didPresent = beginPresentation(
            ads: [],
            startsLoading: true,
            originalKeyWindow: originalKeyWindow,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreOpen: ctaStoreOpen,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution,
            autoStoreRedirect: autoStoreRedirect,
            onAdClick: onAdClick,
            presentationLease: presentationLease,
            onFinish: onFinish
        )
        guard didPresent else {
            loadingGeneration = nil
            return nil
        }
        self.onLoadingTimeout = onLoadingTimeout
        loadingDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.loadingDeadlineNanos) } catch { return }
            guard !Task.isCancelled else { return }
            self?.loadingDidTimeout(generation: generation)
        }
        return generation
    }

    private func beginPresentation(
        ads: [FallbackAd],
        startsLoading: Bool,
        originalKeyWindow: UIWindow?,
        ctaTrackingUrl: String?,
        ctaDestination: AdDestination,
        ctaStoreOpen: StoreOpen,
        ctaStoreUrl: String?,
        attribution: AdAttribution?,
        autoStoreRedirect: AutoStoreRedirect?,
        onAdClick: ((ClickInteraction) -> Void)?,
        presentationLease: FullscreenPresentationLease,
        onFinish: @escaping (FallbackOutcome) -> Void
    ) -> Bool {
        guard window == nil,
              let scene = originalKeyWindow?.windowScene ?? Self.activeWindowScene() else { return false }
        self.ads = ads
        self.index = 0
        self.onFinish = onFinish
        self.ctaTrackingUrl = ctaTrackingUrl
        self.ctaDestination = ctaDestination
        self.ctaStoreOpen = ctaStoreOpen
        self.ctaStoreUrl = ctaStoreUrl
        self.attribution = attribution
        self.autoStoreRedirect = autoStoreRedirect
        self.onAdClick = onAdClick
        self.presentationLease = presentationLease
        isLoading = startsLoading
        if !startsLoading { loadingGeneration = nil }

        self.originalKeyWindow = originalKeyWindow

        let rootView = startsLoading ? loadingView() : adView(at: 0)
        let hosting = UIHostingController(rootView: rootView)
        hosting.view.backgroundColor = .black
        hosting.view.isOpaque = true

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        // Opaque black (not clear) so the host app never shows through — both behind the
        // end screen's safe area and during the rootViewController swap between screens.
        window.backgroundColor = .black
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
        hostingController = hosting
        retainedWhilePresenting = self
        // Hide the status bar in hosts that opted out of VC-based appearance (e.g. React Native),
        // where `.hideStatusBar` in the end-screen view is a no-op. No-op in native hosts.
        SimulaAppStatusBar.hide()
        return true
    }

    /// Replaces the native loading surface with End Screen 1, or safely tears down when the
    /// best-effort prefetch returned no usable screens. The presenter self-retains across the await.
    func resolveLoading(with result: FallbackFetchResult, generation: Int) {
        guard window != nil, isLoading else { return }
        let resolution = presentationCoordinator.resolveLoading(
            generation: generation,
            status: result.status
        )
        guard resolution != .stale else { return }
        loadingDeadlineTask?.cancel()
        loadingDeadlineTask = nil
        onLoadingTimeout = nil
        loadingGeneration = nil
        isLoading = false
        switch resolution {
        case .presentContent:
            guard case .content(let ads) = result, !ads.isEmpty else {
                dismiss(outcome: .noContent)
                return
            }
            self.ads = ads
            index = 0
            hostingController?.rootView = adView(at: index)
        case .finish(let outcome):
            dismiss(outcome: outcome)
        case .stale:
            break
        }
    }

    private func loadingDidTimeout(generation: Int) {
        guard window != nil, isLoading,
              let outcome = presentationCoordinator.loadingTimedOut(generation: generation) else { return }
        isLoading = false
        loadingGeneration = nil
        loadingDeadlineTask = nil
        let timeout = onLoadingTimeout
        onLoadingTimeout = nil
        timeout?()
        dismiss(outcome: outcome)
    }

    /// END_SCREEN_N: open the primary ad's store once, when the fallback screen whose index matches
    /// the configured trigger is presented (index 0 = END SCREEN 1, index 1 = END SCREEN 2).
    private func fireAutoStoreRedirectIfMatching(index: Int) {
        guard let redirect = autoStoreRedirect, redirect.enabled,
              let trigger = AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: index),
              redirect.trigger == trigger,
              autoRedirectGuard.claim(), window != nil, self.index == index else { return }
        let execution = AttributionRouteExecution(
            isActive: {
                self.window != nil
                    && self.index == index
                    && UIApplication.shared.applicationState == .active
            },
            onOutcome: { outcome in
                recordAttributionRoute(outcome: outcome, source: .autoRedirect)
            }
        )
        CreativeCTARouter.open(
            trackingUrl: ctaTrackingUrl,
            destination: ctaDestination,
            storeOpen: ctaStoreOpen,
            storeUrl: ctaStoreUrl,
            attribution: attribution,
            execution: execution
        )
    }

    /// `.id` gives each screen fresh overlay state while the opaque host itself stays installed.
    private func adView(at index: Int) -> AnyView {
        guard ads.indices.contains(index) else { return loadingView() }
        let ad = ads[index]
        return AnyView(AdOverlayView(
            iframeUrl: ad.iframeUrl,
            onClose: { [weak self] in self?.advance(from: index) },
            adId: ad.adId,
            html: ad.html,
            onAdClick: { [weak self] interaction in self?.onAdClick?(interaction) },
            onClickHandoffPendingChanged: { [weak self] pending in
                guard let self, self.index == index else { return }
                if pending {
                    self.clickHandoffIndex = index
                } else if self.clickHandoffIndex == index {
                    self.clickHandoffIndex = nil
                }
            },
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution,
            onPresented: { [weak self] in
                guard let self, self.index == index else { return }
                self.fireAutoStoreRedirectIfMatching(index: index)
            }
        ).id(index))
    }

    private func loadingView() -> AnyView {
        AnyView(
            ZStack {
                Color.black
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
            .ignoresSafeArea()
        )
    }

    /// Reveal the next screen on each close tap; tear down after the last one.
    private func advance(from renderedIndex: Int) {
        guard window != nil,
              canAdvanceFallback(
                renderedIndex: renderedIndex,
                currentIndex: index,
                clickHandoffIndex: clickHandoffIndex
              ) else { return }
        clickHandoffIndex = nil
        index += 1
        if index < ads.count {
            hostingController?.rootView = adView(at: index)
        } else {
            guard let outcome = presentationCoordinator.completedPresentedContent() else { return }
            dismiss(outcome: outcome)
        }
    }

    /// Tears down the presentation window and fires the close callback once.
    private func dismiss(outcome: FallbackOutcome) {
        // Capture locals and clear `self`'s references before invoking the callback: releasing
        // the self-retention below may leave the callback's owner as the last reference to this
        // presenter, so `self` can be deallocated by the time the callback returns. The caller's
        // reference keeps `self` alive through this method itself.
        let win = window
        let hostKeyWindow = originalKeyWindow
        let shouldRestoreHostKeyWindow = win?.isKeyWindow == true
        loadingDeadlineTask?.cancel()
        loadingDeadlineTask = nil
        onLoadingTimeout = nil
        isLoading = false
        loadingGeneration = nil
        clickHandoffIndex = nil
        window = nil
        hostingController = nil
        originalKeyWindow = nil
        let callback = onFinish
        onFinish = nil
        let presentationLease = presentationLease
        self.presentationLease = nil
        retainedWhilePresenting = nil
        win?.isHidden = true
        win?.rootViewController = nil
        if shouldRestoreHostKeyWindow {
            hostKeyWindow?.makeKey()
        }
        callback?(outcome)
        // Balanced with the present-time hide(); ref count keeps the bar hidden if the close
        // callback opens another presenter, restoring the host only when the last one ends.
        SimulaAppStatusBar.restore()
        presentationLease?.finishPostCloseTeardown()
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return active
        }
        return scenes.compactMap { $0 as? UIWindowScene }.first
    }
}
#endif
