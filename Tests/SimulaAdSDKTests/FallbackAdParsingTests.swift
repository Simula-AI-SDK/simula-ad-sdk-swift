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
        let ads = try decode(#"{"native_click_beacon_v1_enabled":true,"ads":[{"ad_id":"a","html":"a"},{"ad_id":"b","iframe_url":"https://example.com"}]}"#)
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
}
