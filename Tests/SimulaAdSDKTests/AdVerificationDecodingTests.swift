import XCTest
@testable import SimulaAdSDK

/// Pure-Foundation decode tests for the OMID `ad_verifications` wire shape on
/// `AdLoadResponse` / `RewardedInitResponse`. No OMID framework or UIKit here, so these
/// run on the macOS test host (where OM itself is a no-op stub).
final class AdVerificationDecodingTests: XCTestCase {

    private func decodeAdLoad(_ json: String) throws -> AdLoadResponse {
        try JSONDecoder().decode(AdLoadResponse.self, from: Data(json.utf8))
    }

    func testAdVerificationsAbsentIsEmpty() throws {
        let r = try decodeAdLoad("""
        {"ad_id":"x","ad_inserted":true,"rendered_html":"<b>hi</b>"}
        """)
        XCTAssertTrue(r.adVerifications.isEmpty)
    }

    func testAdVerificationsFullEntryDecodes() throws {
        let r = try decodeAdLoad("""
        {"ad_id":"x","ad_inserted":true,
         "ad_verifications":[
           {"vendor_key":"iabtechlab.com-omid",
            "javascript_resource_url":"https://verify.example.com/omid.js",
            "verification_parameters":"https://verify.example.com/event"}]}
        """)
        XCTAssertEqual(r.adVerifications.count, 1)
        XCTAssertEqual(r.adVerifications[0].vendorKey, "iabtechlab.com-omid")
        XCTAssertEqual(r.adVerifications[0].javascriptResourceUrl, "https://verify.example.com/omid.js")
        XCTAssertEqual(r.adVerifications[0].verificationParameters, "https://verify.example.com/event")
    }

    func testAdVerificationsDropsEntriesWithoutURL() throws {
        // An entry missing javascript_resource_url is unusable → filtered; a valid one survives.
        let r = try decodeAdLoad("""
        {"ad_verifications":[
           {"vendor_key":"no-url"},
           {"javascript_resource_url":"https://ok.example/v.js"}]}
        """)
        XCTAssertEqual(r.adVerifications.count, 1)
        XCTAssertEqual(r.adVerifications[0].javascriptResourceUrl, "https://ok.example/v.js")
        XCTAssertNil(r.adVerifications[0].vendorKey)
        XCTAssertNil(r.adVerifications[0].verificationParameters)
    }

    func testAdVerificationsTolerateUnknownKeys() throws {
        let r = try decodeAdLoad("""
        {"ad_verifications":[{"javascript_resource_url":"https://v","future":true}]}
        """)
        XCTAssertEqual(r.adVerifications.count, 1)
        XCTAssertEqual(r.adVerifications[0].javascriptResourceUrl, "https://v")
    }

    func testRewardedInitDecodesAdVerifications() throws {
        let r = try JSONDecoder().decode(RewardedInitResponse.self, from: Data("""
        {"serve_id":"s","iframe_url":"https://game","duration_seconds":5,
         "ad_verifications":[{"javascript_resource_url":"https://v.js"}]}
        """.utf8))
        XCTAssertEqual(r.adVerifications.count, 1)
        XCTAssertEqual(r.iframeUrl, "https://game")
    }

    func testWithRenderedHtmlPreservesVerifications() {
        let original = AdLoadResponse(
            adId: "x", adInserted: true, adUnitId: "u", renderedHtml: "<a>",
            adVerifications: [
                AdVerification(vendorKey: "v", javascriptResourceUrl: "https://v", verificationParameters: nil)
            ]
        )
        let injected = original.withRenderedHtml("<a>injected</a>")
        XCTAssertEqual(injected.renderedHtml, "<a>injected</a>")
        XCTAssertEqual(injected.adVerifications.count, 1)
        XCTAssertEqual(injected.adId, "x")
    }
}
