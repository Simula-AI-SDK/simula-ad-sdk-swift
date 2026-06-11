#if os(iOS)
import UIKit
import StoreKit

// MARK: - SKOverlayPresenter

/// Presents the native `SKOverlay` install banner for the `skoverlay` experiment (PRD Section 5).
///
/// This is purely the persistent bottom banner — `SKStoreProductViewController` stays available in
/// the background via `CreativeCTARouter`, independent of this overlay. Presentation is gated to
/// iOS 14+; the capability handshake means the backend won't assign the variant below that, but we
/// re-check defensively so a misconfigured payload can never crash an older OS.
///
/// Presented in the active `UIWindowScene` (the same scene `InterstitialPresenter` uses), so the
/// banner floats above the creative window without taking over the VC stack.
@available(iOS 14.0, *)
@MainActor
enum SKOverlayPresenter {
    /// Presents an SKOverlay for `appID` (numeric App Store id) honoring position + dismissibility, and
    /// carrying any [attribution] tokens so the install the overlay drives is credited to the campaign.
    /// Best-effort: a disabled config or a missing scene simply no-ops (the impression is unaffected).
    static func present(appID: String, config: SKOverlayConfig, attribution: AdAttribution? = nil) {
        guard config.enabled, !appID.isEmpty, let scene = activeWindowScene() else { return }

        let position: SKOverlay.Position = config.position == .bottomRaised ? .bottomRaised : .bottom
        let appConfig = SKOverlay.AppConfiguration(appIdentifier: appID, position: position)
        // `dismissible == false` asks for no user-dismiss control. SKOverlay still renders a system
        // dismiss affordance on some OS versions (documented limitation), so this is best-effort.
        appConfig.userDismissible = config.dismissible

        // Attribution tokens: campaign/provider via the typed properties; the signed SKAdNetwork set
        // via `setAdditionalValue` with the shared `SKStoreProductParameterAdNetwork*` keys (StoreKit
        // records the SKAN install postback when the overlay drives the install). The MMP click for
        // this engagement is fired separately when the app id is resolved (`is_skoverlay=true`).
        if let campaign = attribution?.campaignToken, !campaign.isEmpty { appConfig.campaignToken = campaign }
        if let provider = attribution?.providerToken, !provider.isEmpty { appConfig.providerToken = provider }
        for (key, value) in CreativeCTARouter.skanAdditionalValues(attribution) {
            appConfig.setAdditionalValue(value, forKey: key)
        }

        let overlay = SKOverlay(configuration: appConfig)
        overlay.present(in: scene)
    }

    /// Dismisses any SKOverlay currently shown in the active scene (called on creative teardown so
    /// the banner doesn't outlive the ad).
    static func dismiss() {
        guard let scene = activeWindowScene() else { return }
        SKOverlay.dismiss(in: scene)
    }

    /// Picks a window scene the same way `InterstitialPresenter` / `CreativeCTARouter` do —
    /// preferring a foreground-active scene — so the overlay lands on the same surface as the ad.
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return active
        }
        return scenes.compactMap { $0 as? UIWindowScene }.first
    }
}
#endif
