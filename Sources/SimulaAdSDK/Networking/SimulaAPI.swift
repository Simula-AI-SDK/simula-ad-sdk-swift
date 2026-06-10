import Foundation

// MARK: - API Constants

/// Base URL for all Simula API endpoints (from api.ts)
private let API_BASE_URL = "https://simula-api-701226639755.us-central1.run.app"

// MARK: - API Error

public enum SimulaAPIError: LocalizedError, Sendable {
    case invalidURL
    case httpError(statusCode: Int)
    case invalidApiKey
    case noFill
    case invalidResponse
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .invalidApiKey:
            return "Invalid API key (please check dashboard or contact Simula team for a valid API key)"
        case .noFill:
            return "No fill"
        case .invalidResponse:
            return "Invalid ad response"
        case .decodingError(let message):
            return "Decoding error: \(message)"
        }
    }
}

// MARK: - API Response Models

/// Response from POST /session/create
struct CreateSessionResponse: Decodable {
    let sessionId: String?
    // Optional server-side telemetry directive: a runtime kill-switch + perf sampling rate,
    // letting telemetry volume be dialed without an SDK release. Absent → SDK defaults apply.
    let telemetryEnabled: Bool?
    let telemetrySampleRate: Double?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case telemetryEnabled = "telemetry_enabled"
        case telemetrySampleRate = "telemetry_sample_rate"
    }
}

/// Device capability snapshot reported on ad requests (the "capability handshake"). The backend
/// uses it to withhold variants the OS can't support — e.g. SKOverlay requires iOS 14+,
/// AdAttributionKit requires iOS 17.4+. Computed once per process (`current`) since it never
/// changes during a run; recomputing per request would be wasted work on the ad path.
public struct DeviceCapabilities: Encodable, Sendable {
    public let osVersion: String
    public let storekitAvailable: Bool
    public let skanVersion: String
    public let adAttributionKitAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case osVersion = "os_version"
        case storekitAvailable = "storekit_available"
        case skanVersion = "skan_version"
        case adAttributionKitAvailable = "adattributionkit_available"
    }

    public init(osVersion: String, storekitAvailable: Bool, skanVersion: String, adAttributionKitAvailable: Bool) {
        self.osVersion = osVersion
        self.storekitAvailable = storekitAvailable
        self.skanVersion = skanVersion
        self.adAttributionKitAvailable = adAttributionKitAvailable
    }

    /// The running device's capabilities, evaluated once. `storekit_available` mirrors SKOverlay
    /// availability (iOS 14+); `skan_version` reports the max SKAdNetwork version the SDK supports.
    public static let current: DeviceCapabilities = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        var storekitAvailable = false
        var skanVersion = "0"
        var adAttributionKitAvailable = false
        if #available(iOS 14.0, *) {
            storekitAvailable = true
            skanVersion = "4.0"
        }
        if #available(iOS 17.4, *) {
            adAttributionKitAvailable = true
        }
        return DeviceCapabilities(
            osVersion: osVersion,
            storekitAvailable: storekitAvailable,
            skanVersion: skanVersion,
            adAttributionKitAvailable: adAttributionKitAvailable
        )
    }()

    /// JSON-object form for the dictionary-built `/session/create` body (which also carries the
    /// consent block). Keys match `CodingKeys` so the wire shape is identical to `Encodable` output.
    var dictionary: [String: Any] {
        [
            "os_version": osVersion,
            "storekit_available": storekitAvailable,
            "skan_version": skanVersion,
            "adattributionkit_available": adAttributionKitAvailable,
        ]
    }
}

/// Wraps a decode so failure yields `nil` instead of throwing. Because its own
/// `init` never throws, decoding it from an unkeyed container always advances
/// the container — the basis for lossy array decoding below.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        self.value = try? T(from: decoder)
    }
}

/// Decodes a games array element-by-element, skipping any entry that fails to
/// decode so a single malformed game can't drop the entire catalog.
struct LossyCatalogItems: Decodable {
    let items: [CatalogGameItem]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [CatalogGameItem] = []
        while !container.isAtEnd {
            let wrapped = try container.decode(FailableDecodable<CatalogGameItem>.self)
            if let item = wrapped.value { items.append(item) }
        }
        self.items = items
    }
}

