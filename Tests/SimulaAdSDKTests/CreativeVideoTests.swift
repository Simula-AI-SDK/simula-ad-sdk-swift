import XCTest
@testable import SimulaAdSDK

final class CreativeVideoTests: XCTestCase {
    private func decodeInterstitial(_ json: String) throws -> AdLoadResponse {
        try JSONDecoder().decode(AdLoadResponse.self, from: Data(json.utf8))
    }

    private func decodeRewarded(_ json: String) throws -> RewardedInitResponse {
        try JSONDecoder().decode(RewardedInitResponse.self, from: Data(json.utf8))
    }

    private func decodeFallbacks(_ json: String) throws -> [FallbackAd] {
        try JSONDecoder().decode(FallbackAdsAPIResponse.self, from: Data(json.utf8)).resolvedAds
    }

    func testUnknownCreativeTypeDefaultsToPlayableHTML() throws {
        let response = try decodeInterstitial(#"{"ad_inserted":true,"rendered_html":"<html/>","creative":{"type":"future"}}"#)
        XCTAssertEqual(response.creative?.mediaType, .playable)
        XCTAssertEqual(response.creativeContent, .playable(html: "<html/>"))
    }

    func testPrimaryVideoDecodesURLAndPosterWithoutHTML() throws {
        let response = try decodeInterstitial(#"{"ad_inserted":true,"creative":{"type":"video","url":"https://cdn.example/ad.mp4","poster_url":"https://cdn.example/poster.jpg"}}"#)
        guard case .video(let url, let posterURL)? = response.creativeContent else {
            return XCTFail("Expected video creative")
        }
        XCTAssertEqual(url.absoluteString, "https://cdn.example/ad.mp4")
        XCTAssertEqual(posterURL?.absoluteString, "https://cdn.example/poster.jpg")
    }

    func testInvalidVideoURLIsNotRenderable() throws {
        let response = try decodeInterstitial(#"{"ad_inserted":true,"rendered_html":"ignored","creative":{"type":"video","url":"file:///tmp/ad.mp4"}}"#)
        XCTAssertNil(response.creativeContent)
    }

    func testRewardedUsesHTMLWithoutIframeAndRejectsIframeOnly() throws {
        XCTAssertEqual(
            try decodeRewarded(#"{"rendered_html":"<html/>"}"#).creativeContent,
            .playable(html: "<html/>")
        )
        XCTAssertNil(try decodeRewarded(#"{"iframe_url":"https://example.com/legacy"}"#).creativeContent)
    }

    func testRewardedVideoCreativeDecodes() throws {
        let response = try decodeRewarded(#"{"creative":{"type":"video","url":"https://cdn.example/reward.mp4","poster_url":"https://cdn.example/reward.jpg"}}"#)
        guard case .video(let url, let posterURL)? = response.creativeContent else {
            return XCTFail("Expected rewarded video")
        }
        XCTAssertEqual(url.lastPathComponent, "reward.mp4")
        XCTAssertEqual(posterURL?.lastPathComponent, "reward.jpg")
    }

    func testCapabilitiesEncodeVideoV1ForFullscreenRequests() throws {
        let capabilities = DeviceCapabilities(
            osVersion: "18.0.0",
            storekitAvailable: true,
            skanVersion: "4.0",
            adAttributionKitAvailable: true,
            nativeClickBeaconV1: true,
            videoV1: true
        )
        let rewarded = RewardedInitRequest(adUnitId: "u", capabilities: capabilities)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(rewarded)) as? [String: Any]
        )
        XCTAssertEqual((object["capabilities"] as? [String: Any])?["video_v1"] as? Bool, true)
        XCTAssertEqual(capabilities.dictionary["video_v1"] as? Bool, true)
    }

    func testFallbackVideoAndBehaviorDecodeAndClamp() throws {
        let ads = try decodeFallbacks(#"{"ads":[{"ad_id":"v","type":"video","url":"https://cdn.example/v.mp4","poster_url":"https://cdn.example/p.jpg","ad_behavior":{"close":{"delay_seconds":999,"treatment":"progress_bar","position":"top_left"}}}]}"#)
        let ad = try XCTUnwrap(ads.first)
        XCTAssertEqual(ad.mediaType, .video)
        XCTAssertEqual(ad.adBehavior.close.delaySeconds, 60)
        XCTAssertEqual(ad.adBehavior.close.treatment, .countdownCircle)
        XCTAssertEqual(ad.adBehavior.close.position, .topLeft)
    }

    func testFallbackDefaultsAndUnknownTypeUsePlayableHTML() throws {
        let ads = try decodeFallbacks(#"{"ads":[{"ad_id":"a","type":"future","rendered_html":"new","html":"old"}]}"#)
        let ad = try XCTUnwrap(ads.first)
        XCTAssertEqual(ad.mediaType, .playable)
        XCTAssertEqual(ad.renderedHtml, "new")
        XCTAssertEqual(ad.adBehavior.close.delaySeconds, 5)
        XCTAssertEqual(ad.adBehavior.close.treatment, .countdownCircle)
        XCTAssertEqual(ad.adBehavior.close.position, .topRight)
    }

    func testFallbackEmptyAndPartialBehaviorKeepFallbackCloseDefaults() throws {
        let ads = try decodeFallbacks(#"{"ads":[{"rendered_html":"a","ad_behavior":{}},{"rendered_html":"b","ad_behavior":{"close":{"delay_seconds":0,"treatment":"hidden"}}}]}"#)
        XCTAssertEqual(ads[0].adBehavior.close.delaySeconds, 5)
        XCTAssertEqual(ads[0].adBehavior.close.treatment, .countdownCircle)
        XCTAssertEqual(ads[1].adBehavior.close.delaySeconds, 0)
        XCTAssertEqual(ads[1].adBehavior.close.treatment, .hidden)
    }

    func testFallbackDecodeIsLossyAndPreservesOriginalStageIndex() throws {
        let ads = try decodeFallbacks(#"{"ads":[42,{"type":"video","url":"file:///bad"},{"ad_id":"ok","rendered_html":"<html/>"}]}"#)
        let ad = try XCTUnwrap(ads.first)
        XCTAssertEqual(ads.count, 1)
        XCTAssertEqual(ad.adId, "ok")
        XCTAssertEqual(ad.sourceIndex, 2)
        XCTAssertNil(AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: ad.sourceIndex))
    }

    func testSkippedFirstFallbackDoesNotShiftEndScreenTwoTrigger() throws {
        let ads = try decodeFallbacks(#"{"ads":[{"type":"video","url":"bad"},{"ad_id":"second","html":"<html/>"}]}"#)
        let ad = try XCTUnwrap(ads.first)
        XCTAssertEqual(ad.sourceIndex, 1)
        XCTAssertEqual(
            AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: ad.sourceIndex),
            .endScreen2Open
        )
    }

    func testVideoGateUsesShorterOfConfiguredDelayAndDuration() {
        var gate = VideoPlaybackGate(configuredDelay: 30)
        gate.update(duration: 8, played: 3.9)
        XCTAssertEqual(gate.gateDuration, 8)
        XCTAssertFalse(gate.isUnlocked)
        XCTAssertFalse(gate.reachedAssetMidpoint)

        gate.update(duration: 8, played: 4)
        XCTAssertTrue(gate.reachedAssetMidpoint)
        XCTAssertEqual(gate.progress, 0.5, accuracy: 0.001)

        gate.update(duration: 8, played: 8)
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(gate.secondsRemaining, 0)
    }

    func testVideoEndUnlocksEvenBeforeGate() {
        var gate = VideoPlaybackGate(configuredDelay: 30)
        gate.update(duration: 20, played: 2, ended: true)
        XCTAssertTrue(gate.isUnlocked)
    }
}
