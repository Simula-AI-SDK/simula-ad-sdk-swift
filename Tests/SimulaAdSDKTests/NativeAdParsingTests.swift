import XCTest
@testable import SimulaAdSDK

/// Contract tests for the `POST /load/native` request/response models (backend `CaiNativeRequest` /
/// `CaiNativeResponse`). Pure Codable — no network.
final class NativeAdParsingTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Request

    func testRequestEncodesRequiredKeysAndSnakeCaseCharFields() throws {
        let body = try JSONEncoder().encode(
            NativeAdRequest(position: 3, sessionId: "sess_9", adUnitId: "au_1", charId: "c_7")
        )
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["position"] as? Int, 3)
        XCTAssertEqual(obj["session_id"] as? String, "sess_9")
        XCTAssertEqual(obj["ad_unit_id"] as? String, "au_1")
        XCTAssertEqual(obj["char_id"] as? String, "c_7")
        // The native surface has no char_image (unlike the interstitial).
        XCTAssertNil(obj["char_image"])
    }

    func testContextEncodesCamelCaseWireKeys() throws {
        let ctx = SimulaAdContext(
            searchTerm: "fantasy rpg",
            tags: ["adventure", "magic"],
            category: "roleplay",
            userEmail: "a@b.com",
            customContext: ["recent": "Frieren"],
            nsfw: false
        )
        let body = try JSONEncoder().encode(
            NativeAdRequest(position: 0, sessionId: "s", context: ctx)
        )
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let context = try XCTUnwrap(obj["context"] as? [String: Any])
        // NativeContext is the one camelCase object in the otherwise snake_case API.
        XCTAssertEqual(context["searchTerm"] as? String, "fantasy rpg")
        XCTAssertEqual(context["userEmail"] as? String, "a@b.com")
        XCTAssertEqual(context["category"] as? String, "roleplay")
        XCTAssertEqual((context["customContext"] as? [String: Any])?["recent"] as? String, "Frieren")
        XCTAssertEqual(context["nsfw"] as? Bool, false)
        // No snake_case leakage.
        XCTAssertNil(context["search_term"])
        XCTAssertNil(context["user_email"])
    }

    // MARK: - Response

    func testFillResponseDecodesCamelCaseAdResponseWrapper() throws {
        let json = """
        {
          "impression_id": "serve-123",
          "ad_inserted": true,
          "ad_format": "character_ad",
          "adResponse": {
            "iframe_url": "https://api/iframe/abc",
            "rendered_html": "<iframe srcdoc=...></iframe>"
          }
        }
        """
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        XCTAssertEqual(r.impressionId, "serve-123")
        XCTAssertTrue(r.adInserted)
        XCTAssertEqual(r.adFormat, "character_ad")
        XCTAssertEqual(r.iframeURL, "https://api/iframe/abc")
        XCTAssertTrue(r.hasCreative)
    }

    func testNoFillResponseDecodesWithNullImpressionAndEmptyCreative() throws {
        let json = #"{"impression_id":null,"ad_inserted":false,"ad_format":"","adResponse":{}}"#
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        XCTAssertNil(r.impressionId)
        XCTAssertFalse(r.adInserted)
        XCTAssertEqual(r.adFormat, "")
        XCTAssertNil(r.iframeURL)
        XCTAssertNil(r.renderedHTML)
        XCTAssertFalse(r.hasCreative)
    }

    func testEmptyObjectDecodesToSafeDefaults() throws {
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data("{}"))
        XCTAssertNil(r.impressionId)
        XCTAssertFalse(r.adInserted)
        XCTAssertEqual(r.adFormat, "")
        XCTAssertFalse(r.hasCreative)
    }

    func testUnknownKeysAreIgnored() throws {
        let json = #"{"ad_inserted":true,"ad_format":"character_ad","adResponse":{"iframe_url":"u"},"future":1}"#
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        XCTAssertTrue(r.adInserted)
        XCTAssertEqual(r.iframeURL, "u")
    }
}