/// A single game as returned by the catalog endpoint. `id`/`name` are required
/// (a game missing either is dropped by `LossyCatalogItems`); everything else is
/// optional. The cover may arrive as either `gif_cover` or `gifCover`.
struct CatalogGameItem: Decodable {
    let id: String
    let name: String
    let icon: String?
    let description: String?
    let iconFallback: String?
    let gifCover: String?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, description, iconFallback
        case gifCoverSnake = "gif_cover"
        case gifCoverCamel = "gifCover"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.icon = try? c.decode(String.self, forKey: .icon)
        self.description = try? c.decode(String.self, forKey: .description)
        self.iconFallback = try? c.decode(String.self, forKey: .iconFallback)
        self.gifCover = (try? c.decode(String.self, forKey: .gifCoverSnake))
            ?? (try? c.decode(String.self, forKey: .gifCoverCamel))
    }

    func toGameData() -> GameData {
        GameData(
            id: id,
            name: name,
            iconUrl: icon ?? "",
            description: description ?? "",
            iconFallback: iconFallback,
            gifCover: gifCover
        )
    }
}

/// The `catalog` field when it arrives as an object wrapping a `data` array.
private struct CatalogDataObject: Decodable {
    let data: LossyCatalogItems?
}

/// Top-level catalog response. `catalog` may be a direct array of games, an
/// object with a `data` array, or absent (games then come from top-level `data`).
struct CatalogAPIResponse: Decodable {
    let menuId: String
    let games: [CatalogGameItem]

    enum CodingKeys: String, CodingKey {
        case menuId = "menu_id"
        case catalog
        case data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.menuId = (try? c.decode(String.self, forKey: .menuId)) ?? ""

        if let array = try? c.decode(LossyCatalogItems.self, forKey: .catalog) {
            self.games = array.items                       // catalog: [ … ]
        } else if let object = try? c.decode(CatalogDataObject.self, forKey: .catalog) {
            self.games = object.data?.items ?? []          // catalog: { data: [ … ] }
        } else if let array = try? c.decode(LossyCatalogItems.self, forKey: .data) {
            self.games = array.items                       // data: [ … ]
        } else {
            self.games = []
        }
    }
}

/// Internal catalog result matching React's CatalogResponse
public struct CatalogResponse: Sendable {
    public let menuId: String
    public let games: [GameData]
}

/// Decodes a catalog response payload into a `CatalogResponse`.
///
/// Pure and testable. Tolerant of the shapes the server may return (object with
/// `catalog` array / `catalog.data` / top-level `data`, or a bare array), and
/// lossy per game so one bad entry can't drop the rest. Throws only when the
/// payload is neither a JSON object nor array (e.g. malformed JSON), so genuine
/// contract breaks surface as an error rather than a silently empty catalog.
func parseCatalog(_ data: Data) throws -> CatalogResponse {
    let decoder = JSONDecoder()
    if let response = try? decoder.decode(CatalogAPIResponse.self, from: data) {
        return CatalogResponse(menuId: response.menuId, games: response.games.map { $0.toGameData() })
    }
    // Some deployments return a bare array of games.
    let items = try decoder.decode(LossyCatalogItems.self, from: data)
    return CatalogResponse(menuId: "", games: items.items.map { $0.toGameData() })
}

/// Request body for POST /minigames/init
public struct InitMinigameRequest: Sendable {
    public let gameType: String
    public let sessionId: String
    public var convId: String? = nil
    public var currencyMode: Bool = false
    public var w: CGFloat
    public var h: CGFloat
    public var charId: String?
    public var charName: String?
    public var charImage: String?
    public var charDesc: String?
    public var messages: [Message]?
    public var delegateChar: Bool = true
    public var menuId: String?

    public init(
        gameType: String,
        sessionId: String,
        convId: String? = nil,
        currencyMode: Bool = false,
        w: CGFloat,
        h: CGFloat,
        charId: String? = nil,
        charName: String? = nil,
        charImage: String? = nil,
        charDesc: String? = nil,
        messages: [Message]? = nil,
        delegateChar: Bool = true,
        menuId: String? = nil
    ) {
        self.gameType = gameType
        self.sessionId = sessionId
        self.convId = convId
        self.currencyMode = currencyMode
        self.w = w
        self.h = h
        self.charId = charId
        self.charName = charName
        self.charImage = charImage
        self.charDesc = charDesc
        self.messages = messages
        self.delegateChar = delegateChar
        self.menuId = menuId
    }
}

/// Response from POST /minigames/init
public struct MinigameResponse: Sendable {
    public let adType: String
    public let adInserted: Bool
    public let adId: String
    public let iframeUrl: String
    /// OMID verification resources for the game iframe (empty unless the backend sends them).
    public let adVerifications: [AdVerification]

