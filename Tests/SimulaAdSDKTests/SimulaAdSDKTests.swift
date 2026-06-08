import XCTest
import SwiftUI
@testable import SimulaAdSDK

final class SimulaAdSDKTests: XCTestCase {
    func testColorHexParsing() {
        // Basic smoke test for Color(hex:) initialization
        // More comprehensive tests can be added as needed
        let _ = SwiftUI.Color(hex: "#FF0000")
        let _ = SwiftUI.Color(hex: "#00FF00FF")
        let _ = SwiftUI.Color(hex: "rgba(255, 0, 0, 0.5)")
        let _ = SwiftUI.Color(hex: "transparent")
    }

    func testMiniGameInviteKitTypes() {
        // Verify that the MiniGameInviteKit namespace correctly aliases the
        // declarative invite components. (The interstitial here is the declarative
        // `MiniGameInterstitial`; the imperative ad is `SimulaInterstitialAd`.)
        XCTAssertTrue(MiniGameInviteKit.Invitation.self == MiniGameInvitation.self)
        XCTAssertTrue(MiniGameInviteKit.Button.self == MiniGameButton.self)
        XCTAssertTrue(MiniGameInviteKit.Interstitial.self == MiniGameInterstitial.self)
    }

    // MARK: - Imperative interstitial (SimulaInterstitialAd) state guards

    @MainActor
    func testLoadBeforeInitFiresLoadFailedNotInitialized() {
        // This test assumes the SDK has not been initialized in the test process
        // (no test calls SimulaAds.initialize), so load() must fail fast.
        XCTAssertFalse(SimulaAds.isInitialized, "Test assumes SimulaAds is not initialized")

        let delegate = InterstitialMockDelegate()
        let ad = SimulaInterstitialAd(adUnitId: "test_unit")
        ad.delegate = delegate

        ad.load()

        guard case .notInitialized? = delegate.loadFailedError else {
            return XCTFail("Expected .notInitialized, got \(String(describing: delegate.loadFailedError))")
        }
    }

    @MainActor
    func testShowBeforeLoadFiresDisplayFailedNotReady() {
        let delegate = InterstitialMockDelegate()
        let ad = SimulaInterstitialAd(adUnitId: "test_unit")
        ad.delegate = delegate

        ad.show()

        guard case .notReady? = delegate.displayFailedError else {
            return XCTFail("Expected .notReady, got \(String(describing: delegate.displayFailedError))")
        }
    }

    @MainActor
    func testInterstitialStoresConfiguration() {
        let ad = SimulaInterstitialAd(adUnitId: "unit_42")
        XCTAssertEqual(ad.adUnitId, "unit_42")
    }

    func testMaxGamesToShowValues() {
        XCTAssertEqual(MaxGamesToShow.three.rawValue, 3)
        XCTAssertEqual(MaxGamesToShow.six.rawValue, 6)
        XCTAssertEqual(MaxGamesToShow.nine.rawValue, 9)
    }

    func testThemeDefaults() {
        let theme = MiniGameTheme()
        XCTAssertEqual(theme.resolvedBackgroundColor, "#0b0b0f")
        XCTAssertEqual(theme.resolvedAccentColor, "#3B82F6")
        XCTAssertEqual(theme.resolvedIconCornerRadius, 8)
    }

    // MARK: - Catalog parsing (parseCatalog)

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParseCatalogNestedDataShape() throws {
        let json = """
        {"menu_id":"m1","catalog":{"data":[
          {"id":"g1","name":"Game One","icon":"https://x/i.png","gif_cover":"https://x/c.gif"}
        ]}}
        """
        let result = try parseCatalog(data(json))
        XCTAssertEqual(result.menuId, "m1")
        XCTAssertEqual(result.games.count, 1)
        XCTAssertEqual(result.games[0].id, "g1")
        XCTAssertEqual(result.games[0].iconUrl, "https://x/i.png")
        XCTAssertEqual(result.games[0].gifCover, "https://x/c.gif")
    }

