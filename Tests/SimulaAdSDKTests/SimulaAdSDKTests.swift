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
        // Verify that the MiniGameInviteKit namespace correctly aliases types.
        // The interstitial is no longer part of the namespace — it is the
        // imperative `SimulaInterstitialAd` (see interstitial tests below).
        XCTAssertTrue(MiniGameInviteKit.Invitation.self == MiniGameInvitation.self)
        XCTAssertTrue(MiniGameInviteKit.Button.self == MiniGameButton.self)
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
        let ad = SimulaInterstitialAd(adUnitId: "unit_42", minPlayThreshold: 5)
        XCTAssertEqual(ad.adUnitId, "unit_42")
        XCTAssertEqual(ad.minPlayThreshold, 5)
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
         "rendered_assets":["https://x/a.png","https://x/b.png"],
         "tracking_url":"https://x/click"}
        """
        let r = try decodeAdLoad(json)
        XCTAssertEqual(r.adId, "ad_1")
        XCTAssertTrue(r.adInserted)
        XCTAssertEqual(r.adUnitId, "unit_1")
        XCTAssertTrue(r.rewarded)
        XCTAssertEqual(r.destination, "web")
        XCTAssertEqual(r.destinationKind, .web)
        XCTAssertEqual(r.renderedFormat, "rewarded_video")
        XCTAssertEqual(r.renderedAssets, ["https://x/a.png", "https://x/b.png"])
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

    func testAdLoadMissingRenderedAssetsIsEmpty() throws {
        let json = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertEqual(r.renderedAssets, [])
    }

    func testAdLoadAdInsertedFalseDecodes() throws {
        let json = #"{"ad_id":"a","ad_inserted":false,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertFalse(r.adInserted)
    }

    func testAdLoadMalformedJSONThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(AdLoadResponse.self, from: Data("not json".utf8)))
    }

    // MARK: - No-fill: blank/whitespace-only rendered assets

    /// The no-fill guard filters blank/whitespace asset URLs before the emptiness
    /// check (M2). A payload whose only assets are "" / " " must be treated as
    /// no-fill, not rendered as a black "ad" that fires a junk impression.
    private func nonBlankAssets(_ assets: [String]) -> [String] {
        assets.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func testAdLoadBlankOnlyAssetsAreNoFill() throws {
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "rendered_assets":["", "   ", "\\t"]}
        """
        let r = try decodeAdLoad(json)
        // Decoder keeps the raw strings...
        XCTAssertEqual(r.renderedAssets.count, 3)
        // ...but after filtering there is nothing renderable → no-fill.
        XCTAssertTrue(nonBlankAssets(r.renderedAssets).isEmpty,
                      "Blank/whitespace-only assets must filter to empty (no-fill)")
    }

    func testAdLoadMixedBlankAndValidAssetsKeepsValid() throws {
        let json = """
        {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "rendered_assets":["", "https://x/a.png", "  ", "https://x/b.png"]}
        """
        let r = try decodeAdLoad(json)
        let kept = nonBlankAssets(r.renderedAssets)
        XCTAssertEqual(kept, ["https://x/a.png", "https://x/b.png"])
    }

    func testWithRenderedAssetsReplacesOnlyAssets() {
        let original = AdLoadResponse(
            adId: "ad_1", adInserted: true, adUnitId: "u", rewarded: true,
            destination: "web", renderedFormat: "rewarded_video",
            renderedAssets: ["", " ", "https://x/a.png"], trackingUrl: "https://x/click"
        )
        let sanitized = original.withRenderedAssets(nonBlankAssets(original.renderedAssets))
        XCTAssertEqual(sanitized.renderedAssets, ["https://x/a.png"])
        // Every other field is carried over unchanged.
        XCTAssertEqual(sanitized.adId, "ad_1")
        XCTAssertTrue(sanitized.adInserted)
        XCTAssertEqual(sanitized.adUnitId, "u")
        XCTAssertTrue(sanitized.rewarded)
        XCTAssertEqual(sanitized.destination, "web")
        XCTAssertEqual(sanitized.renderedFormat, "rewarded_video")
        XCTAssertEqual(sanitized.trackingUrl, "https://x/click")
    }

    // MARK: - Ad load request (AdLoadRequest encode)

    func testAdLoadRequestEncodesSnakeCaseKeys() throws {
        let body = AdLoadRequest(adUnitId: "unit_1", rewarded: true, sessionId: "sess_9")
        let encoded = try JSONEncoder().encode(body)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(obj?["ad_unit_id"] as? String, "unit_1")
        XCTAssertEqual(obj?["session_id"] as? String, "sess_9")
        XCTAssertEqual(obj?["rewarded"] as? Bool, true)
    }

    func testAdLoadRequestDefaults() {
        let body = AdLoadRequest(adUnitId: "unit_1")
        XCTAssertFalse(body.rewarded)
        XCTAssertEqual(body.sessionId, "")
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

    func testClosePositionSnapsForEdgeAnchoredTreatments() throws {
        // countdown_circle / progress_bar can't render bottom_left → snap to top_right.
        for treatment in ["countdown_circle", "progress_bar"] {
            let json = """
            {"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
             "ad_behavior":{"close":{"treatment":"\(treatment)","position":"bottom_left"}}}
            """
            XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(json).adBehavior).close.position, .topRight)
        }
        // hidden / reward_or_close_label keep bottom_left.
        for treatment in ["hidden", "reward_or_close_label"] {
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
        // No creative node: adUnitType derives from the legacy rewarded flag / rendered_format.
        let rewardedFlag = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":true}"#
        XCTAssertEqual(try decodeAdLoad(rewardedFlag).adUnitType, .rewarded)

        let renderedFormat = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"rendered_format":"rewarded_video"}"#
        XCTAssertEqual(try decodeAdLoad(renderedFormat).adUnitType, .rewarded)

        let plain = #"{"ad_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
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
        XCTAssertFalse(ad.rewarded)
        XCTAssertEqual(ad.minPlayThreshold, 0)
        XCTAssertEqual(ad.ctaText, "Learn More")
    }

    @MainActor
    func testInterstitialConfigurationIsMutable() {
        let ad = SimulaInterstitialAd(adUnitId: "u")
        ad.rewarded = true
        ad.minPlayThreshold = 7
        ad.ctaText = "Play Now"
        XCTAssertTrue(ad.rewarded)
        XCTAssertEqual(ad.minPlayThreshold, 7)
        XCTAssertEqual(ad.ctaText, "Play Now")
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