    public init(adType: String, adInserted: Bool, adId: String, iframeUrl: String,
                adVerifications: [AdVerification] = []) {
        self.adType = adType
        self.adInserted = adInserted
        self.adId = adId
        self.iframeUrl = iframeUrl
        self.adVerifications = adVerifications
    }
}

/// Internal raw JSON response for init minigame
private struct MinigameAPIResponse: Decodable {
    let adType: String?
    let adInserted: Bool?
    let adResponse: MinigameAdResponse?
}

private struct MinigameAdResponse: Decodable {
    let adId: String?
    let iframeUrl: String?
    let adVerifications: [AdVerification]

    enum CodingKeys: String, CodingKey {
        case adId = "ad_id"
        case iframeUrl = "iframe_url"
        case adVerifications = "ad_verifications"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.adId = try? c.decode(String.self, forKey: .adId)
        self.iframeUrl = try? c.decode(String.self, forKey: .iframeUrl)
        self.adVerifications = c.decodeAdVerifications(forKey: .adVerifications)
    }
}

// MARK: - Ad Load (imperative prefetch)

/// Where a creative's CTA leads. Unknown/absent values fall back to `.appstore`.
public enum AdDestination: String, Sendable {
    case appstore
    case web
}

/// One IAB Open Measurement verification vendor entry from a response `ad_verifications`
/// array. All fields are optional so a partial/unexpected shape is tolerated; an entry
/// without `javascript_resource_url` is unusable and dropped when building OMID resources.
/// Forward-compatible — the backend does not send this today.
public struct AdVerification: Decodable, Sendable {
    public let vendorKey: String?
    public let javascriptResourceUrl: String
    public let verificationParameters: String?

    enum CodingKeys: String, CodingKey {
        case vendorKey = "vendor_key"
        case javascriptResourceUrl = "javascript_resource_url"
        case verificationParameters = "verification_parameters"
    }
}

/// Decodes an `ad_verifications` array tolerantly: missing/partial entries are skipped,
/// a missing key yields an empty array (never throws).
extension KeyedDecodingContainer {
    func decodeAdVerifications(forKey key: Key) -> [AdVerification] {
        ((try? decode([FailableVerification].self, forKey: key)) ?? [])
            .compactMap { $0.value }
    }
}

/// Wrapper so one malformed entry doesn't fail the whole `ad_verifications` array.
private struct FailableVerification: Decodable {
    let value: AdVerification?
    init(from decoder: Decoder) throws {
        value = try? AdVerification(from: decoder)
    }
}

/// Request body for POST /ads/load/interstitial — the imperative `.load()` prefetch call.
public struct AdLoadRequest: Encodable, Sendable {
    public let adUnitId: String
    public let sessionId: String
    /// Optional character context the backend can use to target the creative.
    /// Encoded only when non-nil (synthesized `encodeIfPresent`).
    public let charId: String?
    public let charName: String?
    public let charImage: String?
    public let charDesc: String?
    /// Device capability snapshot so the backend never assigns an unsupported variant.
    public let capabilities: DeviceCapabilities

    enum CodingKeys: String, CodingKey {
        case adUnitId = "ad_unit_id"
        case sessionId = "session_id"
        case charId = "char_id"
        case charName = "char_name"
        case charImage = "char_image"
        case charDesc = "char_desc"
        case capabilities
    }

    public init(
        adUnitId: String,
        sessionId: String = "",
        charId: String? = nil,
        charName: String? = nil,
        charImage: String? = nil,
        charDesc: String? = nil,
        capabilities: DeviceCapabilities = .current
    ) {
        self.adUnitId = adUnitId
        self.sessionId = sessionId
        self.charId = charId
        self.charName = charName
        self.charImage = charImage
        self.charDesc = charDesc
        self.capabilities = capabilities
    }
}

/// Prefetch payload from POST /ads/load/interstitial. The SDK caches this and renders
/// the server-rendered `rendered_html` itself in a web view. `destination` says whether
/// a CTA tap opens the App Store or a web URL; `trackingUrl` is the click-attribution
/// redirect to open. Decoding is tolerant: missing fields fall back to defaults so
/// a partial payload can't fail the whole decode (malformed JSON still throws).
public struct AdLoadResponse: Decodable, Sendable {
    public let adId: String
    public let adInserted: Bool
    public let adUnitId: String
    public let destination: String
    public let renderedFormat: String?
    public let trackingUrl: String?
    /// Server-rendered HTML creative. When present (non-blank) it is rendered
    /// full-screen in a web view — the imperative interstitial's sole creative.
    public let renderedHtml: String?
    /// Server-driven render config for this impression (A/B test). `nil` when the payload
    /// omits `ad_behavior` — the renderer falls back to today's literal close button / store path.
    public let adBehavior: AdBehavior?
    /// Creative descriptor (`creative` node). `nil` when omitted; `adUnitType` drives close copy.
    public let creative: Creative?
    /// Experiment-assignment metadata (`experiment` node), carried for telemetry only.
    public let experiment: Experiment?
    /// OMID verification resources (`ad_verifications`). Empty unless the backend sends them
    /// (forward-compatible). HTML interstitials are measured via injected JS, not this list.
    public let adVerifications: [AdVerification]