    func testParseCatalogDirectArrayShape() throws {
        let json = """
        {"menu_id":"m2","catalog":[{"id":"g1","name":"G1"},{"id":"g2","name":"G2"}]}
        """
        let result = try parseCatalog(data(json))
        XCTAssertEqual(result.menuId, "m2")
        XCTAssertEqual(result.games.map(\.id), ["g1", "g2"])
    }

    func testParseCatalogTopLevelDataShape() throws {
        let json = #"{"data":[{"id":"g1","name":"G1"}]}"#
        let result = try parseCatalog(data(json))
        XCTAssertEqual(result.menuId, "")
        XCTAssertEqual(result.games.count, 1)
    }

    func testParseCatalogBareArrayShape() throws {
        let json = #"[{"id":"g1","name":"G1"}]"#
        let result = try parseCatalog(data(json))
        XCTAssertEqual(result.games.count, 1)
        XCTAssertEqual(result.games[0].name, "G1")
    }

    func testParseCatalogDropsInvalidGamesButKeepsRest() throws {
        // Second entry is missing the required "name" — it should be dropped,
        // not abort the whole catalog.
        let json = """
        {"catalog":[{"id":"g1","name":"Good"},{"id":"g2"},{"id":"g3","name":"AlsoGood"}]}
        """
        let result = try parseCatalog(data(json))
        XCTAssertEqual(result.games.map(\.id), ["g1", "g3"])
    }

    func testParseCatalogGifCoverCamelCase() throws {
        let json = #"{"catalog":[{"id":"g1","name":"G1","gifCover":"https://x/c.gif"}]}"#
        let result = try parseCatalog(data(json))
        XCTAssertEqual(result.games.first?.gifCover, "https://x/c.gif")
    }

    func testParseCatalogInvalidJSONThrows() {
        XCTAssertThrowsError(try parseCatalog(data("not json")))
    }

    // MARK: - Catalog request URL (session_id query)

    func testCatalogURLAppendsSessionId() throws {
        let url = try XCTUnwrap(SimulaAPI.catalogURL(sessionId: "sess_9"))
        XCTAssertTrue(url.absoluteString.hasSuffix("/minigames/catalogv2?session_id=sess_9"),
                      "Unexpected URL: \(url.absoluteString)")
    }

    func testCatalogURLOmitsSessionWhenNilOrEmpty() throws {
        XCTAssertNil(try XCTUnwrap(SimulaAPI.catalogURL(sessionId: nil)).query)
        XCTAssertNil(try XCTUnwrap(SimulaAPI.catalogURL(sessionId: "")).query)
    }

