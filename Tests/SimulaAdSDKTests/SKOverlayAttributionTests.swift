import XCTest
#if os(iOS)
import StoreKit
#endif
@testable import SimulaAdSDK

/// Tests for the documented SKOverlay SKAN conveyance (`SKOverlay.AppConfiguration.adImpression`).
///
/// The view-through signature (`view_attribution_signature`, fidelity-type 0) is REQUIRED — the
/// click signature is fidelity-type 1 and fails validation on this surface. When it's absent the
/// presenter falls back to the legacy `setAdditionalValue` path, so `adImpression(...)` must
/// return nil exactly then.
final class SKOverlayAttributionTests: XCTestCase {

    func testOverlayOwnershipDismissesOnlyMatchingOwnerAndScene() {
        var ownership = SKOverlayOwnershipState<String, String>()
        ownership.install(owner: "first", scene: "scene-a")
        ownership.install(owner: "second", scene: "scene-b")

        XCTAssertTrue(ownership.owns(owner: "first", scene: "scene-a"))
        XCTAssertNil(ownership.takeSceneForDismiss(owner: "stale"))
        XCTAssertEqual(ownership.takeSceneForDismiss(owner: "first"), "scene-a")
        XCTAssertTrue(ownership.owns(owner: "second", scene: "scene-b"))
        XCTAssertEqual(ownership.takeSceneForDismiss(owner: "second"), "scene-b")
    }

    func testNewOverlayInSameSceneInvalidatesPreviousOwner() {
        var ownership = SKOverlayOwnershipState<String, String>()
        ownership.install(owner: "first", scene: "scene-a")
        ownership.install(owner: "second", scene: "scene-a")

        XCTAssertFalse(ownership.owns(owner: "first", scene: "scene-a"))
        XCTAssertNil(ownership.takeSceneForDismiss(owner: "first"))
        XCTAssertEqual(ownership.takeSceneForDismiss(owner: "second"), "scene-a")
    }

    func testOverlayDismissReturnsExactOwnerAndSuppressesLatePresentation() {
        var state = SKOverlayPresentationState<String>()
        XCTAssertTrue(state.canPresent(hasResolvedAppID: true))
        XCTAssertTrue(state.install("overlay-1"))
        XCTAssertFalse(state.install("overlay-2"))
        XCTAssertEqual(state.dismiss(), "overlay-1")
        XCTAssertNil(state.dismiss())
        XCTAssertFalse(state.canPresent(hasResolvedAppID: true))
        XCTAssertFalse(state.install("late-overlay"))
    }

    func testOverlayCannotScheduleBeforeResolutionAndDismissSuppressesPendingWork() {
        var state = SKOverlayPresentationState<String>()
        XCTAssertFalse(state.canPresent(hasResolvedAppID: false))
        XCTAssertTrue(state.requestCreativePresentation())
        XCTAssertTrue(state.creativePresentationRequested)
        XCTAssertNil(state.dismiss())
        XCTAssertTrue(state.suppressPending)
        XCTAssertFalse(state.creativePresentationRequested)
        XCTAssertFalse(state.requestCreativePresentation())
        XCTAssertFalse(state.canPresent(hasResolvedAppID: true))
    }