    /// `destination` mapped to a typed value; unknown strings fall back to `.appstore`.
    public var destinationKind: AdDestination {
        AdDestination(rawValue: destination) ?? .appstore
    }

    /// Returns a copy with `renderedHtml` replaced (e.g. after OMID script injection),
    /// preserving every other field.
    public func withRenderedHtml(_ html: String?) -> AdLoadResponse {
        AdLoadResponse(
            adId: adId, adInserted: adInserted, adUnitId: adUnitId, destination: destination,
            renderedFormat: renderedFormat, trackingUrl: trackingUrl, renderedHtml: html,
            adBehavior: adBehavior, creative: creative, experiment: experiment,
            adVerifications: adVerifications
        )
    }

    /// The HTML creative to render — trimmed and non-blank — or `nil`. A `nil`
    /// value means the payload carries no renderable creative (no-fill).
    public var htmlCreative: String? {
        guard let html = renderedHtml,
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return html
    }

    /// The ad format for this impression. Prefers the nested `creative.ad_unit_type`; falls back
    /// to the legacy `rendered_format` so older payloads (`rewarded_video`) keep working.
    public var adUnitType: AdUnitType {
        if let creative { return creative.adUnitType }
        return renderedFormat == "rewarded_video" ? .rewarded : .interstitial
    }

    enum CodingKeys: String, CodingKey {
        case adId = "ad_id"
        case adInserted = "ad_inserted"
        case adUnitId = "ad_unit_id"
        case destination
        case renderedFormat = "rendered_format"
        case trackingUrl = "tracking_url"
        case renderedHtml = "rendered_html"
        case adBehavior = "ad_behavior"
        case creative
        case experiment
        case adVerifications = "ad_verifications"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.adId = (try? c.decode(String.self, forKey: .adId)) ?? ""
        self.adInserted = (try? c.decode(Bool.self, forKey: .adInserted)) ?? false
        self.adUnitId = (try? c.decode(String.self, forKey: .adUnitId)) ?? ""
        self.destination = (try? c.decode(String.self, forKey: .destination)) ?? AdDestination.appstore.rawValue
        self.renderedFormat = try? c.decode(String.self, forKey: .renderedFormat)
        self.trackingUrl = try? c.decode(String.self, forKey: .trackingUrl)
        self.renderedHtml = try? c.decode(String.self, forKey: .renderedHtml)
        // Absent `ad_behavior` decodes to nil (render today's defaults); a present object
        // decodes tolerantly (partial/unknown fields fall back per-field, never throwing).
        self.adBehavior = try? c.decode(AdBehavior.self, forKey: .adBehavior)
        self.creative = try? c.decode(Creative.self, forKey: .creative)
        self.experiment = try? c.decode(Experiment.self, forKey: .experiment)
        self.adVerifications = c.decodeAdVerifications(forKey: .adVerifications)
    }

    /// Member-wise init for internal construction and tests.
    public init(
        adId: String,
        adInserted: Bool,
        adUnitId: String,
        destination: String = "appstore",
        renderedFormat: String? = nil,
        trackingUrl: String? = nil,
        renderedHtml: String? = nil,
        adBehavior: AdBehavior? = nil,
        creative: Creative? = nil,
        experiment: Experiment? = nil,
        adVerifications: [AdVerification] = []
    ) {
        self.adId = adId
        self.adInserted = adInserted
        self.adUnitId = adUnitId
        self.destination = destination
        self.renderedFormat = renderedFormat
        self.trackingUrl = trackingUrl
        self.renderedHtml = renderedHtml
        self.adBehavior = adBehavior
        self.creative = creative
        self.experiment = experiment
        self.adVerifications = adVerifications
    }
}

// MARK: - Rewarded Minigame Models

