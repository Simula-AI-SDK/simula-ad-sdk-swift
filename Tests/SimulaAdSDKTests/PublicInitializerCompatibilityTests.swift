import XCTest
@testable import SimulaAdSDK

final class PublicInitializerCompatibilityTests: XCTestCase {
    func testLegacyDeviceCapabilitiesInitializerSymbolsRemainCallable() {
        let four: (String, Bool, String, Bool) -> DeviceCapabilities =
            DeviceCapabilities.init(osVersion:storekitAvailable:skanVersion:adAttributionKitAvailable:)
        let five: (String, Bool, String, Bool, Bool) -> DeviceCapabilities =
            DeviceCapabilities.init(osVersion:storekitAvailable:skanVersion:adAttributionKitAvailable:nativeClickBeaconV1:)
        XCTAssertFalse(four("17", true, "4.0", false).videoV1)
        XCTAssertFalse(five("17", true, "4.0", false, true).videoV1)
    }

    func testLegacyCreativeInitializerSymbolRemainsCallable() {
        let initializer: (String, String?, AdUnitType) -> Creative =
            Creative.init(type:bundleUrl:adUnitType:)
        let creative = initializer("playable", "https://bundle", .rewarded)
        XCTAssertNil(creative.url)
        XCTAssertNil(creative.posterUrl)
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
