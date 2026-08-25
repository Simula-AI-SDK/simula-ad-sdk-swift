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

    /// auto_store_redirect END_SCREEN_N: the primary ad's config + a closure that opens its store,
    /// fired once when the fallback screen whose index matches the trigger is presented.
    private var autoStoreRedirect: AutoStoreRedirect?
    private var onAutoStoreRedirect: (@MainActor () -> Void)?
    private var autoRedirectFired = false
    /// Fired when a user taps an end-screen CTA — surfaces the publisher click on the parent ad.
    private var onAdClick: (() -> Void)?
    /// The primary serve's CTA routing context, threaded into each end screen's WebView so its CTA
    /// opens deterministically (in-app store sheet from the raw `ios_store_url` + background tracker
    /// fire) instead of resolving the tracker's redirect chain. Defaults keep today's behavior.
    private var ctaTrackingUrl: String?
    private var ctaDestination: AdDestination = .appstore
    private var ctaStoreUrl: String?
    private var attribution: AdAttribution?

    /// Presents the fallback ad screens in order. Returns `true` if they were presented; `false`
    /// when `ads` is empty or no window scene was available (`onClose` is then never called).
    @discardableResult
    func present(
        ads: [FallbackAd],
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreUrl: String? = nil,
        attribution: AdAttribution? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        onAutoStoreRedirect: (@MainActor () -> Void)? = nil,
        onAdClick: (() -> Void)? = nil,
        presentationLease: FullscreenPresentationLease,
        onClose: @escaping () -> Void
    ) -> Bool {
        guard !ads.isEmpty else { return false }
        return beginPresentation(
            ads: ads,
            startsLoading: false,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution,
            autoStoreRedirect: autoStoreRedirect,
            onAutoStoreRedirect: onAutoStoreRedirect,
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
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreUrl: String? = nil,
        attribution: AdAttribution? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        onAutoStoreRedirect: (@MainActor () -> Void)? = nil,
        onAdClick: (() -> Void)? = nil,
        presentationLease: FullscreenPresentationLease,
        onClose: @escaping () -> Void
    ) -> Bool {
        beginPresentation(
            ads: [],
            startsLoading: true,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution,
            autoStoreRedirect: autoStoreRedirect,
            onAutoStoreRedirect: onAutoStoreRedirect,
            onAdClick: onAdClick,
            presentationLease: presentationLease,
            onClose: onClose
        )
    }

    private func beginPresentation(
        ads: [FallbackAd],
        startsLoading: Bool,
        ctaTrackingUrl: String?,
        ctaDestination: AdDestination,
        ctaStoreUrl: String?,
        attribution: AdAttribution?,
        autoStoreRedirect: AutoStoreRedirect?,
        onAutoStoreRedirect: (@MainActor () -> Void)?,
        onAdClick: (() -> Void)?,
        presentationLease: FullscreenPresentationLease,
        onClose: @escaping () -> Void
    ) -> Bool {
        guard window == nil, let scene = Self.activeWindowScene() else { return false }
        self.ads = ads
        self.index = 0
        self.onClose = onClose
        self.ctaTrackingUrl = ctaTrackingUrl
        self.ctaDestination = ctaDestination
        self.ctaStoreUrl = ctaStoreUrl
        self.attribution = attribution
        self.autoStoreRedirect = autoStoreRedirect
        self.onAutoStoreRedirect = onAutoStoreRedirect
        self.onAdClick = onAdClick
        self.presentationLease = presentationLease

        originalKeyWindow = scene.keyWindow

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
        if !startsLoading {
            fireAutoStoreRedirectIfMatching(index: 0)
        }
        return true
    }

    /// Replaces the native loading surface with End Screen 1, or safely tears down when the
    /// best-effort prefetch returned no usable screens. The presenter self-retains across the await.
    func resolveLoading(with ads: [FallbackAd]) {
        guard window != nil else { return }
        guard !ads.isEmpty else {
            dismiss()
            return
        }
        self.ads = ads
        index = 0
        hostingController?.rootView = adView(at: index)
        fireAutoStoreRedirectIfMatching(index: index)
    }

    /// END_SCREEN_N: open the primary ad's store once, when the fallback screen whose index matches
    /// the configured trigger is presented (index 0 = END SCREEN 1, index 1 = END SCREEN 2).
    private func fireAutoStoreRedirectIfMatching(index: Int) {
        guard !autoRedirectFired, let redirect = autoStoreRedirect, redirect.enabled,
              let trigger = AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: index),
              redirect.trigger == trigger else { return }
        autoRedirectFired = true
        onAutoStoreRedirect?()
    }

    /// `.id` gives each screen fresh overlay state while the opaque host itself stays installed.
    private func adView(at index: Int) -> AnyView {
        guard ads.indices.contains(index) else { return loadingView() }
        let ad = ads[index]
        return AnyView(AdOverlayView(
            iframeUrl: ad.iframeUrl,
            onClose: { [weak self] in self?.advance() },
            adId: ad.adId,
            html: ad.html,
            onAdClick: { [weak self] in self?.onAdClick?() },
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution
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
    private func advance() {
        index += 1
        if index < ads.count {
            hostingController?.rootView = adView(at: index)
            fireAutoStoreRedirectIfMatching(index: index)
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
        hostKeyWindow?.makeKey()
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