/// Request body for POST /minigames/init/rewarded — the rewarded `.load()` call.
/// `minPlayThreshold` (seconds) is optional; when omitted the server decides the
/// required play duration and returns it as `duration_seconds`.
public struct RewardedInitRequest: Encodable, Sendable {
    public let adUnitId: String
    public let sessionId: String
    public let minPlayThreshold: Int?
    /// Optional character context the backend can use to target the minigame.
    /// Encoded only when non-nil (synthesized `encodeIfPresent`).
    public let charId: String?
    public let charName: String?
    public let charImage: String?
    public let charDesc: String?

    enum CodingKeys: String, CodingKey {
        case adUnitId = "ad_unit_id"
        case sessionId = "session_id"
        case minPlayThreshold = "min_play_threshold"
        case charId = "char_id"
        case charName = "char_name"
        case charImage = "char_image"
        case charDesc = "char_desc"
    }

    public init(
        adUnitId: String,
        sessionId: String = "",
        minPlayThreshold: Int? = nil,
        charId: String? = nil,
        charName: String? = nil,
        charImage: String? = nil,
        charDesc: String? = nil
    ) {
        self.adUnitId = adUnitId
        self.sessionId = sessionId
        self.minPlayThreshold = minPlayThreshold
        self.charId = charId
        self.charName = charName
        self.charImage = charImage
        self.charDesc = charDesc
    }
}

/// Payload from POST /minigames/init/rewarded. The SDK renders `iframeUrl` in a
/// WebView and enforces `durationSeconds` before the reward can be earned. Decoding
/// is tolerant: missing fields fall back to defaults so a partial payload can't fail
/// the whole decode (malformed JSON still throws).
public struct RewardedInitResponse: Decodable, Sendable {
    public let serveId: String
    public let iframeUrl: String
    public let adId: String
    public let durationSeconds: Int
    /// OMID verification resources for the game iframe. Empty unless the backend sends
    /// them (forward-compatible); drives an optional native-display OMID session.
    public let adVerifications: [AdVerification]

    enum CodingKeys: String, CodingKey {
        case serveId = "serve_id"
        case iframeUrl = "iframe_url"
        case adId = "ad_id"
        case durationSeconds = "duration_seconds"
        case adVerifications = "ad_verifications"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.serveId = (try? c.decode(String.self, forKey: .serveId)) ?? ""
        self.iframeUrl = (try? c.decode(String.self, forKey: .iframeUrl)) ?? ""
        self.adId = (try? c.decode(String.self, forKey: .adId)) ?? ""
        self.durationSeconds = (try? c.decode(Int.self, forKey: .durationSeconds)) ?? 0
        self.adVerifications = c.decodeAdVerifications(forKey: .adVerifications)
    }

    /// Member-wise init for internal construction and tests.
    public init(serveId: String, iframeUrl: String, adId: String = "", durationSeconds: Int,
                adVerifications: [AdVerification] = []) {
        self.serveId = serveId
        self.iframeUrl = iframeUrl
        self.adId = adId
        self.durationSeconds = durationSeconds
        self.adVerifications = adVerifications
    }
}

/// Request body for POST /minigames/verify-reward.
public struct VerifyRewardRequest: Encodable, Sendable {
    public let serveId: String
    public let sessionId: String
    public let elapsedPlayTime: Double

    enum CodingKeys: String, CodingKey {
        case serveId = "serve_id"
        case sessionId = "session_id"
        case elapsedPlayTime = "elapsed_play_time"
    }

    public init(serveId: String, sessionId: String, elapsedPlayTime: Double) {
        self.serveId = serveId
        self.sessionId = sessionId
        self.elapsedPlayTime = elapsedPlayTime
    }
}

/// Response from POST /minigames/verify-reward. `token` is the publisher-facing
/// reward token; the backend fires the SSV postback server-side on a verified call.
public struct VerifyRewardResponse: Decodable, Sendable {
    public let verified: Bool
    public let token: String?

    public init(verified: Bool, token: String?) {
        self.verified = verified
        self.token = token
    }

    enum CodingKeys: String, CodingKey {
        case verified, token
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.verified = (try? c.decode(Bool.self, forKey: .verified)) ?? false
        self.token = try? c.decode(String.self, forKey: .token)
    }
}

// MARK: - SimulaAPI

/// Centralized API client for all Simula endpoints (translates api.ts)
public final class SimulaAPI: @unchecked Sendable {
    private let session: URLSession