    func testCatalogURLEncodesSpecialCharacters() throws {
        let url = try XCTUnwrap(SimulaAPI.catalogURL(sessionId: "a b&c"))
        // Round-trips back to the original value (decoded)...
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "session_id" })?.value, "a b&c")
        // ...and the raw string is percent-encoded (no literal space/&).
        XCTAssertFalse(url.absoluteString.contains("a b&c"))
    }

    // MARK: - Ad load parsing (AdLoadResponse decode)

    private func decodeAdLoad(_ json: String) throws -> AdLoadResponse {
        try JSONDecoder().decode(AdLoadResponse.self, from: data(json))
    }

    func testAdLoadHappyPath() throws {
        let json = """
        {"ad_id":"ad_1","ad_inserted":true,"ad_unit_id":"unit_1","rewarded":true,
         "destination":"web","rendered_format":"rewarded_video",
         "rendered_html":"<b>hi</b>",
         "tracking_url":"https://x/click"}
        """
        let r = try decodeAdLoad(json)
        XCTAssertEqual(r.adId, "ad_1")
        XCTAssertTrue(r.adInserted)
        XCTAssertEqual(r.adUnitId, "unit_1")
        XCTAssertEqual(r.destination, "web")
        XCTAssertEqual(r.destinationKind, .web)
        XCTAssertEqual(r.renderedFormat, "rewarded_video")
        XCTAssertEqual(r.renderedHtml, "<b>hi</b>")
        XCTAssertEqual(r.trackingUrl, "https://x/click")
    }

    func testAdLoadDestinationDefaultsToAppstoreWhenAbsent() throws {
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertEqual(r.destination, "appstore")
        XCTAssertEqual(r.destinationKind, .appstore)
    }

    func testAdLoadDestinationUnknownFallsBackToAppstore() throws {
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"destination":"carousel"}"#
        let r = try decodeAdLoad(json)
        // The raw string is preserved, but destinationKind maps unknown → .appstore.
        XCTAssertEqual(r.destination, "carousel")
        XCTAssertEqual(r.destinationKind, .appstore)
    }

    func testAdLoadMissingRenderedFormatIsNil() throws {
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertNil(r.renderedFormat)
    }

    func testAdLoadAdInsertedFalseDecodes() throws {
        let json = #"{"ad_id":"a","ad_inserted":false,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertFalse(r.adInserted)
    }

    func testAdLoadMalformedJSONThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(AdLoadResponse.self, from: Data("not json".utf8)))
    }

    // MARK: - Ad load: rendered_html (HTML creative precedence)

    func testAdLoadDecodesRenderedHtml() throws {
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "rendered_html":"<html><body>hi</body></html>"}
        """
        let r = try decodeAdLoad(json)
        XCTAssertEqual(r.renderedHtml, "<html><body>hi</body></html>")
        // Present & non-blank → htmlCreative is the renderable creative.
        XCTAssertEqual(r.htmlCreative, "<html><body>hi</body></html>")
    }

    func testAdLoadRenderedHtmlAbsentIsNil() throws {
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertNil(r.renderedHtml)
        XCTAssertNil(r.htmlCreative)
    }

    func testAdLoadRenderedHtmlBlankYieldsNilCreative() throws {
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"rendered_html":"   \n\t  "}"#
        let r = try decodeAdLoad(json)
        // The raw whitespace string is preserved by the decoder...
        XCTAssertFalse(r.renderedHtml?.isEmpty ?? true)
        // ...but htmlCreative trims it away → no renderable creative (no-fill).
        XCTAssertNil(r.htmlCreative)
    }

    /// A payload with a non-blank `rendered_html` is fillable (mirrors the `load()`
    /// no-fill rule: fill = adInserted && htmlCreative != nil).
    func testAdLoadHtmlOnlyPayloadIsFillable() throws {
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"rendered_html":"<b>x</b>"}"#
        let r = try decodeAdLoad(json)
        XCTAssertNotNil(r.htmlCreative)
        XCTAssertTrue(r.adInserted && r.htmlCreative != nil)
    }

    /// No `rendered_html` (even with `ad_inserted == true`) is a no-fill: there is
    /// no other creative to render now that the carousel/asset path is gone.
    func testAdLoadNoHtmlIsNoFill() throws {
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertNil(r.htmlCreative)
        XCTAssertFalse(r.adInserted && r.htmlCreative != nil)
    }

    // MARK: - Ad load request (AdLoadRequest encode)

    func testAdLoadRequestEncodesSnakeCaseKeys() throws {
        let body = AdLoadRequest(adUnitId: "unit_1", sessionId: "sess_9")
        let encoded = try JSONEncoder().encode(body)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(obj?["ad_unit_id"] as? String, "unit_1")
        XCTAssertEqual(obj?["session_id"] as? String, "sess_9")
        // `rewarded` is no longer part of the request body.
        XCTAssertNil(obj?["rewarded"])
    }

    func testAdLoadRequestDefaults() {
        let body = AdLoadRequest(adUnitId: "unit_1")
        XCTAssertEqual(body.sessionId, "")
        XCTAssertNil(body.charId)
        XCTAssertNil(body.charName)
        XCTAssertNil(body.charImage)
        XCTAssertNil(body.charDesc)
    }

    func testAdLoadRequestEncodesCharFieldsWhenSet() throws {
        let body = AdLoadRequest(
            adUnitId: "u",
            charId: "char_7",
            charName: "Mentor",
            charImage: "https://cdn.example.com/avatar.png",
            charDesc: "a wise mentor"
        )
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(obj?["char_id"] as? String, "char_7")
        XCTAssertEqual(obj?["char_name"] as? String, "Mentor")
        XCTAssertEqual(obj?["char_image"] as? String, "https://cdn.example.com/avatar.png")
        XCTAssertEqual(obj?["char_desc"] as? String, "a wise mentor")
    }

    func testAdLoadRequestOmitsCharFieldsWhenNil() throws {
        let body = AdLoadRequest(adUnitId: "u")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        // Synthesized `encodeIfPresent` drops nil optionals → keys absent on the wire.
        XCTAssertNil(obj?["char_id"])
        XCTAssertNil(obj?["char_name"])
        XCTAssertNil(obj?["char_image"])
        XCTAssertNil(obj?["char_desc"])
    }

    // MARK: - AdDestination raw values

    func testAdDestinationRawValues() {
        XCTAssertEqual(AdDestination(rawValue: "appstore"), .appstore)
        XCTAssertEqual(AdDestination(rawValue: "web"), .web)
        XCTAssertNil(AdDestination(rawValue: "carousel"))
    }

    // MARK: - Ad behavior (ad_behavior decode, v2 schema)

    func testAdBehaviorAbsentDecodesToNil() throws {
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        // Absent ad_behavior → nil so the renderer falls back to today's literal behavior.
        XCTAssertNil(r.adBehavior)
        XCTAssertNil(r.creative)
        XCTAssertNil(r.experiment)
    }

    func testAdBehaviorHappyPath() throws {
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "creative":{"type":"playable","bundle_url":"https://b","ad_unit_type":"rewarded"},
         "experiment":{"experiment_id":"playable_close_q3","variant_id":"countdown_circle_top_right_3s","layer":"close_chrome"},
         "ad_behavior":{"close":{"delay_seconds":3,"treatment":"countdown_circle",
           "position":"top_right","progress_bar_color":"#00FF00"},
           "store_prompt":{"enabled":true,"trigger":"midpoint","position":"top_left","platform":"ios"},
           "skoverlay":{"enabled":true,"timing":"on_click","delay_seconds":0,"position":"bottom","dismissible":true}}}
        """
        let r = try decodeAdLoad(json)
        let b = try XCTUnwrap(r.adBehavior)
        XCTAssertEqual(b.close.delaySeconds, 3)
        XCTAssertEqual(b.close.treatment, .countdownCircle)
        XCTAssertEqual(b.close.position, .topRight)
        XCTAssertEqual(b.close.progressBarColor, "#00FF00")

        let prompt = try XCTUnwrap(b.storePrompt)
        XCTAssertTrue(prompt.enabled)
        XCTAssertEqual(prompt.position, .topLeft)
        XCTAssertEqual(prompt.platform, .ios)

        let overlay = try XCTUnwrap(b.skoverlay)
        XCTAssertTrue(overlay.enabled)
        XCTAssertEqual(overlay.timing, .onClick)
        XCTAssertEqual(overlay.position, .bottom)
        XCTAssertTrue(overlay.dismissible)

        XCTAssertEqual(r.creative?.adUnitType, .rewarded)
        XCTAssertEqual(r.creative?.bundleUrl, "https://b")
        XCTAssertEqual(r.adUnitType, .rewarded)
        XCTAssertEqual(r.experiment?.experimentId, "playable_close_q3")
        XCTAssertEqual(r.experiment?.variantId, "countdown_circle_top_right_3s")
        XCTAssertEqual(r.experiment?.layer, "close_chrome")
    }

    func testAdBehaviorEmptyObjectUsesDefaults() throws {
        // Present-but-empty ad_behavior is non-nil and fully defaulted; the new nodes stay nil.
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"ad_behavior":{}}"#
        let b = try XCTUnwrap(try decodeAdLoad(json).adBehavior)
        XCTAssertEqual(b.close.delaySeconds, 0)
        XCTAssertEqual(b.close.treatment, .hidden)
        XCTAssertEqual(b.close.position, .topRight)
        XCTAssertEqual(b.close.progressBarColor, "#FFFFFF")
        XCTAssertNil(b.storePrompt)
        XCTAssertNil(b.skoverlay)
    }

    func testAdBehaviorPartialCloseFillsDefaults() throws {
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"delay_seconds":3}}}
        """
        let b = try XCTUnwrap(try decodeAdLoad(json).adBehavior)
        XCTAssertEqual(b.close.delaySeconds, 3)
        XCTAssertEqual(b.close.treatment, .hidden)
        XCTAssertEqual(b.close.position, .topRight)
        XCTAssertEqual(b.close.progressBarColor, "#FFFFFF")
    }

    func testAdBehaviorHyphenNormalization() throws {
        // Hyphenated wire spellings normalize to the same tolerant enums as underscores.
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"treatment":"reward-or-close-label","position":"top-left"},
           "skoverlay":{"enabled":true,"timing":"during-play","position":"bottom-raised"}}}
        """
        let b = try XCTUnwrap(try decodeAdLoad(json).adBehavior)
        XCTAssertEqual(b.close.treatment, .rewardOrCloseLabel)
        XCTAssertEqual(b.close.position, .topLeft)
        XCTAssertEqual(b.skoverlay?.timing, .duringPlay)
        XCTAssertEqual(b.skoverlay?.position, .bottomRaised)
    }

    func testClosePositionExcludesBottomRight() throws {
        // v2 excludes bottom_right (and legacy bottom_corner) → snaps to the safe top_right default.
        for raw in ["bottom_right", "bottom_corner"] {
            let json = """
            {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
             "ad_behavior":{"close":{"treatment":"hidden","position":"\(raw)"}}}
            """
            XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(json).adBehavior).close.position, .topRight)
        }
    }

    func testClosePositionHonorsBottomLeftForAllTreatments() throws {
        // bottom_left is honored for every treatment (no snap). progress_bar still renders its bar at
        // the top edge, but its resolved close position follows the config.
        for treatment in ["hidden", "reward_or_close_label", "countdown_circle", "progress_bar"] {
            let json = """
            {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
             "ad_behavior":{"close":{"treatment":"\(treatment)","position":"bottom_left"}}}
            """
            XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(json).adBehavior).close.position, .bottomLeft)
        }
    }

    func testCloseTreatmentUnknownFallsBackToHidden() throws {
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"treatment":"sparkles","position":"galaxy"}}}
        """
        let b = try XCTUnwrap(try decodeAdLoad(json).adBehavior)
        XCTAssertEqual(b.close.treatment, .hidden)
        XCTAssertEqual(b.close.position, .topRight)
    }

    func testProgressBarColorValidation() {
        // Valid 6-digit hex (with/without #) is accepted and normalized to upper-case with a #.
        XCTAssertEqual(validatedHexColor("#3b82f6"), "#3B82F6")
        XCTAssertEqual(validatedHexColor("00FF00"), "#00FF00")
        // Malformed → white fallback.
        XCTAssertEqual(validatedHexColor("#FFF"), "#FFFFFF")        // too short
        XCTAssertEqual(validatedHexColor("#GGGGGG"), "#FFFFFF")     // non-hex
        XCTAssertEqual(validatedHexColor("rgba(0,0,0,1)"), "#FFFFFF")
        XCTAssertEqual(validatedHexColor(nil), "#FFFFFF")
    }

    func testProgressBarColorDecodesAndFallsBack() throws {
        let good = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"progress_bar_color":"#abcdef"}}}
        """
        XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(good).adBehavior).close.progressBarColor, "#ABCDEF")

        let bad = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"progress_bar_color":"not-a-color"}}}
        """
        XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(bad).adBehavior).close.progressBarColor, "#FFFFFF")
    }

    func testStorePromptVerbatimPositionAndPlatform() throws {
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"store_prompt":{"enabled":true,"position":"bottom_left","platform":"android"}}}
        """
        let prompt = try XCTUnwrap(try XCTUnwrap(try decodeAdLoad(json).adBehavior).storePrompt)
        XCTAssertTrue(prompt.enabled)
        XCTAssertEqual(prompt.position, .bottomLeft)   // rendered verbatim — never recomputed
        XCTAssertEqual(prompt.platform, .android)
        XCTAssertEqual(prompt.trigger, "midpoint")
    }

    func testSKOverlayDefaultsAndValues() throws {
        // Empty skoverlay object → defaults (disabled, on_click, bottom, dismissible).
        let empty = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"skoverlay":{}}}
        """
        let d = try XCTUnwrap(try XCTUnwrap(try decodeAdLoad(empty).adBehavior).skoverlay)
        XCTAssertFalse(d.enabled)
        XCTAssertEqual(d.timing, .onClick)
        XCTAssertEqual(d.position, .bottom)
        XCTAssertTrue(d.dismissible)

        // Explicit values, including a clamped negative delay.
        let full = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"skoverlay":{"enabled":true,"timing":"delayed","delay_seconds":-3,
           "position":"bottom_raised","dismissible":false}}}
        """
        let o = try XCTUnwrap(try XCTUnwrap(try decodeAdLoad(full).adBehavior).skoverlay)
        XCTAssertTrue(o.enabled)
        XCTAssertEqual(o.timing, .delayed)
        XCTAssertEqual(o.delaySeconds, 0)             // negative clamps to 0
        XCTAssertEqual(o.position, .bottomRaised)
        XCTAssertFalse(o.dismissible)
    }

    func testAdUnitTypeFallsBackToLegacyFlags() throws {
        // No creative node: adUnitType derives from the legacy `rendered_format` (the imperative
        // HTML model dropped the flat `rewarded` flag, so a stray `rewarded` key is ignored).
        let renderedFormat = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rendered_format":"rewarded_video"}"#
        XCTAssertEqual(try decodeAdLoad(renderedFormat).adUnitType, .rewarded)

        let plain = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":true}"#
        XCTAssertEqual(try decodeAdLoad(plain).adUnitType, .interstitial)
    }

    func testAdBehaviorResilientToUnknownEnums() throws {
        // Unknown enum strings fall back per-field; delay_seconds is still parsed.
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"delay_seconds":12,"treatment":"spinner","position":"middle",
           "progress_bar_color":"warp"},"store_open":"warp"}}
        """
        let b = try XCTUnwrap(try decodeAdLoad(json).adBehavior)
        XCTAssertEqual(b.close.delaySeconds, 12)
        XCTAssertEqual(b.close.treatment, .hidden)
        XCTAssertEqual(b.close.position, .topRight)
        XCTAssertEqual(b.close.progressBarColor, "#FFFFFF")
        XCTAssertEqual(b.storeOpen, .external)
    }

    func testAdBehaviorNegativeDelayClampsToZero() throws {
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"delay_seconds":-5}}}
        """
        XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(json).adBehavior).close.delaySeconds, 0)
    }

    func testAdBehaviorOversizedDelayClampsToMax() throws {
        // A bad/oversized delay must clamp so it can't trap the user behind a blocked close.
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"delay_seconds":600}}}
        """
        XCTAssertEqual(
            try XCTUnwrap(try decodeAdLoad(json).adBehavior).close.delaySeconds,
            maxCloseDelaySeconds
        )
    }

    func testDeviceCapabilitiesEncodesHandshakeKeys() throws {
        // The capability handshake must serialize the snake_case keys the backend expects.
        let data = try JSONEncoder().encode(DeviceCapabilities.current)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(obj["os_version"])
        XCTAssertNotNil(obj["storekit_available"])
        XCTAssertNotNil(obj["skan_version"])
        XCTAssertNotNil(obj["adattributionkit_available"])
    }

    // MARK: - Interstitial configuration defaults / mutability

    @MainActor
    func testInterstitialDefaultConfiguration() {
        let ad = SimulaInterstitialAd(adUnitId: "u")
        XCTAssertEqual(ad.adUnitId, "u")
    }

    // MARK: - Global character context (SimulaAds)

    @MainActor
    func testSimulaAdsSetCharacterUpdatesGlobalContext() {
        SimulaAds.setCharacter(
            charId: "char_7",
            charName: "Mentor",
            charImage: "https://x/a.png",
            charDesc: "a wise mentor"
        )
        XCTAssertEqual(SimulaAds.charId, "char_7")
        XCTAssertEqual(SimulaAds.charName, "Mentor")
        XCTAssertEqual(SimulaAds.charImage, "https://x/a.png")
        XCTAssertEqual(SimulaAds.charDesc, "a wise mentor")

        // Direct property assignment updates a single field on the fly.
        SimulaAds.charName = "Sage"
        XCTAssertEqual(SimulaAds.charName, "Sage")

        // setCharacter replaces wholesale: omitted fields are cleared (no stale carry-over).
        SimulaAds.setCharacter(charId: "char_8")
        XCTAssertEqual(SimulaAds.charId, "char_8")
        XCTAssertNil(SimulaAds.charName)
        XCTAssertNil(SimulaAds.charImage)
        XCTAssertNil(SimulaAds.charDesc)

        // Reset global state so other tests aren't affected.
        SimulaAds.setCharacter()
    }

    // MARK: - Rewarded init parsing (RewardedInitResponse decode)

    private func decodeRewardedInit(_ json: String) throws -> RewardedInitResponse {
        try JSONDecoder().decode(RewardedInitResponse.self, from: data(json))
    }

    func testRewardedInitHappyPath() throws {
        let json = #"{"serve_id":"srv_1","iframe_url":"https://x/play","ad_id":"ad_9","duration_seconds":30}"#
        let r = try decodeRewardedInit(json)
        XCTAssertEqual(r.serveId, "srv_1")
        XCTAssertEqual(r.iframeUrl, "https://x/play")
        XCTAssertEqual(r.adId, "ad_9")
        XCTAssertEqual(r.durationSeconds, 30)
    }

    func testRewardedInitMissingFieldsFallBackToDefaults() throws {
        // Tolerant decode: a partial payload must not fail the whole decode.
        let r = try decodeRewardedInit(#"{"serve_id":"srv_2","iframe_url":"https://x/p"}"#)
        XCTAssertEqual(r.serveId, "srv_2")
        XCTAssertEqual(r.adId, "")           // missing → ""
        XCTAssertEqual(r.durationSeconds, 0) // missing → 0
    }

    func testRewardedInitMalformedJSONThrows() {
        XCTAssertThrowsError(try decodeRewardedInit("not json"))
    }

    // MARK: - Verify reward parsing (VerifyRewardResponse decode)

    func testVerifyRewardResponseDecodes() throws {
        let r = try JSONDecoder().decode(VerifyRewardResponse.self, from: data(#"{"verified":true,"token":"tok_1"}"#))
        XCTAssertTrue(r.verified)
        XCTAssertEqual(r.token, "tok_1")
    }

    func testVerifyRewardResponseMissingTokenIsNil() throws {
        let r = try JSONDecoder().decode(VerifyRewardResponse.self, from: data(#"{"verified":true}"#))
        XCTAssertTrue(r.verified)
        XCTAssertNil(r.token)
    }

    // MARK: - Rewarded request encoding (snake_case)

    func testRewardedInitRequestEncodesSnakeCaseKeys() throws {
        let body = RewardedInitRequest(adUnitId: "unit_1", sessionId: "sess_9", minPlayThreshold: 15)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(obj?["ad_unit_id"] as? String, "unit_1")
        XCTAssertEqual(obj?["session_id"] as? String, "sess_9")
        XCTAssertEqual(obj?["min_play_threshold"] as? Int, 15)
    }

    func testRewardedInitRequestOmitsThresholdWhenNil() throws {
        let body = RewardedInitRequest(adUnitId: "unit_1", sessionId: "s")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertNil(obj?["min_play_threshold"], "nil threshold must be omitted, not sent as null")
    }

    func testVerifyRewardRequestEncodesSnakeCaseKeys() throws {
        let body = VerifyRewardRequest(serveId: "srv_1", sessionId: "sess_9", elapsedPlayTime: 31.5)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(obj?["serve_id"] as? String, "srv_1")
        XCTAssertEqual(obj?["session_id"] as? String, "sess_9")
        XCTAssertEqual(obj?["elapsed_play_time"] as? Double, 31.5)
    }

    // MARK: - Idempotent verify response

    func testVerifyRewardResponse409IdempotentShape() {
        // The API layer maps HTTP 409 (already claimed) to a verified response with a
        // nil token; assert that shape directly (no network).
        let r = VerifyRewardResponse(verified: true, token: nil)
        XCTAssertTrue(r.verified)
        XCTAssertNil(r.token)
    }

    // MARK: - Rewarded configuration + state guards

    @MainActor
    func testRewardedDefaultConfiguration() {
        let ad = SimulaRewardedAd(adUnitId: "u")
        XCTAssertEqual(ad.adUnitId, "u")
        XCTAssertEqual(ad.minPlayThreshold, 0)
    }

    @MainActor
    func testRewardedLoadBeforeInitFiresLoadFailedNotInitialized() {
        XCTAssertFalse(SimulaAds.isInitialized, "Test assumes SimulaAds is not initialized")
        let delegate = RewardedMockDelegate()
        let ad = SimulaRewardedAd(adUnitId: "u")
        ad.delegate = delegate
        ad.load()
        guard case .notInitialized? = delegate.loadFailedError else {
            return XCTFail("Expected .notInitialized, got \(String(describing: delegate.loadFailedError))")
        }
    }

    @MainActor
    func testRewardedShowBeforeLoadFiresDisplayFailedNotReady() {
        let delegate = RewardedMockDelegate()
        let ad = SimulaRewardedAd(adUnitId: "u")
        ad.delegate = delegate
        ad.show()
        guard case .notReady? = delegate.displayFailedError else {
            return XCTFail("Expected .notReady, got \(String(describing: delegate.displayFailedError))")
        }
    }
}

// MARK: - Test doubles

/// Captures the most recent failure events from a `SimulaInterstitialAd`.
final class InterstitialMockDelegate: SimulaInterstitialAdDelegate {
    var loadFailedError: SimulaAdError?
    var displayFailedError: SimulaAdError?

    func interstitialDidFailToLoad(_ ad: SimulaInterstitialAd, error: SimulaAdError) {
        loadFailedError = error
    }

    func interstitialDidFailToDisplay(_ ad: SimulaInterstitialAd, error: SimulaAdError) {
        displayFailedError = error
    }
}

/// Captures the most recent failure events from a `SimulaRewardedAd`.
final class RewardedMockDelegate: SimulaRewardedAdDelegate {
    var loadFailedError: SimulaAdError?
    var displayFailedError: SimulaAdError?

    func rewardedDidFailToLoad(_ ad: SimulaRewardedAd, error: SimulaAdError) {
        loadFailedError = error
    }

    func rewardedDidFailToDisplay(_ ad: SimulaRewardedAd, error: SimulaAdError) {
        displayFailedError = error
    }
}
