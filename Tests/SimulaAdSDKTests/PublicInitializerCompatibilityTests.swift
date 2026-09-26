import XCTest
@testable import SimulaAdSDK

final class PublicInitializerCompatibilityTests: XCTestCase {
    func testLegacyDeviceCapabilitiesInitializerSymbolsRemainCallable() {
        let four: (String, Bool, String, Bool) -> DeviceCapabilities =
            DeviceCapabilities.init(osVersion:storekitAvailable:skanVersion:adAttributionKitAvailable:)
        let five: (String, Bool, String, Bool, Bool) -> DeviceCapabilities =
            DeviceCapabilities.init(osVersion:storekitAvailable:skanVersion:adAttributionKitAvailable:nativeClickBeaconV1:)
        let six: (String, Bool, String, Bool, Bool, Bool) -> DeviceCapabilities =
            DeviceCapabilities.init(osVersion:storekitAvailable:skanVersion:adAttributionKitAvailable:nativeClickBeaconV1:videoV1:)
        XCTAssertFalse(four("17", true, "4.0", false).videoV1)
        XCTAssertFalse(five("17", true, "4.0", false, true).videoV1)
        XCTAssertFalse(six("17", true, "4.0", false, true, true).videoPlanV2)
    }

    func testLegacyCreativeInitializerSymbolRemainsCallable() {
        let initializer: (String, String?, AdUnitType) -> Creative =
            Creative.init(type:bundleUrl:adUnitType:)
        let videoInitializer: (String, String?, String?, String?, AdUnitType) -> Creative =
            Creative.init(type:bundleUrl:url:posterUrl:adUnitType:)
        let creative = initializer("playable", "https://bundle", .rewarded)
        XCTAssertNil(creative.url)
        XCTAssertNil(creative.posterUrl)
        XCTAssertEqual(
            videoInitializer("video", nil, "https://cdn/video.mp4", nil, .interstitial).url,
            "https://cdn/video.mp4"
        )
    }

    func testLegacyAdBehaviorInitializerSymbolRemainsCallable() {
        let initializer: (
            CloseBehavior, StoreOpen, StorePrompt?, SKOverlayConfig?, AutoStoreRedirect?
        ) -> AdBehavior = AdBehavior.init(close:storeOpen:storePrompt:skoverlay:autoStoreRedirect:)
        XCTAssertEqual(
            initializer(CloseBehavior(), .external, nil, nil, nil).video.style,
            .cornerCTA
        )
    }

    func testLegacyFallbackInitializerSymbolsRemainCallable() {
        let legacy: (String, String, String?) -> FallbackAd =
            FallbackAd.init(adId:iframeUrl:html:)
        let beaconAware: (String, String, String?, Bool) -> FallbackAd =
            FallbackAd.init(adId:iframeUrl:html:nativeClickBeaconV1Enabled:)

        XCTAssertNil(legacy("a", "legacy", "<html/>").trackingUrl)
        XCTAssertTrue(beaconAware("b", "legacy", "<html/>", true).nativeClickBeaconV1Enabled)
    }

    func testLegacyRewardedRequestInitializerSymbolsRemainCallable() {
        let basic: (String, String, String?, String?, String?, String?, SimulaAdContext?) -> RewardedInitRequest =
            RewardedInitRequest.init(adUnitId:sessionId:charId:charName:charImage:charDesc:context:)
        let metadata: (String, String, String?, String?, String?, String?, SimulaAdContext?, [String: String]?) -> RewardedInitRequest =
            RewardedInitRequest.init(adUnitId:sessionId:charId:charName:charImage:charDesc:context:metadata:)
        XCTAssertEqual(basic("u", "s", nil, nil, nil, nil, nil).adUnitId, "u")
        XCTAssertEqual(metadata("u", "s", nil, nil, nil, nil, nil, ["k": "v"]).metadata, ["k": "v"])
    }

    func testVerifyRewardRequestInitializerSymbolsRemainCallable() {
        let legacy: (String, String, Double, String) -> VerifyRewardRequest =
            VerifyRewardRequest.init(serveId:sessionId:elapsedPlayTime:adUnitId:)
        let reasonAware: (String, String, Double, String, RewardCompletionReason?) -> VerifyRewardRequest =
            VerifyRewardRequest.init(serveId:sessionId:elapsedPlayTime:adUnitId:completionReason:)

        XCTAssertNil(legacy("serve", "session", 1, "unit").completionReason)
        XCTAssertEqual(
            reasonAware("serve", "session", 1, "unit", .creativeCompleted).completionReason,
            .creativeCompleted
        )
    }

    func testLegacyAdLoadRequestInitializerSymbolsRemainCallable() {
        let capabilities = DeviceCapabilities(
            osVersion: "17",
            storekitAvailable: true,
            skanVersion: "4.0",
            adAttributionKitAvailable: false
        )
        let basic: (String, String, String?, String?, String?, String?, SimulaAdContext?, DeviceCapabilities) -> AdLoadRequest =
            AdLoadRequest.init(adUnitId:sessionId:charId:charName:charImage:charDesc:context:capabilities:)
        let metadata: (String, String, String?, String?, String?, String?, SimulaAdContext?, [String: String]?, DeviceCapabilities) -> AdLoadRequest =
            AdLoadRequest.init(adUnitId:sessionId:charId:charName:charImage:charDesc:context:metadata:capabilities:)
        XCTAssertEqual(basic("u", "s", nil, nil, nil, nil, nil, capabilities).adUnitId, "u")
        XCTAssertEqual(metadata("u", "s", nil, nil, nil, nil, nil, ["k": "v"], capabilities).metadata, ["k": "v"])
    }

    func testRewardedResponseInitializerSymbolsRemainCallable() {
        let legacy: (
            String, String, String, String, String?, String?, AdBehavior?, AdAttribution?, Double, Bool
        ) -> RewardedInitResponse = RewardedInitResponse.init(
            impressionId:iframeUrl:renderedHtml:destination:trackingUrl:iosStoreUrl:
            adBehavior:skanAttribution:bidAmt:prewarmSKProduct:
        )
        let creative: (
            String, String, String, Creative?, String, String?, String?, AdBehavior?, AdAttribution?, Double, Bool
        ) -> RewardedInitResponse = RewardedInitResponse.init(
            impressionId:iframeUrl:renderedHtml:creative:destination:trackingUrl:iosStoreUrl:
            adBehavior:skanAttribution:bidAmt:prewarmSKProduct:
        )
        let experiment: (
            String, String, String, Creative?, String, String?, String?, AdBehavior?, AdAttribution?, Experiment?, Double, Bool
        ) -> RewardedInitResponse = RewardedInitResponse.init(
            impressionId:iframeUrl:renderedHtml:creative:destination:trackingUrl:iosStoreUrl:
            adBehavior:skanAttribution:experiment:bidAmt:prewarmSKProduct:
        )
        let legacyResponse = legacy("i", "legacy", "<html/>", "web", nil, nil, nil, nil, 1, false)
        let creativeResponse = creative("i", "legacy", "<html/>", nil, "web", nil, nil, nil, nil, 1, false)
        let assignment = Experiment(experimentId: "exp", variantId: "variant")
        let experimentResponse = experiment(
            "i", "legacy", "<html/>", nil, "web", nil, nil, nil, nil, assignment, 1, false
        )
        XCTAssertNil(legacyResponse.creative)
        XCTAssertNil(creativeResponse.experiment)
        XCTAssertEqual(legacyResponse.renderedHtml, "<html/>")
        XCTAssertEqual(experimentResponse.experiment, assignment)
    }
}
