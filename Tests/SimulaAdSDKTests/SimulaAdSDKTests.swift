import XCTest
import SwiftUI
#if os(iOS)
import CoreTelephony
#endif
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
        XCTAssertTrue(url.absoluteString.hasSuffix("/minigames/catalog?session_id=sess_9"),
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
        {"impression_id":"ad_1","ad_inserted":true,"ad_unit_id":"unit_1","rewarded":true,
         "destination":"web","rendered_format":"rewarded_video",
         "rendered_html":"<b>hi</b>",
         "tracking_url":"https://x/click"}
        """
        let r = try decodeAdLoad(json)
        XCTAssertEqual(r.impressionId, "ad_1")
        XCTAssertTrue(r.adInserted)
        XCTAssertEqual(r.adUnitId, "unit_1")
        XCTAssertEqual(r.destination, "web")
        XCTAssertEqual(r.destinationKind, .web)
        XCTAssertEqual(r.renderedFormat, "rewarded_video")
        XCTAssertEqual(r.renderedHtml, "<b>hi</b>")
        XCTAssertEqual(r.trackingUrl, "https://x/click")
    }

    func testAdLoadDestinationDefaultsToAppstoreWhenAbsent() throws {
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertEqual(r.destination, "appstore")
        XCTAssertEqual(r.destinationKind, .appstore)
    }

    func testAdLoadDestinationUnknownFallsBackToAppstore() throws {
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"destination":"carousel"}"#
        let r = try decodeAdLoad(json)
        // The raw string is preserved, but destinationKind maps unknown → .appstore.
        XCTAssertEqual(r.destination, "carousel")
        XCTAssertEqual(r.destinationKind, .appstore)
    }

    func testAdLoadMissingRenderedFormatIsNil() throws {
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertNil(r.renderedFormat)
    }

    func testAdLoadAdInsertedFalseDecodes() throws {
        let json = #"{"impression_id":"a","ad_inserted":false,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertFalse(r.adInserted)
    }

    func testAdLoadMalformedJSONThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(AdLoadResponse.self, from: Data("not json".utf8)))
    }

    // MARK: - Ad load: rendered_html (HTML creative precedence)

    func testAdLoadDecodesRenderedHtml() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "rendered_html":"<html><body>hi</body></html>"}
        """
        let r = try decodeAdLoad(json)
        XCTAssertEqual(r.renderedHtml, "<html><body>hi</body></html>")
        // Present & non-blank → htmlCreative is the renderable creative.
        XCTAssertEqual(r.htmlCreative, "<html><body>hi</body></html>")
    }

    func testAdLoadRenderedHtmlAbsentIsNil() throws {
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        XCTAssertNil(r.renderedHtml)
        XCTAssertNil(r.htmlCreative)
    }

    func testAdLoadRenderedHtmlBlankYieldsNilCreative() throws {
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"rendered_html":"   \n\t  "}"#
        let r = try decodeAdLoad(json)
        // The raw whitespace string is preserved by the decoder...
        XCTAssertFalse(r.renderedHtml?.isEmpty ?? true)
        // ...but htmlCreative trims it away → no renderable creative (no-fill).
        XCTAssertNil(r.htmlCreative)
    }

    /// A payload with a non-blank `rendered_html` is fillable (mirrors the `load()`
    /// no-fill rule: fill = adInserted && htmlCreative != nil).
    func testAdLoadHtmlOnlyPayloadIsFillable() throws {
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"rendered_html":"<b>x</b>"}"#
        let r = try decodeAdLoad(json)
        XCTAssertNotNil(r.htmlCreative)
        XCTAssertTrue(r.adInserted && r.htmlCreative != nil)
    }

    /// No `rendered_html` (even with `ad_inserted == true`) is a no-fill: there is
    /// no other creative to render now that the carousel/asset path is gone.
    func testAdLoadNoHtmlIsNoFill() throws {
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
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
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false}"#
        let r = try decodeAdLoad(json)
        // Absent ad_behavior → nil so the renderer falls back to today's literal behavior.
        XCTAssertNil(r.adBehavior)
        XCTAssertNil(r.creative)
        XCTAssertNil(r.experiment)
    }

    func testAdBehaviorHappyPath() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
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
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"ad_behavior":{}}"#
        let b = try XCTUnwrap(try decodeAdLoad(json).adBehavior)
        XCTAssertEqual(b.close.delaySeconds, 0)
        XCTAssertEqual(b.close.treatment, .hidden)
        XCTAssertEqual(b.close.position, .topRight)
        XCTAssertEqual(b.close.progressBarColor, "#FFFFFF")
        XCTAssertNil(b.storePrompt)
        XCTAssertNil(b.skoverlay)
        XCTAssertNil(b.autoStoreRedirect)
    }

    // MARK: - Ad behavior: auto_store_redirect

    func testAutoStoreRedirectAbsentIsNil() throws {
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"ad_behavior":{}}"#
        XCTAssertNil(try XCTUnwrap(try decodeAdLoad(json).adBehavior).autoStoreRedirect)
    }

    func testAutoStoreRedirectFullConfigDecodes() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"auto_store_redirect":{"enabled":true,"trigger":"end_screen_1_open"}}}
        """
        let r = try XCTUnwrap(try decodeAdLoad(json).adBehavior?.autoStoreRedirect)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.trigger, .endScreen1Open)
    }

    func testAutoStoreRedirectEmptyObjectDefaults() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"auto_store_redirect":{}}}
        """
        let r = try XCTUnwrap(try decodeAdLoad(json).adBehavior?.autoStoreRedirect)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.trigger, .playableEnd)
    }

    func testAutoStoreRedirectUnknownTriggerFallsBack() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"auto_store_redirect":{"enabled":true,"trigger":"warp_drive"}}}
        """
        let r = try XCTUnwrap(try decodeAdLoad(json).adBehavior?.autoStoreRedirect)
        XCTAssertEqual(r.trigger, .playableEnd)
    }

    func testEndScreenFallbackIndexMapping() {
        // END_SCREEN_1/2_OPEN fire when the matching post-close fallback ad screen is presented:
        // index 0 = END SCREEN 1, index 1 = END SCREEN 2 (no signal from the webview).
        XCTAssertEqual(AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: 0), .endScreen1Open)
        XCTAssertEqual(AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: 1), .endScreen2Open)
        // No end-screen trigger for further indices (PLAYABLE_END is native, has no fallback index).
        XCTAssertNil(AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: 2))
        XCTAssertNil(AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: -1))
    }

    // MARK: - User-Agent (PRD)

    func testUserAgentComposeMatchesPRDFormat() {
        let ua = SimulaUserAgent.compose(
            sdkVersion: "1.2.3",
            osVersion: "17.2",
            locale: "en_US",
            deviceModel: "iPhone16,1",
            buildId: "21C52",
            bundleId: "com.publisher.app"
        )
        XCTAssertEqual(
            ua,
            "Simula-SDK/1.2.3 (iOS 17.2; en_US; iPhone16,1; Build/21C52; com.publisher.app)"
        )
    }

    /// The CTA / redirect-resolver session (Adjust attribution PRD) must present as a genuine
    /// mobile Safari/WebView navigation: a WebKit UA, not the custom `Simula-SDK/...` UA, and no
    /// `X-Device-Id` (only `standardHeaders()` — used by the API/telemetry sessions — carries it).
    func testCTASessionConfigurationUsesSafariUAAndOmitsDeviceId() {
        let config = SimulaUserAgent.sessionConfiguration()
        let headers = config.httpAdditionalHeaders as? [String: String] ?? [:]

        XCTAssertEqual(headers["User-Agent"], SimulaUserAgent.safariUserAgent)
        XCTAssertNil(headers["X-Device-Id"])
        XCTAssertFalse(SimulaUserAgent.safariUserAgent.contains("Simula-SDK"))
    }

    func testSafariUserAgentFormat() {
        let ua = SimulaUserAgent.safariUserAgent
        XCTAssertTrue(ua.hasPrefix("Mozilla/5.0 (iPhone; CPU iPhone OS "))
        XCTAssertTrue(ua.contains("like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"))
    }

    /// The custom-UA path (`standardHeaders()`, used by `SimulaAPI` and asset loads) must be
    /// unaffected by the Safari-UA change: it still carries the SDK UA and `X-Device-Id` (when the
    /// platform supplies one).
    func testStandardHeadersUnaffectedBySafariUAChange() {
        let headers = SimulaUserAgent.standardHeaders()
        XCTAssertEqual(headers["User-Agent"], SimulaUserAgent.value)
        XCTAssertTrue(SimulaUserAgent.value.hasPrefix("Simula-SDK/"))
    }

    // MARK: - X-Connection-Type (OpenRTB device.connectiontype)

    func testConnectionTypeClassifyOfflineIsUnknownZero() {
        let (value, label) = SimulaConnectionType.classify(
            satisfied: false, isWifi: false, isWiredEthernet: false, isCellular: false, cellularGeneration: 99
        )
        XCTAssertEqual(value, 0)
        XCTAssertEqual(label, "none")
    }

    func testConnectionTypeClassifyWifi() {
        let (value, label) = SimulaConnectionType.classify(
            satisfied: true, isWifi: true, isWiredEthernet: false, isCellular: false, cellularGeneration: 99
        )
        XCTAssertEqual(value, 2)
        XCTAssertEqual(label, "wifi")
    }

    func testConnectionTypeClassifyWiredEthernetIsDistinctValueSameLabelAsWifi() {
        let (value, label) = SimulaConnectionType.classify(
            satisfied: true, isWifi: false, isWiredEthernet: true, isCellular: false, cellularGeneration: 99
        )
        XCTAssertEqual(value, 1) // OpenRTB "wired", distinct from wifi's 2
        XCTAssertEqual(label, "wifi") // telemetry label continuity with the pre-existing monitor
    }

    func testConnectionTypeClassifyCellularUsesSuppliedGeneration() {
        let (value, label) = SimulaConnectionType.classify(
            satisfied: true, isWifi: false, isWiredEthernet: false, isCellular: true, cellularGeneration: 7
        )
        XCTAssertEqual(value, 7)
        XCTAssertEqual(label, "cellular")
    }

    func testConnectionTypeClassifyNoTransportIsUnknown() {
        let (value, label) = SimulaConnectionType.classify(
            satisfied: true, isWifi: false, isWiredEthernet: false, isCellular: false, cellularGeneration: 99
        )
        XCTAssertEqual(value, 0)
        XCTAssertEqual(label, "unknown")
    }

    #if os(iOS)
    func testConnectionTypeGenerationMapping() {
        XCTAssertEqual(SimulaConnectionType.generation(forRadioAccessTechnology: CTRadioAccessTechnologyLTE), 6)
        XCTAssertEqual(SimulaConnectionType.generation(forRadioAccessTechnology: CTRadioAccessTechnologyWCDMA), 5)
        XCTAssertEqual(SimulaConnectionType.generation(forRadioAccessTechnology: CTRadioAccessTechnologyEdge), 4)
        XCTAssertEqual(SimulaConnectionType.generation(forRadioAccessTechnology: "bogus-unknown-tech"), 3)
    }
    #endif

    /// `X-Connection-Type` must be read live per request (never cached at session init) so a
    /// mid-session network switch (Wi-Fi → cellular) shows up on the very next call — verified here
    /// by asserting the header always reflects whatever `SimulaConnectionType.shared.current` is at
    /// call time, not a value frozen at session/config creation.
    func testConnectionTypeHeaderReadLivePerRequest() {
        SimulaConnectionType.shared.start()
        // `current` is a live computed property (lock-guarded read), not a value captured once;
        // this documents/guards the contract makeHeaders() relies on.
        let first = SimulaConnectionType.shared.current
        let second = SimulaConnectionType.shared.current
        XCTAssertEqual(first, second) // stable when the network hasn't changed
        XCTAssertGreaterThanOrEqual(first, 0)
    }

    // MARK: - skan_attribution tokens (response-root sibling of ad_behavior; SKOverlay / SKStoreProduct)

    func testSkanAttributionDecodesCampaignProviderAndSkan() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "skan_attribution":{
           "campaign_token":"camp_tok","provider_token":"prov_tok",
           "skan":{"version":"4.0","ad_network_id":"net123.skadnetwork","source_app_store_id":987654321,
             "nonce":"00000000-0000-0000-0000-000000000001","timestamp":1700000000000,
             "attribution_signature":"sig==","source_id":1234}}}
        """
        let a = try XCTUnwrap(try decodeAdLoad(json).skanAttribution)
        XCTAssertEqual(a.campaignToken, "camp_tok")
        XCTAssertEqual(a.providerToken, "prov_tok")
        let skan = try XCTUnwrap(a.skan)
        XCTAssertEqual(skan.version, "4.0")
        XCTAssertEqual(skan.adNetworkIdentifier, "net123.skadnetwork")
        XCTAssertEqual(skan.sourceAppStoreIdentifier, 987_654_321)
        XCTAssertEqual(skan.nonce, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(skan.timestamp, 1_700_000_000_000)
        XCTAssertEqual(skan.attributionSignature, "sig==")
        XCTAssertEqual(skan.sourceIdentifier, 1234)
        XCTAssertNil(skan.campaignIdentifier)
    }

    func testSkanAttributionAbsentIsNil() throws {
        let json = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,"ad_behavior":{}}"#
        XCTAssertNil(try decodeAdLoad(json).skanAttribution)
    }

    func testSkanAttributionAllOrNothingDropsPartialButKeepsTokens() throws {
        // The SKAN block is missing `attribution_signature` (a required field) → StoreKit could not
        // build a valid postback, so the whole `skan` decodes to nil. The App Analytics tokens, which
        // are independent, still decode.
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "skan_attribution":{
           "campaign_token":"camp_tok",
           "skan":{"version":"4.0","ad_network_id":"net123.skadnetwork","source_app_store_id":987654321,
             "nonce":"00000000-0000-0000-0000-000000000001","timestamp":1700000000000,"source_id":1234}}}
        """
        let a = try XCTUnwrap(try decodeAdLoad(json).skanAttribution)
        XCTAssertEqual(a.campaignToken, "camp_tok")
        XCTAssertNil(a.providerToken)
        XCTAssertNil(a.skan)
    }

    func testAdBehaviorPartialCloseFillsDefaults() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
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
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
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
            {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
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
            {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
             "ad_behavior":{"close":{"treatment":"\(treatment)","position":"bottom_left"}}}
            """
            XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(json).adBehavior).close.position, .bottomLeft)
        }
    }

    func testCloseTreatmentUnknownFallsBackToHidden() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
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
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"progress_bar_color":"#abcdef"}}}
        """
        XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(good).adBehavior).close.progressBarColor, "#ABCDEF")

        let bad = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"progress_bar_color":"not-a-color"}}}
        """
        XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(bad).adBehavior).close.progressBarColor, "#FFFFFF")
    }

    func testStorePromptVerbatimPositionAndPlatform() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
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
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"skoverlay":{}}}
        """
        let d = try XCTUnwrap(try XCTUnwrap(try decodeAdLoad(empty).adBehavior).skoverlay)
        XCTAssertFalse(d.enabled)
        XCTAssertEqual(d.timing, .onClick)
        XCTAssertEqual(d.position, .bottom)
        XCTAssertTrue(d.dismissible)

        // Explicit values, including a clamped negative delay.
        let full = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
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
        let renderedFormat = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rendered_format":"rewarded_video"}"#
        XCTAssertEqual(try decodeAdLoad(renderedFormat).adUnitType, .rewarded)

        let plain = #"{"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":true}"#
        XCTAssertEqual(try decodeAdLoad(plain).adUnitType, .interstitial)
    }

    func testAdBehaviorResilientToUnknownEnums() throws {
        // Unknown enum strings fall back per-field; delay_seconds is still parsed.
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"delay_seconds":12,"treatment":"spinner","position":"middle",
           "progress_bar_color":"warp"},"store_open":"warp"}}
        """
        let b = try XCTUnwrap(try decodeAdLoad(json).adBehavior)
        XCTAssertEqual(b.close.delaySeconds, 12)
        XCTAssertEqual(b.close.treatment, .hidden)
        XCTAssertEqual(b.close.position, .topRight)
        XCTAssertEqual(b.close.progressBarColor, "#FFFFFF")
        // Unknown/missing store_open falls back to the in-app store sheet (documented default).
        XCTAssertEqual(b.storeOpen, .skstoreproduct)
    }

    func testAdBehaviorNegativeDelayClampsToZero() throws {
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
         "ad_behavior":{"close":{"delay_seconds":-5}}}
        """
        XCTAssertEqual(try XCTUnwrap(try decodeAdLoad(json).adBehavior).close.delaySeconds, 0)
    }

    func testAdBehaviorOversizedDelayClampsToMax() throws {
        // A bad/oversized delay must clamp so it can't trap the user behind a blocked close.
        let json = """
        {"impression_id":"a","ad_inserted":true,"ad_unit_id":"u","rewarded":false,
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

    // MARK: - Character context (per-load)

    @MainActor
    func testInterstitialLoadAcceptsPerCallCharacterContext() {
        // Character context now flows through `load(...)` instead of global SimulaAds
        // state. Without `initialize` it fails fast with .notInitialized, but the call
        // must still accept the per-call character arguments (compile + runtime).
        XCTAssertFalse(SimulaAds.isInitialized, "Test assumes SimulaAds is not initialized")

        let delegate = InterstitialMockDelegate()
        let ad = SimulaInterstitialAd(adUnitId: "test_unit")
        ad.delegate = delegate

        ad.load(
            charId: "char_7",
            charName: "Mentor",
            charImage: "https://x/a.png",
            charDesc: "a wise mentor"
        )

        guard case .notInitialized? = delegate.loadFailedError else {
            return XCTFail("Expected .notInitialized, got \(String(describing: delegate.loadFailedError))")
        }
    }

    @MainActor
    func testStaleAndDuplicateRequestErrorMessages() {
        // These messages are part of the public contract, shared with Kotlin — verbatim
        // except the "loading" copy names this platform's load callback (the `didLoad`
        // delegate callback, vs Kotlin's `onAdLoaded`).
        XCTAssertEqual(
            SimulaAdError.stale.errorDescription,
            "The loaded ad has expired (1 hour limit) and can no longer be shown. "
                + "Call load() to request a new ad."
        )
        XCTAssertEqual(
            SimulaAdError.duplicateRequest(retryInSeconds: 42).errorDescription,
            "An ad for this placement is already loaded. Call show() to display it, "
                + "or load() again in 42 seconds."
        )
        XCTAssertEqual(
            SimulaAdError.duplicateRequest(retryInSeconds: nil).errorDescription,
            "An ad for this placement is already loading. "
                + "Wait for the didLoad delegate callback before calling load() again."
        )
    }

    @MainActor
    func testAlignedErrorMessagesMatchAndroid() {
        // These strings are kept verbatim-aligned with the Kotlin SDK's SimulaAdError so the two
        // platforms surface identical diagnostics (platform-specific API names aside).
        XCTAssertEqual(
            SimulaAdError.notInitialized.errorDescription,
            "SimulaAds is not initialized — call SimulaAds.initialize() first."
        )
        XCTAssertEqual(
            SimulaAdError.noSession.errorDescription,
            "Could not create a session. Check the API key and network connection."
        )
        XCTAssertEqual(
            SimulaAdError.noFill.errorDescription,
            "No ad available to show right now (no fill)."
        )
        XCTAssertEqual(
            SimulaAdError.notReady.errorDescription,
            "Ad not ready — call load() first and wait for the loaded callback before show()."
        )
        XCTAssertEqual(
            SimulaAdError.alreadyShowing.errorDescription,
            "An interstitial is already showing."
        )
        XCTAssertEqual(
            SimulaAdError.network(.invalidResponse).errorDescription,
            "Network error while loading the ad — check the connection and call load() again."
        )
        XCTAssertEqual(
            SimulaAdError.adUnitNotFound.errorDescription,
            "Ad unit id is not registered for this app — check the ad unit id in your Simula dashboard."
        )
    }

    func testAdUnitNotFoundTelemetryCode() {
        XCTAssertEqual(SimulaAdError.adUnitNotFound.telemetryCode, "ad_unit_not_found")
    }

    func testAPIErrorBodyDecodesAdUnitNotFoundCode() throws {
        let json = #"{"code":"ad_unit_not_found","message":"Ad unit 'x' is not registered for this publisher."}"#
        let body = try JSONDecoder().decode(SimulaAPIErrorBody.self, from: Data(json.utf8))
        XCTAssertEqual(body.code, "ad_unit_not_found")
    }

    // MARK: - Rewarded init parsing (RewardedInitResponse decode)

    private func decodeRewardedInit(_ json: String) throws -> RewardedInitResponse {
        try JSONDecoder().decode(RewardedInitResponse.self, from: data(json))
    }

    func testRewardedInitHappyPath() throws {
        let json = #"{"impression_id":"imp_1","iframe_url":"https://x/play","ad_behavior":{"close":{"delay_seconds":30}}}"#
        let r = try decodeRewardedInit(json)
        XCTAssertEqual(r.impressionId, "imp_1")
        XCTAssertEqual(r.iframeUrl, "https://x/play")
        // The play-to-earn gate now rides on `ad_behavior.close.delay_seconds` (no top-level field).
        XCTAssertEqual(r.adBehavior?.close.delaySeconds, 30)
    }

    func testRewardedInitMissingFieldsFallBackToDefaults() throws {
        // Tolerant decode: a partial payload must not fail the whole decode. Legacy
        // `serve_id`/`ad_id` keys are unknown now and must be ignored, not remapped.
        let r = try decodeRewardedInit(#"{"iframe_url":"https://x/p","serve_id":"srv_2","ad_id":"a"}"#)
        XCTAssertEqual(r.impressionId, "")   // missing → ""
        XCTAssertNil(r.adBehavior)           // absent `ad_behavior` → nil → no gate, no store prompt
    }

    func testRewardedInitMalformedJSONThrows() {
        XCTAssertThrowsError(try decodeRewardedInit("not json"))
    }

    // MARK: - Fallback ads parsing (GET /load/fallbacks/{impression_id})

    func testFallbacksResponseDecodesScreensInOrder() throws {
        let json = """
        {"impression_id":"imp_1","ads":[
          {"ad_id":"a1","html":"<html>1</html>","iframe_url":"https://i/1"},
          {"ad_id":"a2","html":"<html>2</html>","iframe_url":"https://i/2"}
        ]}
        """
        let r = try JSONDecoder().decode(FallbackAdsAPIResponse.self, from: data(json))
        XCTAssertEqual(r.impressionId, "imp_1")
        XCTAssertEqual(r.ads.count, 2)
        XCTAssertEqual(r.ads[0].adId, "a1")
        XCTAssertEqual(r.ads[0].iframeUrl, "https://i/1")
        // html is the preferred creative source rendered by AdOverlayView.
        XCTAssertEqual(r.ads[0].html, "<html>1</html>")
        XCTAssertEqual(r.ads[1].adId, "a2")
    }

    func testFallbacksResponseToleratesEmptyAndPartialPayloads() throws {
        let empty = try JSONDecoder().decode(FallbackAdsAPIResponse.self, from: data(#"{"impression_id":"i","ads":[]}"#))
        XCTAssertTrue(empty.ads.isEmpty)

        let bare = try JSONDecoder().decode(FallbackAdsAPIResponse.self, from: data("{}"))
        XCTAssertNil(bare.impressionId)
        XCTAssertTrue(bare.ads.isEmpty)

        let partial = try JSONDecoder().decode(FallbackAdsAPIResponse.self, from: data(#"{"ads":[{"ad_id":"a1"}]}"#))
        XCTAssertEqual(partial.ads[0].adId, "a1")
        XCTAssertNil(partial.ads[0].iframeUrl)
        XCTAssertNil(partial.ads[0].html)
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
        let body = RewardedInitRequest(adUnitId: "unit_1", sessionId: "sess_9")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(obj?["ad_unit_id"] as? String, "unit_1")
        XCTAssertEqual(obj?["session_id"] as? String, "sess_9")
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
