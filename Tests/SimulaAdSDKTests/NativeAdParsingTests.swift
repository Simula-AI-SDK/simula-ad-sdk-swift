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

    func testThemeEncodesTopLevelWhenSet() throws {
        let body = try JSONEncoder().encode(
            NativeAdRequest(position: 0, sessionId: "s", theme: "dark")
        )
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // theme is a top-level sibling of position / session_id, not nested.
        XCTAssertEqual(obj["theme"] as? String, "dark")
    }

    func testThemeOmittedWhenNil() throws {
        let body = try JSONEncoder().encode(NativeAdRequest(position: 0, sessionId: "s"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(obj["theme"]) // omitted entirely → backend defaults to light
    }

    func testContextEncodesCamelCaseWireKeys() throws {
        let ctx = SimulaAdContext(
            searchTerm: "fantasy rpg",
            tags: ["adventure", "magic"],
            category: "roleplay",
            userEmail: "a@b.com",
            customContext: [
                "recent": "Frieren",
                "episodes": 28,
                "rating": 4.7,
                "watching": true,
                "genres": ["fantasy", "adventure"],
                "meta": ["subbed": true],
            ],
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
        // customContext carries arbitrary JSON, not just strings.
        let custom = try XCTUnwrap(context["customContext"] as? [String: Any])
        XCTAssertEqual(custom["recent"] as? String, "Frieren")
        XCTAssertEqual(custom["episodes"] as? Int, 28)
        XCTAssertEqual(custom["rating"] as? Double, 4.7)
        XCTAssertEqual(custom["watching"] as? Bool, true)
        XCTAssertEqual(custom["genres"] as? [String], ["fantasy", "adventure"])
        XCTAssertEqual((custom["meta"] as? [String: Any])?["subbed"] as? Bool, true)
        XCTAssertEqual(context["nsfw"] as? Bool, false)
        // No snake_case leakage.
        XCTAssertNil(context["search_term"])
        XCTAssertNil(context["user_email"])
    }

    func testCustomContextSupportsNestedMaps() throws {
        // Maps inside maps inside maps — JSONValue.object nests to any depth.
        let ctx = SimulaAdContext(customContext: [
            "profile": [
                "prefs": [
                    "theme": "dark",
                    "limits": ["maxAds": 3],
                ],
                "tags": ["a", "b"],
            ],
        ])
        let body = try JSONEncoder().encode(
            NativeAdRequest(position: 0, sessionId: "s", context: ctx)
        )
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let custom = try XCTUnwrap((obj["context"] as? [String: Any])?["customContext"] as? [String: Any])
        let profile = try XCTUnwrap(custom["profile"] as? [String: Any])
        let prefs = try XCTUnwrap(profile["prefs"] as? [String: Any])
        XCTAssertEqual(prefs["theme"] as? String, "dark")
        XCTAssertEqual((prefs["limits"] as? [String: Any])?["maxAds"] as? Int, 3)
        XCTAssertEqual(profile["tags"] as? [String], ["a", "b"])
    }

    func testCustomContextStringValuesAreWireCompatible() throws {
        // Back-compat guard: a string-valued entry must encode to the exact same bytes it did when
        // customContext was [String: String] — plain {"key":"value"}, no enum-case wrapper leakage.
        let ctx = SimulaAdContext(customContext: ["recent": "Frieren", "mood": "calm"])
        let body = try JSONEncoder().encode(ctx)
        let custom = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: body) as? [String: Any])?["customContext"] as? [String: Any]
        )
        XCTAssertEqual(custom as? [String: String], ["recent": "Frieren", "mood": "calm"])
        // Raw substring check: no ".string"/"_0"/case-name artifacts in the JSON text.
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"recent\":\"Frieren\""))
        XCTAssertFalse(text.contains("string"))
        XCTAssertFalse(text.contains("_0"))
    }

    func testCustomContextOmittedWhenNil() throws {
        // nil customContext must be omitted entirely, not sent as "customContext":null.
        let ctx = SimulaAdContext(searchTerm: "x")
        let text = String(decoding: try JSONEncoder().encode(ctx), as: UTF8.self)
        XCTAssertFalse(text.contains("customContext"))
    }

    func testJSONValueRoundTripsThroughDecode() throws {
        // JSONValue is public Codable; verify decode disambiguates types (esp. Bool vs Int).
        let original: [String: JSONValue] = [
            "s": "txt", "i": 7, "d": 1.5, "b": true, "z": 0,
            "arr": [1, "two", false], "obj": ["k": "v"], "nil": nil,
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(decoded["s"], .string("txt"))
        XCTAssertEqual(decoded["i"], .int(7))
        XCTAssertEqual(decoded["d"], .double(1.5))
        XCTAssertEqual(decoded["b"], .bool(true))   // not .int(1)
        XCTAssertEqual(decoded["z"], .int(0))       // not .bool(false)
        XCTAssertEqual(decoded["arr"], .array([.int(1), .string("two"), .bool(false)]))
        XCTAssertEqual(decoded["obj"], .object(["k": .string("v")]))
        XCTAssertEqual(decoded["nil"], JSONValue.null)
    }

    // MARK: - Response

    func testFillResponseDecodesFlatCreativeAndClickThroughParams() throws {
        let json = """
        {
          "impression_id": "serve-123",
          "ad_inserted": true,
          "ad_format": "character_ad",
          "iframe_url": "https://api/iframe/abc",
          "rendered_html": "<iframe srcdoc=...></iframe>",
          "destination": "web",
          "tracking_url": "https://mmp.example/click?cid=1"
        }
        """
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        XCTAssertEqual(r.impressionId, "serve-123")
        XCTAssertTrue(r.adInserted)
        XCTAssertEqual(r.adFormat, "character_ad")
        XCTAssertEqual(r.iframeURL, "https://api/iframe/abc")
        XCTAssertEqual(r.destination, "web")
        XCTAssertEqual(r.destinationKind, .web)
        XCTAssertEqual(r.trackingUrl, "https://mmp.example/click?cid=1")
        XCTAssertTrue(r.hasCreative)
    }

    func testDestinationDefaultsToAppStoreAndTrackingURLToNilWhenOmitted() throws {
        let json = #"{"impression_id":"s","ad_inserted":true,"ad_format":"character_ad","iframe_url":"u"}"#
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        XCTAssertEqual(r.destination, "appstore")
        XCTAssertEqual(r.destinationKind, .appstore)
        XCTAssertNil(r.trackingUrl)
    }

    func testNoFillResponseDecodesWithNullImpressionAndEmptyCreative() throws {
        let json = #"{"impression_id":null,"ad_inserted":false,"ad_format":""}"#
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        XCTAssertNil(r.impressionId)
        XCTAssertFalse(r.adInserted)
        XCTAssertEqual(r.adFormat, "")
        XCTAssertNil(r.iframeURL)
        XCTAssertNil(r.renderedHTML)
        XCTAssertEqual(r.destination, "appstore")
        XCTAssertNil(r.trackingUrl)
        XCTAssertFalse(r.hasCreative)
    }

    func testEmptyObjectDecodesToSafeDefaults() throws {
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data("{}"))
        XCTAssertNil(r.impressionId)
        XCTAssertFalse(r.adInserted)
        XCTAssertEqual(r.adFormat, "")
        XCTAssertEqual(r.destination, "appstore")
        XCTAssertFalse(r.hasCreative)
    }

    func testUnknownKeysAreIgnored() throws {
        let json = #"{"ad_inserted":true,"ad_format":"character_ad","iframe_url":"u","future":1}"#
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        XCTAssertTrue(r.adInserted)
        XCTAssertEqual(r.iframeURL, "u")
    }

    // MARK: - skan_attribution (parity with interstitial/rewarded)

    func testSkanAttributionDecodesAtResponseRoot() throws {
        let json = """
        {
          "impression_id": "serve-123",
          "ad_inserted": true,
          "ad_format": "character_ad",
          "iframe_url": "https://api/iframe/abc",
          "destination": "appstore",
          "tracking_url": "https://mmp.example/click?cid=1",
          "skan_attribution": {
            "campaign_token": "camp_tok", "provider_token": "prov_tok",
            "skan": {"version":"4.0","ad_network_id":"net123.skadnetwork","source_app_store_id":987654321,
              "nonce":"00000000-0000-0000-0000-000000000001","timestamp":1700000000000,
              "attribution_signature":"sig==","source_id":1234}
          }
        }
        """
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        let a = try XCTUnwrap(r.skanAttribution)
        XCTAssertTrue(a.hasUsableTokens)
        XCTAssertEqual(a.campaignToken, "camp_tok")
        XCTAssertEqual(a.providerToken, "prov_tok")
        XCTAssertEqual(a.skan?.version, "4.0")
        XCTAssertEqual(a.skan?.sourceIdentifier, 1234)
    }

    func testSkanAttributionAbsentIsNil() throws {
        let json = #"{"impression_id":"s","ad_inserted":true,"ad_format":"character_ad","iframe_url":"u"}"#
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        XCTAssertNil(r.skanAttribution)
    }

    func testSkanAttributionEmptyObjectHasNoUsableTokens() throws {
        // A present-but-empty object decodes (non-nil), but carries nothing usable → callers treat it
        // as "absent" and keep today's external open.
        let json = #"{"impression_id":"s","ad_inserted":true,"ad_format":"character_ad","iframe_url":"u","skan_attribution":{}}"#
        let r = try JSONDecoder().decode(NativeAdResponse.self, from: data(json))
        let a = try XCTUnwrap(r.skanAttribution)
        XCTAssertFalse(a.hasUsableTokens)
    }
}
