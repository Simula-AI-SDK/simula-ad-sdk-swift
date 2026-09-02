import Foundation

struct SKOverlayOwnershipState<Owner: Hashable, Scene: Hashable> {
    private var ownerByScene: [Scene: Owner] = [:]
    private var sceneByOwner: [Owner: Scene] = [:]

    mutating func install(owner: Owner, scene: Scene) {
        if let replacedOwner = ownerByScene[scene] {
            sceneByOwner[replacedOwner] = nil
        }
        if let previousScene = sceneByOwner[owner] {
            ownerByScene[previousScene] = nil
        }
        ownerByScene[scene] = owner
        sceneByOwner[owner] = scene
    }

    mutating func takeSceneForDismiss(owner: Owner) -> Scene? {
        guard let scene = sceneByOwner.removeValue(forKey: owner),
              ownerByScene[scene] == owner else { return nil }
        ownerByScene[scene] = nil
        return scene
    }

    func owns(owner: Owner, scene: Scene) -> Bool {
        ownerByScene[scene] == owner && sceneByOwner[owner] == scene
    }
}

struct SKOverlayOwnershipToken: Hashable, Sendable {
    fileprivate let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

struct SKOverlayPresentationState<Ownership> {
    private(set) var ownership: Ownership?
    private(set) var suppressPending = false

    func canPresent(hasResolvedAppID: Bool) -> Bool {
        !suppressPending && ownership == nil && hasResolvedAppID
    }

    mutating func install(_ ownership: Ownership) -> Bool {
        guard !suppressPending, self.ownership == nil else { return false }
        self.ownership = ownership
        return true
    }

    mutating func dismiss() -> Ownership? {
        suppressPending = true
        defer { ownership = nil }
        return ownership
    }
}

#if os(iOS)
import UIKit
import StoreKit

/// Builds a fidelity-type 0 impression for APIs that consume the server's
/// `view_attribution_signature`. The caller owns the impression lifecycle.
@available(iOS 14.5, *)
@MainActor
func makeSKANViewThroughImpression(
    appID: String,
    attribution: AdAttribution?,
    surface: SKANAttributionSurface
) -> SKAdImpression? {
    guard let skan = attribution?.skan else { return nil }
    guard let viewSignature = skan.viewAttributionSignature, !viewSignature.isEmpty else { return nil }
    guard ["2.2", "3.0", "4.0"].contains(skan.version) else {
        CreativeCTARouter.recordDroppedSKAN(.unsupportedViewVersion, surface: surface)
        return nil
    }
    guard let advertisedID = Int(appID) else {
        CreativeCTARouter.recordDroppedSKAN(.invalidAdvertisedAppID, surface: surface)
        return nil
    }
    if let reason = skanPayloadRejectionReason(skan, signature: viewSignature) {
        CreativeCTARouter.recordDroppedSKAN(reason, surface: surface)
        return nil
    }
    guard let identifier = validatedSKANIdentifier(
        version: skan.version,
        campaignIdentifier: skan.campaignIdentifier,
        sourceIdentifier: skan.sourceIdentifier
    ) else {
        CreativeCTARouter.recordDroppedSKAN(.unsupportedVersion, surface: surface)
        return nil
    }

    let impression = SKAdImpression()
    impression.sourceAppStoreItemIdentifier = NSNumber(value: skan.sourceAppStoreIdentifier)
    impression.advertisedAppStoreItemIdentifier = NSNumber(value: advertisedID)
    impression.adNetworkIdentifier = skan.adNetworkIdentifier
    impression.adImpressionIdentifier = skan.nonce.lowercased()
    impression.timestamp = NSNumber(value: skan.timestamp)
    impression.signature = viewSignature
    impression.version = skan.version
    switch identifier {
    case .campaign(let campaignID):
        impression.adCampaignIdentifier = NSNumber(value: campaignID)
    case .source(let sourceID):
        guard #available(iOS 16.1, *) else {
            CreativeCTARouter.recordDroppedSKAN(.unsupportedOS, surface: surface)
            return nil
        }
        impression.sourceIdentifier = NSNumber(value: sourceID)
    }
    return impression
}

// MARK: - SKOverlayPresenter