    func testCreativeRequestedOverlayDoesNotRequireExperimentConfig() {
        let config = creativeRequestedSKOverlayConfig(from: nil)

        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.timing, .onClick)
        XCTAssertEqual(config.delaySeconds, 0)
        XCTAssertEqual(config.position, .bottom)
        XCTAssertTrue(config.dismissible)
    }

    func testCreativeRequestedOverlayIgnoresExperimentEnableAndTiming() {
        let experiment = SKOverlayConfig(
            enabled: false,
            timing: .delayed,
            delaySeconds: 30,
            position: .bottomRaised,
            dismissible: false
        )

        let config = creativeRequestedSKOverlayConfig(from: experiment)

        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.timing, .onClick)
        XCTAssertEqual(config.delaySeconds, 0)
        XCTAssertEqual(config.position, .bottomRaised)
        XCTAssertFalse(config.dismissible)
    }

    private func attribution(_ skanFields: String) throws -> AdAttribution {
        let json = """
        {"campaign_token":"camp_tok","provider_token":"prov_tok","skan":{\(skanFields)}}
        """
        return try JSONDecoder().decode(AdAttribution.self, from: Data(json.utf8))
    }

    // MARK: - Decode (platform-independent)

    func testViewAttributionSignatureDecodes() throws {
        let a = try attribution("""
        "version":"4.0","ad_network_id":"2xg367y5gd.adattributionkit","source_app_store_id":1671705818,
        "nonce":"n","timestamp":1784691000000,"attribution_signature":"click_sig",
        "view_attribution_signature":"view_sig","source_id":25
        """)
        XCTAssertEqual(a.skan?.viewAttributionSignature, "view_sig")
        XCTAssertEqual(a.skan?.attributionSignature, "click_sig")
    }

    func testViewAttributionSignatureAbsentOnOldPayloads() throws {
        // Servers pre-dating the field omit it — must decode to nil, not fail.
        let a = try attribution("""
        "version":"4.0","ad_network_id":"2xg367y5gd.adattributionkit","source_app_store_id":1671705818,
        "nonce":"n","timestamp":1784691000000,"attribution_signature":"click_sig","source_id":25
        """)
        XCTAssertNil(a.skan?.viewAttributionSignature)
    }

    // MARK: - SKAdImpression construction (iOS only — SKAdImpression doesn't exist on macOS)

    #if os(iOS)
    private func skan4() throws -> AdAttribution {
        try attribution("""
        "version":"4.0","ad_network_id":"2xg367y5gd.adattributionkit","source_app_store_id":1671705818,
        "nonce":"00000000-0000-0000-0000-000000000001","timestamp":1784691000000,
        "attribution_signature":"click_sig","view_attribution_signature":"view_sig","source_id":25
        """)
    }

    @available(iOS 16.0, *)
    func testAdImpressionBuildsWithViewSignature() async throws {
        let built = await SKOverlayPresenter.adImpression(appID: "1575412509", attribution: try skan4())
        let imp = try XCTUnwrap(built)
        XCTAssertEqual(imp.version, "4.0")
        XCTAssertEqual(imp.adNetworkIdentifier, "2xg367y5gd.adattributionkit")
        XCTAssertEqual(imp.sourceAppStoreItemIdentifier.intValue, 1_671_705_818)
        XCTAssertEqual(imp.advertisedAppStoreItemIdentifier.intValue, 1_575_412_509)
        XCTAssertEqual(imp.adImpressionIdentifier, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(imp.timestamp.intValue, 1_784_691_000_000)
        // The VIEW-THROUGH signature, never the click (fidelity-1) one.
        XCTAssertEqual(imp.signature, "view_sig")
        if #available(iOS 16.1, *) {
            XCTAssertEqual(imp.sourceIdentifier.intValue, 25)
        }
        // SKAN 4 replaces the legacy campaign slot; do not provide an out-of-range placeholder.
        XCTAssertNil(imp.value(forKey: "adCampaignIdentifier"))
    }

    @available(iOS 16.0, *)
    func testAdImpressionNilWithoutViewSignature() async throws {
        let a = try attribution("""
        "version":"4.0","ad_network_id":"2xg367y5gd.adattributionkit","source_app_store_id":1671705818,
        "nonce":"n","timestamp":1784691000000,"attribution_signature":"click_sig","source_id":25
        """)
        let result = await SKOverlayPresenter.adImpression(appID: "1575412509", attribution: a)
        XCTAssertNil(result)
    }

    @available(iOS 16.0, *)
    func testAdImpressionNilWithoutSkanBlock() async throws {
        let result = await SKOverlayPresenter.adImpression(appID: "1575412509", attribution: nil)
        XCTAssertNil(result)
    }

    @MainActor
    func testTrackerOnlyOverlayResolutionDoesNotCreateMMPClick() {
        var resolved: String? = "not-called"
        CreativeCTARouter.resolveAppStoreID(
            trackingUrl: "https://tracker.example/click",
            destination: .appstore,
            storeUrl: nil
        ) { resolved = $0 }

        XCTAssertNil(resolved, "tracker-only overlay setup must stay side-effect-free")
    }

    @MainActor
    func testDirectItmsOverlayResolutionUsesStoreIdWithoutMMPRequest() {
        var resolved: String? = nil
        CreativeCTARouter.resolveAppStoreID(
            trackingUrl: "itms-apps://apps.apple.com/app/id1575412509",
            destination: .appstore,
            storeUrl: nil
        ) { resolved = $0 }

        XCTAssertEqual(resolved, "1575412509")
    }

    @available(iOS 16.0, *)
    func testAdImpressionNilOnNonNumericAppID() async throws {
        let result = await SKOverlayPresenter.adImpression(appID: "not-an-id", attribution: try skan4())
        XCTAssertNil(result)
    }

    @available(iOS 16.0, *)
    func testAdImpressionSkan3UsesCampaignIdentifier() async throws {
        let a = try attribution("""
        "version":"3.0","ad_network_id":"2xg367y5gd.adattributionkit","source_app_store_id":1671705818,
        "nonce":"00000000-0000-0000-0000-000000000001","timestamp":1784691000000,"attribution_signature":"click_sig",
        "view_attribution_signature":"view_sig","campaign_id":42
        """)
        let built = await SKOverlayPresenter.adImpression(appID: "1575412509", attribution: a)
        let imp = try XCTUnwrap(built)
        XCTAssertEqual(imp.adCampaignIdentifier.intValue, 42)
        XCTAssertEqual(imp.signature, "view_sig")
        XCTAssertEqual(imp.version, "3.0")
    }

    @available(iOS 15.0, *)
    @MainActor
    func testInterstitialViewThroughBuilderSupportsSkan3() throws {
        let a = try attribution("""
        "version":"3.0","ad_network_id":"2xg367y5gd.adattributionkit","source_app_store_id":1671705818,
        "nonce":"00000000-0000-0000-0000-000000000001","timestamp":1784691000000,"attribution_signature":"click_sig",
        "view_attribution_signature":"view_sig","campaign_id":42
        """)

        let built = makeSKANViewThroughImpression(
            appID: "1575412509",
            attribution: a,
            surface: .interstitialViewThrough
        )
        let imp = try XCTUnwrap(built)

        XCTAssertEqual(imp.adCampaignIdentifier.intValue, 42)
        XCTAssertEqual(imp.signature, "view_sig")
        XCTAssertEqual(imp.version, "3.0")
    }

    @available(iOS 16.0, *)
    func testAdImpressionRejectsPreViewThroughSkanVersion() async throws {
        let a = try attribution("""
        "version":"2.1","ad_network_id":"2xg367y5gd.adattributionkit","source_app_store_id":1671705818,
        "nonce":"00000000-0000-0000-0000-000000000001","timestamp":1784691000000,
        "attribution_signature":"click_sig","view_attribution_signature":"view_sig","campaign_id":42
        """)
        let built = await SKOverlayPresenter.adImpression(appID: "1575412509", attribution: a)
        XCTAssertNil(built)
    }
    #endif
}
