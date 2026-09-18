import XCTest
@testable import SimulaAdSDK

final class FallbackAdParsingTests: XCTestCase {
    private func decode(_ json: String) throws -> [FallbackAd] {
        try JSONDecoder().decode(FallbackAdsAPIResponse.self, from: Data(json.utf8)).resolvedAds
    }

    func testMissingOwnershipDefaultsToHTML() throws {
        let ads = try decode(#"{"ads":[{"ad_id":"a","html":"<html/>"}]}"#)
        XCTAssertEqual(ads.map(\.nativeClickBeaconV1Enabled), [false])
    }

    func testMalformedOwnershipDefaultsToHTMLWithoutDroppingAd() throws {
        let ads = try decode(#"{"native_click_beacon_v1_enabled":"true","ads":[{"ad_id":"a","html":"<html/>"}]}"#)
        XCTAssertEqual(ads.map(\.nativeClickBeaconV1Enabled), [false])
    }

    func testFalseResponseOwnershipKeepsHTMLOwner() throws {
        let ads = try decode(#"{"native_click_beacon_v1_enabled":false,"ads":[{"ad_id":"a","html":"<html/>"}]}"#)
        XCTAssertEqual(ads.map(\.nativeClickBeaconV1Enabled), [false])
    }

    func testTrueResponseOwnershipAppliesToEveryAd() throws {
        let ads = try decode(#"{"native_click_beacon_v1_enabled":true,"ads":[{"ad_id":"a","html":"a"},{"ad_id":"b","rendered_html":"b"}]}"#)
        XCTAssertEqual(ads.map(\.nativeClickBeaconV1Enabled), [true, true])
    }

    func testFalseItemOverrideWinsOverTrueResponseOwnership() throws {
        let ads = try decode(#"{"native_click_beacon_v1_enabled":true,"ads":[{"ad_id":"a","html":"a","native_click_beacon_v1_enabled":false}]}"#)
        XCTAssertEqual(ads.map(\.nativeClickBeaconV1Enabled), [false])
    }

    func testTrueItemOverrideWinsOverFalseResponseOwnership() throws {
        let ads = try decode(#"{"native_click_beacon_v1_enabled":false,"ads":[{"ad_id":"a","html":"a","native_click_beacon_v1_enabled":true}]}"#)
        XCTAssertEqual(ads.map(\.nativeClickBeaconV1Enabled), [true])
    }

    func testIframeOnlyFallbackIsDropped() throws {
        let ads = try decode(#"{"ads":[{"ad_id":"a","iframe_url":"https://example.com"}]}"#)
        XCTAssertTrue(ads.isEmpty)
    }

    func testRenderedHtmlWinsOverLegacyHtml() throws {
        let ads = try decode(#"{"ads":[{"ad_id":"a","rendered_html":"new","html":"old"}]}"#)
        XCTAssertEqual(ads.first?.renderedHtml, "new")
    }

    func testFallbackCloseMissingNullAndMalformedObjectsUseFallbackDefaults() throws {
        let ads = try decode(#"{"ads":[{"html":"a"},{"html":"b","ad_behavior":null},{"html":"c","ad_behavior":"bad"},{"html":"d","ad_behavior":{"close":17}}]}"#)

        XCTAssertEqual(ads.map(\.closeBehavior.delaySeconds), [5, 5, 5, 5])
        XCTAssertEqual(ads.map(\.closeBehavior.treatment), Array(repeating: .countdownCircle, count: 4))
        XCTAssertEqual(ads.map(\.closeBehavior.position), Array(repeating: .topRight, count: 4))
        XCTAssertEqual(ads.map(\.closeBehavior.action), Array(repeating: .closeX, count: 4))
    }

    func testFallbackClosePartialAndMalformedFieldsResolveIndependently() throws {
        let ads = try decode(#"{"ads":[{"html":"a","ad_behavior":{"close":{"delay_seconds":"9","treatment":"hidden","position":4,"action":"FORWARD"}}},{"html":"b"}]}"#)

        XCTAssertEqual(ads[0].closeBehavior.delaySeconds, 5)
        XCTAssertEqual(ads[0].closeBehavior.treatment, .hidden)
        XCTAssertEqual(ads[0].closeBehavior.position, .topRight)
        XCTAssertEqual(ads[0].closeBehavior.action, .forward)
    }

    func testFallbackDelayClampsToSafetyRange() throws {
        let ads = try decode(#"{"ads":[{"html":"a","ad_behavior":{"close":{"delay_seconds":-1}}},{"html":"b","ad_behavior":{"close":{"delay_seconds":600}}}]}"#)

        XCTAssertEqual(ads.map(\.closeBehavior.delaySeconds), [0, maxCloseDelaySeconds])
    }

    func testFallbackTreatmentAcceptsOnlyHiddenAndCountdownCircle() throws {
        let values: [(String, CloseTreatment)] = [
            ("hidden", .hidden),
            ("COUNTDOWN-CIRCLE", .countdownCircle),
            ("progress_bar", .countdownCircle),
            ("reward_or_close_label", .countdownCircle),
            ("unknown", .countdownCircle),
        ]

        for (raw, expected) in values {
            let ads = try decode(#"{"ads":[{"html":"a","ad_behavior":{"close":{"treatment":"\#(raw)"}}}]}"#)
            XCTAssertEqual(ads[0].closeBehavior.treatment, expected, raw)
        }
    }

    func testFallbackPositionAndActionParsingAreTolerant() throws {
        let ads = try decode(#"{"ads":[{"html":"a","ad_behavior":{"close":{"position":"TOP-LEFT","action":"FoRwArD"}}},{"html":"b","ad_behavior":{"close":{"position":"bottom-left","action":"CLOSE-X"}}},{"html":"c","ad_behavior":{"close":{"position":"elsewhere","action":"skip"}}}]}"#)

        XCTAssertEqual(ads.map(\.closeBehavior.position), [.topLeft, .bottomLeft, .topRight])
        XCTAssertEqual(ads.map(\.closeBehavior.action), [.forward, .closeX, .closeX])
    }

    func testFallbackItemsKeepIndependentCloseTimingTreatmentAndPosition() throws {
        let ads = try decode(#"{"ads":[{"html":"a","ad_behavior":{"close":{"delay_seconds":2,"treatment":"hidden","position":"top_left","action":"forward"}}},{"html":"b","ad_behavior":{"close":{"delay_seconds":9,"treatment":"countdown_circle","position":"bottom_left","action":"forward"}}}]}"#)

        XCTAssertEqual(ads[0].closeBehavior.delaySeconds, 2)
        XCTAssertEqual(ads[0].closeBehavior.treatment, .hidden)
        XCTAssertEqual(ads[0].closeBehavior.position, .topLeft)
        XCTAssertEqual(ads[0].closeBehavior.action, .forward)
        XCTAssertEqual(ads[1].closeBehavior.delaySeconds, 9)
        XCTAssertEqual(ads[1].closeBehavior.treatment, .countdownCircle)
        XCTAssertEqual(ads[1].closeBehavior.position, .bottomLeft)
        XCTAssertEqual(ads[1].closeBehavior.action, .closeX, "ES2 must close even when configured forward")
    }

    func testOnlyResolvedUsableES1CanRetainForward() throws {
        let ads = try decode(#"{"ads":[{"ad_id":"unusable","ad_behavior":{"close":{"action":"forward"}}},{"ad_id":"es1","html":"a","ad_behavior":{"close":{"action":"forward"}}},{"ad_id":"es2","html":"b","ad_behavior":{"close":{"action":"forward"}}},{"ad_id":"later","html":"c","ad_behavior":{"close":{"action":"forward"}}}]}"#)

        XCTAssertEqual(ads.map(\.adId), ["es1", "es2", "later"])
        XCTAssertEqual(ads.map(\.closeBehavior.action), [.forward, .closeX, .closeX])
    }

    func testES1WithoutNextUsableFallbackForcesClose() throws {
        let ads = try decode(#"{"ads":[{"html":"a","ad_behavior":{"close":{"action":"forward"}}},{"ad_id":"unusable","ad_behavior":{"close":{"action":"forward"}}}]}"#)
        XCTAssertEqual(ads.map(\.closeBehavior.action), [.closeX])
    }

    func testWhitespaceOnlySuccessorDoesNotEnableES1Forward() throws {
        let ads = try decode(#"{"ads":[{"html":"a","ad_behavior":{"close":{"action":"forward"}}},{"html":" \n\t ","iframe_url":"   "}]}"#)

        XCTAssertEqual(ads.count, 1)
        XCTAssertEqual(ads[0].closeBehavior.action, .closeX)
    }

    func testFallbackActionRoleResolver() {
        XCTAssertEqual(resolvedFallbackCloseAction(configured: .forward, usableIndex: 0, usableCount: 2), .forward)
        XCTAssertEqual(resolvedFallbackCloseAction(configured: .closeX, usableIndex: 0, usableCount: 2), .closeX)
        XCTAssertEqual(resolvedFallbackCloseAction(configured: .forward, usableIndex: 0, usableCount: 1), .closeX)
        XCTAssertEqual(resolvedFallbackCloseAction(configured: .forward, usableIndex: 1, usableCount: 3), .closeX)
        XCTAssertEqual(resolvedFallbackCloseAction(configured: .forward, usableIndex: 2, usableCount: 3), .closeX)
    }

    func testPrimaryAndRewardedDecodeTheirOwnCloseActions() throws {
        let primary = try JSONDecoder().decode(
            AdLoadResponse.self,
            from: Data(#"{"impression_id":"p","ad_behavior":{"close":{"action":"FORWARD"}}}"#.utf8)
        )
        let rewarded = try JSONDecoder().decode(
            RewardedInitResponse.self,
            from: Data(#"{"impression_id":"r","ad_behavior":{"close":{"action":"close-x"}}}"#.utf8)
        )

        XCTAssertEqual(primary.adBehavior?.close.action, .forward)
        XCTAssertEqual(rewarded.adBehavior?.close.action, .closeX)
    }

    func testPrimaryCloseActionMissingAndUnknownDefaultToCloseX() throws {
        let missing = try JSONDecoder().decode(CloseBehavior.self, from: Data("{}".utf8))
        let unknown = try JSONDecoder().decode(CloseBehavior.self, from: Data(#"{"action":"skip"}"#.utf8))
        XCTAssertEqual(missing.action, .closeX)
        XCTAssertEqual(unknown.action, .closeX)
    }

    func testFallbackCountdownPolicySupportsConfiguredAndZeroDurations() {
        let zero = FallbackCountdownPolicy(delaySeconds: 0)
        XCTAssertEqual(zero.totalMilliseconds, 0)
        XCTAssertFalse(zero.needsTicker)

        let configured = FallbackCountdownPolicy(delaySeconds: 7)
        XCTAssertEqual(configured.totalMilliseconds, 7_000)
        XCTAssertTrue(configured.needsTicker)

        XCTAssertEqual(FallbackCountdownPolicy(delaySeconds: 100).delaySeconds, maxCloseDelaySeconds)
    }
}