/// Presents the native `SKOverlay` install banner for the `skoverlay` experiment (PRD Section 5).
/// StoreKit exposes no overlay-tap callback, so this surface remains StoreKit/SKAN-attributed and
/// never manufactures an SDK click or an MMP tracker request merely to observe engagement.
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
    private static var ownership = SKOverlayOwnershipState<SKOverlayOwnershipToken, ObjectIdentifier>()
    private static var presentedScenes: [ObjectIdentifier: WeakObjectReference<UIWindowScene>] = [:]

    /// Presents an SKOverlay for `appID` (numeric App Store id) honoring position + dismissibility, and
    /// carrying any [attribution] tokens so the install the overlay drives is credited to the campaign.
    /// Best-effort: a disabled config or a missing scene simply no-ops (the impression is unaffected).
    static func present(
        appID: String,
        config: SKOverlayConfig,
        attribution: AdAttribution? = nil,
        originatingScene: UIWindowScene? = nil
    ) -> SKOverlayOwnershipToken? {
        guard config.enabled, Int(appID) != nil,
              UIApplication.shared.applicationState == .active else { return nil }
        let scene: UIWindowScene?
        if let originatingScene {
            scene = originatingScene.activationState == .foregroundActive ? originatingScene : nil
        } else {
            scene = preferredForegroundActiveWindowScene()
        }
        guard let scene else { return nil }

        let position: SKOverlay.Position = config.position == .bottomRaised ? .bottomRaised : .bottom
        let appConfig = SKOverlay.AppConfiguration(appIdentifier: appID, position: position)
        // `dismissible == false` asks for no user-dismiss control. SKOverlay still renders a system
        // dismiss affordance on some OS versions (documented limitation), so this is best-effort.
        appConfig.userDismissible = config.dismissible

        // Attribution: campaign/provider via the typed properties. The signed SKAdNetwork set
        // goes through the DOCUMENTED `setAdImpression(_:)` API whenever the server sent the
        // view-through (fidelity-type 0) signature — StoreKit then records the SKAN install
        // postback when the overlay drives the install. The SKAdImpression initializer is iOS
        // 16+, and older servers omit the view signature; both cases fall back to the
        // undocumented `setAdditionalValue` conveyance with the shared
        // `SKStoreProductParameterAdNetwork*` keys. App-id resolution is side-effect free; StoreKit
        // owns any later user engagement with the install banner.
        if let campaign = attribution?.campaignToken, !campaign.isEmpty { appConfig.campaignToken = campaign }
        if let provider = attribution?.providerToken, !provider.isEmpty { appConfig.providerToken = provider }
        var usedDocumentedImpression = false
        var documentedRejectionRecorded = false
        if #available(iOS 16.0, *) {
            let viewSignatureWasSupplied = attribution?.skan?.viewAttributionSignature?.isEmpty == false
            if let impression = Self.adImpression(appID: appID, attribution: attribution) {
                appConfig.setAdImpression(impression)
                usedDocumentedImpression = true
            } else {
                // Every nil path with a supplied view signature records its rejection in
                // `adImpression`; a missing signature is a normal compatibility fallback.
                documentedRejectionRecorded = viewSignatureWasSupplied
            }
        }
        if !usedDocumentedImpression {
            for (key, value) in CreativeCTARouter.skanAdditionalValues(
                attribution,
                surface: .skOverlayFallback,
                recordRejection: !documentedRejectionRecorded
            ) {
                appConfig.setAdditionalValue(value, forKey: key)
            }
        }

        let overlay = SKOverlay(configuration: appConfig)
        overlay.present(in: scene)
        let token = SKOverlayOwnershipToken()
        let sceneID = ObjectIdentifier(scene)
        ownership.install(owner: token, scene: sceneID)
        presentedScenes[sceneID] = WeakObjectReference(scene)
        return token
    }

    /// Builds the documented view-through impression for the overlay from the server's signed
    /// SKAN block. Requires the fidelity-type 0 signature (`view_attribution_signature`) — the
    /// click signature is fidelity-type 1 and would fail validation here. Returns nil when the
    /// block is absent or malformed so the caller can fall back to `setAdditionalValue`.
    @available(iOS 16.0, *)
    static func adImpression(appID: String, attribution: AdAttribution?) -> SKAdImpression? {
        makeSKANViewThroughImpression(
            appID: appID,
            attribution: attribution,
            surface: .skOverlayImpression
        )
    }

    /// Dismisses in the exact scene used for presentation, so multi-window hosts cannot leak an
    /// overlay into one scene while teardown targets another.
    static func dismiss(ownershipToken: SKOverlayOwnershipToken) {
        guard let sceneID = ownership.takeSceneForDismiss(owner: ownershipToken) else { return }
        let scene = presentedScenes.removeValue(forKey: sceneID)?.value
        guard let scene, ObjectIdentifier(scene) == sceneID else { return }
        SKOverlay.dismiss(in: scene)
    }

}
#endif
