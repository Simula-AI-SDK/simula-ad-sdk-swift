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
/// same pattern as `InterstitialPresenter`. `onClose` fires once the last screen closes and the
/// window is torn down.
@MainActor
final class FallbackAdPresenter {
    private static let loadingDeadlineNanos: UInt64 = 2_000_000_000
    private var window: UIWindow?
    /// One opaque host survives loading and every screen swap. Replacing its root view lets SwiftUI
    /// dismantle the previous representable before creating the next one, so only one fallback
    /// WebView is owned at a time.
    private var hostingController: UIHostingController<AnyView>?
    private var onClose: (() -> Void)?
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

    /// auto_store_redirect END_SCREEN_N: emitted and durably persisted once when the matching
    /// fallback screen is actually presented.
    private var autoStoreRedirect: AutoStoreRedirect?
    private let autoRedirectHandoff = AutomaticClickHandoffGuard()
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
    private var clickBeaconImpressionId: String?
    private var loadingDeadlineTask: Task<Void, Never>?
    private var onLoadingTimeout: (() -> Void)?
    private var isLoading = false

    /// Presents the fallback ad screens in order. Returns `true` if they were presented; `false`
    /// when `ads` is empty or no window scene was available (`onClose` is then never called).
    @discardableResult
    func present(
        ads: [FallbackAd],
        originalKeyWindow: UIWindow?,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil,
        attribution: AdAttribution? = nil,
        clickBeaconImpressionId: String? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        onAdClick: ((ClickInteraction) -> Void)? = nil,
        presentationLease: FullscreenPresentationLease,
        onClose: @escaping () -> Void
    ) -> Bool {
        guard !ads.isEmpty else { return false }
        return beginPresentation(
            ads: ads,
            startsLoading: false,
            originalKeyWindow: originalKeyWindow,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreOpen: ctaStoreOpen,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution,
            clickBeaconImpressionId: clickBeaconImpressionId,
            autoStoreRedirect: autoStoreRedirect,
            onAdClick: onAdClick,
            presentationLease: presentationLease,
            onClose: onClose
        )
    }

    /// Installs an SDK-owned opaque fallback window synchronously while fallback prefetch is still
    /// in flight. The same window and hosting controller are reused when `resolveLoading` supplies
    /// the screens, preventing the primary presenter from exposing the host app during handoff.
    @discardableResult
    func presentLoading(
        originalKeyWindow: UIWindow?,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil,
        attribution: AdAttribution? = nil,
        clickBeaconImpressionId: String? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        onAdClick: ((ClickInteraction) -> Void)? = nil,
        onLoadingTimeout: @escaping () -> Void,
        presentationLease: FullscreenPresentationLease,
        onClose: @escaping () -> Void
    ) -> Bool {
        let didPresent = beginPresentation(
            ads: [],
            startsLoading: true,
            originalKeyWindow: originalKeyWindow,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreOpen: ctaStoreOpen,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution,
            clickBeaconImpressionId: clickBeaconImpressionId,
            autoStoreRedirect: autoStoreRedirect,
            onAdClick: onAdClick,
            presentationLease: presentationLease,
            onClose: onClose
        )
        guard didPresent else { return false }
        self.onLoadingTimeout = onLoadingTimeout
        loadingDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.loadingDeadlineNanos) } catch { return }
            guard !Task.isCancelled else { return }
            self?.loadingDidTimeout()
        }
        return true
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
        clickBeaconImpressionId: String?,
        autoStoreRedirect: AutoStoreRedirect?,
        onAdClick: ((ClickInteraction) -> Void)?,
        presentationLease: FullscreenPresentationLease,
        onClose: @escaping () -> Void
    ) -> Bool {
        guard window == nil,
              let scene = originalKeyWindow?.windowScene ?? Self.activeWindowScene() else { return false }
        self.ads = ads
        self.index = 0
        self.onClose = onClose
        self.ctaTrackingUrl = ctaTrackingUrl
        self.ctaDestination = ctaDestination
        self.ctaStoreOpen = ctaStoreOpen
        self.ctaStoreUrl = ctaStoreUrl
        self.attribution = attribution
        self.clickBeaconImpressionId = clickBeaconImpressionId
        self.autoStoreRedirect = autoStoreRedirect
        self.onAdClick = onAdClick
        self.presentationLease = presentationLease
        isLoading = startsLoading

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
    func resolveLoading(with ads: [FallbackAd]) {
        guard window != nil, isLoading else { return }
        isLoading = false
        loadingDeadlineTask?.cancel()
        loadingDeadlineTask = nil
        onLoadingTimeout = nil
        guard !ads.isEmpty else {
            dismiss()
            return
        }
        self.ads = ads
        index = 0
        hostingController?.rootView = adView(at: index)
    }

    private func loadingDidTimeout() {
        guard window != nil, isLoading else { return }
        isLoading = false
        loadingDeadlineTask = nil
        let timeout = onLoadingTimeout
        onLoadingTimeout = nil
        timeout?()
        dismiss()
    }

    /// END_SCREEN_N: open the primary ad's store once, when the fallback screen whose index matches
    /// the configured trigger is presented (index 0 = END SCREEN 1, index 1 = END SCREEN 2).
    private func fireAutoStoreRedirectIfMatching(index: Int) {
        guard let redirect = autoStoreRedirect, redirect.enabled,
              let trigger = AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: index),
              redirect.trigger == trigger,
              let generation = autoRedirectHandoff.claim() else { return }
        let interaction = ClickInteraction(source: .autoRedirect)
        onAdClick?(interaction)
        ClickHandoffPersistence.wait(
            interaction: interaction,
            beaconImpressionId: clickBeaconImpressionId
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.window != nil, self.index == index,
                      self.autoRedirectHandoff.persistenceCompleted(generation: generation) else { return }
                _ = CreativeCTARouter.open(
                    trackingUrl: self.ctaTrackingUrl,
                    destination: self.ctaDestination,
                    storeOpen: self.ctaStoreOpen,
                    storeUrl: self.ctaStoreUrl,
                    attribution: self.attribution
                )
            }
        }
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
        guard window != nil, index == renderedIndex else { return }
        index += 1
        if index < ads.count {
            hostingController?.rootView = adView(at: index)
        } else {
            dismiss()
        }
    }

    /// Tears down the presentation window and fires the close callback once.
    private func dismiss() {
        // Capture locals and clear `self`'s references before invoking the callback: releasing
        // the self-retention below may leave the callback's owner as the last reference to this
        // presenter, so `self` can be deallocated by the time the callback returns. The caller's
        // reference keeps `self` alive through this method itself.
        let win = window
        let hostKeyWindow = originalKeyWindow
        let shouldRestoreHostKeyWindow = win?.isKeyWindow == true
        loadingDeadlineTask?.cancel()
        loadingDeadlineTask = nil
        autoRedirectHandoff.cancelPendingRoute()
        onLoadingTimeout = nil
        isLoading = false
        window = nil
        hostingController = nil
        originalKeyWindow = nil
        let callback = onClose
        onClose = nil
        let presentationLease = presentationLease
        self.presentationLease = nil
        retainedWhilePresenting = nil
        win?.isHidden = true
        win?.rootViewController = nil
        if shouldRestoreHostKeyWindow {
            hostKeyWindow?.makeKey()
        }
        callback?()
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
