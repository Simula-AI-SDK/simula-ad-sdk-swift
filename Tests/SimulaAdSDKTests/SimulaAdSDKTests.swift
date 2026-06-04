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