    /// Shared session tuned for the ad path. The default `URLSession.shared`
    /// uses a 60s request timeout, which would let a hung ad/init request stall
    /// the experience. These tighter limits fail fast instead.
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10   // per-request inactivity timeout
        config.timeoutIntervalForResource = 20  // overall ceiling for one resource
        config.waitsForConnectivity = false     // fail fast when offline
        // Session-wide task delegate harvests URLSessionTaskMetrics into telemetry for every
        // request (skipping the telemetry endpoint itself). Async `data(for:)` still works.
        return URLSession(
            configuration: config,
            delegate: TelemetryURLSessionDelegate.shared,
            delegateQueue: nil
        )
    }()

    /// Cached ISO-8601 formatter. `ISO8601DateFormatter` construction is costly,
    /// and the viewport tracking calls would otherwise allocate one per event.
    /// `string(from:)` is thread-safe, so a single shared instance is fine.
    private static let iso8601Formatter = ISO8601DateFormatter()

    public init(session: URLSession? = nil) {
        self.session = session ?? SimulaAPI.defaultSession
    }

    // MARK: - Common Headers

    private func makeHeaders(apiKey: String? = nil, consent: ConsentSnapshot? = nil) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "ngrok-skip-browser-warning": "1",
        ]
        if let apiKey = apiKey {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        // Attach consent signals to every request from the single header chokepoint.
        // Reads the process-wide store unless an explicit snapshot is supplied.
        let snapshot = consent ?? SimulaPrivacy.shared.currentSnapshot
        for (key, value) in snapshot.consentHeaders() {
            headers[key] = value
        }
        return headers
    }

    private func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    // MARK: - Create Session

    /// Creates a server session and returns its id.
    /// Translates `createSession()` from api.ts
    public func createSession(
        apiKey: String,
        devMode: Bool = false,
        primaryUserID: String? = nil,
        privacy: ConsentSnapshot? = nil
    ) async throws -> String? {
        guard let url = URL(string: "\(API_BASE_URL)/session/create") else { throw SimulaAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(apiKey: apiKey, consent: privacy), to: &request)
        // Body carries dev/user identity, the device-capability handshake (so the backend never
        // assigns an unsupported variant), plus, when present, the consent block the backend ties
        // to the session and inherits on subsequent calls.
        var body: [String: Any] = ["devMode": devMode]
        if let ppid = primaryUserID, !ppid.isEmpty { body["ppid"] = ppid }
        body["capabilities"] = DeviceCapabilities.current.dictionary
        if let privacy { body["privacy"] = privacy.privacyBody() }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        if httpResponse.statusCode == 401 {
            throw SimulaAPIError.invalidApiKey
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let json = try JSONDecoder().decode(CreateSessionResponse.self, from: data)
        // Honor a server-side telemetry directive (kill-switch / sampling) if present.
        if json.telemetryEnabled != nil || json.telemetrySampleRate != nil {
            Telemetry.shared.applyServerConfig(
                enabled: json.telemetryEnabled ?? true,
                sampleRate: json.telemetrySampleRate ?? 1.0
            )
        }
        if let sid = json.sessionId, !sid.isEmpty {
            return sid
        }
        return nil
    }

    // MARK: - Fetch Catalog

    /// Fetches the game catalog.
    /// Translates `fetchCatalog()` from api.ts
    ///
    /// `sessionId` is passed through as the `session_id` query param when available (the backend
    /// ties the catalog to the session); omitted when nil/empty.
    public func fetchCatalog(sessionId: String? = nil) async throws -> CatalogResponse {
        guard let url = Self.catalogURL(sessionId: sessionId) else {
            throw SimulaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(makeHeaders(), to: &request)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SimulaAPIError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        // Decode flexibly into the SDK's CatalogResponse (see parseCatalog).
        return try parseCatalog(data)
    }

    /// Builds the catalog request URL, adding `session_id` when available. Pure/testable.
    static func catalogURL(sessionId: String? = nil) -> URL? {
        guard var components = URLComponents(string: "\(API_BASE_URL)/minigames/catalog") else {
            return nil
        }
        if let sessionId, !sessionId.isEmpty {
            components.queryItems = [URLQueryItem(name: "session_id", value: sessionId)]
        }
        return components.url
    }

    // MARK: - Load Ad (imperative prefetch)

    /// Prefetches one interstitial creative via POST /ads/load/interstitial. Pure
    /// transport: returns the response as-is — including `ad_inserted == false`, which
    /// the caller maps to a no-fill. No impression is fired here; `.load()` is prefetch
    /// only.
    public func loadAd(
        adUnitId: String,
        sessionId: String = "",
        charId: String? = nil,
        charName: String? = nil,
        charImage: String? = nil,
        charDesc: String? = nil
    ) async throws -> AdLoadResponse {
        guard let url = URL(string: "\(API_BASE_URL)/load/interstitial") else {
            throw SimulaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(), to: &request)
        request.httpBody = try JSONEncoder().encode(
            AdLoadRequest(
                adUnitId: adUnitId,
                sessionId: sessionId,
                charId: charId,
                charName: charName,
                charImage: charImage,
                charDesc: charDesc
            )
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SimulaAPIError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        return try JSONDecoder().decode(AdLoadResponse.self, from: data)
    }

    // MARK: - Rewarded Minigame

    /// Initializes a rewarded minigame via POST /minigames/init/rewarded. Returns the
    /// iframe URL, the `serve_id` that ties the play to its later verification, and the
    /// `duration_seconds` the SDK must enforce before a reward can be earned.
    public func loadRewarded(
        adUnitId: String,
        sessionId: String = "",
        minPlayThreshold: Int? = nil,
        charId: String? = nil,
        charName: String? = nil,
        charImage: String? = nil,
        charDesc: String? = nil
    ) async throws -> RewardedInitResponse {
        guard let url = URL(string: "\(API_BASE_URL)/load/rewarded") else {
            throw SimulaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(), to: &request)
        request.httpBody = try JSONEncoder().encode(
            RewardedInitRequest(
                adUnitId: adUnitId,
                sessionId: sessionId,
                minPlayThreshold: minPlayThreshold,
                charId: charId,
                charName: charName,
                charImage: charImage,
                charDesc: charDesc
            )
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SimulaAPIError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        return try JSONDecoder().decode(RewardedInitResponse.self, from: data)
    }

    /// Verifies a rewarded play via POST /minigames/verify-reward. On a verified call
    /// the backend fires the publisher's SSV postback server-side and returns the
    /// reward `token`. Idempotent: a repeated call for the same `serve_id` returns 409,
    /// which is treated here as a successful (already-claimed) verification so retries
    /// converge without double-rewarding.
    public func verifyReward(
        serveId: String,
        sessionId: String,
        elapsedPlayTime: Double
    ) async throws -> VerifyRewardResponse {
        guard let url = URL(string: "\(API_BASE_URL)/minigames/verify-reward") else {
            throw SimulaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(), to: &request)
        request.httpBody = try JSONEncoder().encode(
            VerifyRewardRequest(serveId: serveId, sessionId: sessionId, elapsedPlayTime: elapsedPlayTime)
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimulaAPIError.invalidResponse
        }

        // Already claimed — treat as a successful idempotent verification.
        if httpResponse.statusCode == 409 {
            return VerifyRewardResponse(verified: true, token: nil)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SimulaAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(VerifyRewardResponse.self, from: data)
    }

    // MARK: - Init Minigame

    /// Initializes a minigame and returns the iframe URL + ad id.
    /// Translates `getMinigame()` from api.ts
    public func getMinigame(_ params: InitMinigameRequest) async throws -> MinigameResponse {
        guard let url = URL(string: "\(API_BASE_URL)/minigames/init") else {
            throw SimulaAPIError.invalidURL
        }

        var body: [String: Any] = [
            "game_type": params.gameType,
            "session_id": params.sessionId,
            "currency_mode": params.currencyMode,
            "w": params.w,
            "h": params.h,
            "delegate_char": params.delegateChar,
        ]
        if let convId = params.convId { body["conv_id"] = convId }
        if let charId = params.charId { body["char_id"] = charId }
        if let charName = params.charName { body["char_name"] = charName }
        if let charImage = params.charImage { body["char_image"] = charImage }
        if let charDesc = params.charDesc { body["char_desc"] = charDesc }
        if let menuId = params.menuId { body["menu_id"] = menuId }

        if let messages = params.messages {
            body["messages"] = messages.map { ["role": $0.role, "content": $0.content] }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(), to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SimulaAPIError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        let apiResponse = try JSONDecoder().decode(MinigameAPIResponse.self, from: data)

        guard let adResponse = apiResponse.adResponse,
              let adId = adResponse.adId,
              let iframeUrl = adResponse.iframeUrl else {
            throw SimulaAPIError.invalidResponse
        }

        return MinigameResponse(
            adType: apiResponse.adType ?? "minigame",
            adInserted: apiResponse.adInserted ?? false,
            adId: adId,
            iframeUrl: iframeUrl,
            adVerifications: adResponse.adVerifications
        )
    }

    // MARK: - Fetch Ad for Minigame

    /// Fetches a fallback ad after minigame play.
    /// Translates `fetchAdForMinigame()` from api.ts
    public func fetchAdForMinigame(aid: String) async throws -> String? {
        guard let url = URL(string: "\(API_BASE_URL)/minigames/fallback_ad/\(aid)") else {
            throw SimulaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(), to: &request)
        request.httpBody = nil

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SimulaAPIError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        let apiResponse = try JSONDecoder().decode(MinigameAPIResponse.self, from: data)

        if let adResponse = apiResponse.adResponse,
           let iframeUrl = adResponse.iframeUrl, !iframeUrl.isEmpty {
            return iframeUrl
        }

        return nil
    }

    // MARK: - Track Menu Game Click

    /// Tracks when a user clicks a game in the menu.
    /// Translates `trackMenuGameClick()` from api.ts
    public func trackMenuGameClick(
        menuId: String,
        gameName: String,
        apiKey: String
    ) async {
        guard let url = URL(string: "\(API_BASE_URL)/minigames/menu/track/click") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(apiKey: apiKey), to: &request)

        let body: [String: Any] = [
            "menu_id": menuId,
            "game_name": gameName,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _ = try? await session.data(for: request)
    }

    // MARK: - Track Impression

    /// Tracks an ad impression. When the load response carried an `experiment` node, its
    /// assignment metadata rides along so impressions can be attributed to the A/B variant.
    /// Translates `trackImpression()` from api.ts
    public func trackImpression(adId: String, apiKey: String, experiment: Experiment? = nil) async {
        // An empty `adId` would POST to `.../impression/` (no id) — skip it.
        guard !adId.isEmpty else { return }
        guard let url = URL(string: "\(API_BASE_URL)/track/engagement/impression/\(adId)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(apiKey: apiKey), to: &request)
        var body: [String: Any] = [:]
        if let experiment {
            if let id = experiment.experimentId { body["experiment_id"] = id }
            if let variant = experiment.variantId { body["variant_id"] = variant }
            if let layer = experiment.layer { body["layer"] = layer }
        }
        request.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? "{}".data(using: .utf8)

        _ = try? await session.data(for: request)
    }

    // MARK: - Report Ad

    /// Submits a user-initiated ad report against the impression (`POST /impressions/{adId}/report`).
    /// `flag` is one of the `AdReportReason` wire values; `note` is an optional free-text detail. The
    /// backend stores the flag + note against the ad serve (no moderation on receipt). Best-effort and
    /// silent-fail like the other tracking calls — a report must never disrupt the ad experience.
    public func reportAd(adId: String, flag: String, note: String? = nil, apiKey: String) async {
        guard !adId.isEmpty else { return }
        guard let url = URL(string: "\(API_BASE_URL)/impressions/\(adId)/report") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(apiKey: apiKey), to: &request)
        var body: [String: Any] = ["flag": flag]
        if let note, !note.isEmpty { body["note"] = note }
        request.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? "{}".data(using: .utf8)

        _ = try? await session.data(for: request)
    }

    // MARK: - Track Viewport Entry

    /// Tracks when an ad enters the viewport.
    /// Translates `trackViewportEntry()` from api.ts
    public func trackViewportEntry(adId: String, apiKey: String) async {
        guard let url = URL(string: "\(API_BASE_URL)/track/engagement/viewport_entry/\(adId)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(apiKey: apiKey), to: &request)

        let body: [String: Any] = [
            "timestamp": SimulaAPI.iso8601Formatter.string(from: Date()),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _ = try? await session.data(for: request)
    }

    // MARK: - Track Viewport Exit

    /// Tracks when an ad exits the viewport.
    /// Translates `trackViewportExit()` from api.ts
    public func trackViewportExit(adId: String, apiKey: String) async {
        guard let url = URL(string: "\(API_BASE_URL)/track/engagement/viewport_exit/\(adId)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(apiKey: apiKey), to: &request)

        let body: [String: Any] = [
            "timestamp": SimulaAPI.iso8601Formatter.string(from: Date()),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _ = try? await session.data(for: request)
    }

    // MARK: - Telemetry

    /// Delivers a telemetry batch (`POST /v1/telemetry/events`), reusing the auth + consent
    /// headers so it inherits the same privacy posture as tracking. Returns the HTTP status
    /// (or -1 on a connectivity failure) for the caller to map to accept/drop/retry. The
    /// `TelemetryURLSessionDelegate` skips this path, so the request is never self-recorded.
    public func postTelemetry(apiKey: String, body: Data) async -> Int {
        guard let url = URL(string: "\(API_BASE_URL)/v1/telemetry/events") else { return -1 }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(apiKey: apiKey), to: &request)
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            return -1
        }
    }
}
