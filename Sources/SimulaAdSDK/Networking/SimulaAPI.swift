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

    enum CodingKeys: String, CodingKey {
        case adId = "ad_id"
        case iframeUrl = "iframe_url"
    }
}

// MARK: - SimulaAPI

/// Centralized API client for all Simula endpoints (translates api.ts)
public final class SimulaAPI: @unchecked Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder

    /// Shared session tuned for the ad path. The default `URLSession.shared`
    /// uses a 60s request timeout, which would let a hung ad/init request stall
    /// the experience. These tighter limits fail fast instead.
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10   // per-request inactivity timeout
        config.timeoutIntervalForResource = 20  // overall ceiling for one resource
        config.waitsForConnectivity = false     // fail fast when offline
        return URLSession(configuration: config)
    }()

    /// Cached ISO-8601 formatter. `ISO8601DateFormatter` construction is costly,
    /// and the viewport tracking calls would otherwise allocate one per event.
    /// `string(from:)` is thread-safe, so a single shared instance is fine.
    private static let iso8601Formatter = ISO8601DateFormatter()

    public init(session: URLSession? = nil) {
        self.session = session ?? SimulaAPI.defaultSession
        self.decoder = JSONDecoder()
    }

    // MARK: - Common Headers

    private func makeHeaders(apiKey: String? = nil) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "ngrok-skip-browser-warning": "1",
        ]
        if let apiKey = apiKey {
            headers["Authorization"] = "Bearer \(apiKey)"
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
        primaryUserID: String? = nil
    ) async throws -> String? {
        var components = URLComponents(string: "\(API_BASE_URL)/session/create")!
        var queryItems: [URLQueryItem] = []
        queryItems.append(URLQueryItem(name: "devMode", value: String(devMode)))
        if let ppid = primaryUserID, !ppid.isEmpty {
            queryItems.append(URLQueryItem(name: "ppid", value: ppid))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else { throw SimulaAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(apiKey: apiKey), to: &request)
        request.httpBody = "{}".data(using: .utf8)

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

        let json = try decoder.decode(CreateSessionResponse.self, from: data)
        if let sid = json.sessionId, !sid.isEmpty {
            return sid
        }
        return nil
    }

    // MARK: - Fetch Catalog

    /// Fetches the game catalog.
    /// Translates `fetchCatalog()` from api.ts
    public func fetchCatalog() async throws -> CatalogResponse {
        guard let url = URL(string: "\(API_BASE_URL)/minigames/catalogv2") else {
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

        let apiResponse = try decoder.decode(MinigameAPIResponse.self, from: data)

        guard let adResponse = apiResponse.adResponse,
              let adId = adResponse.adId,
              let iframeUrl = adResponse.iframeUrl else {
            throw SimulaAPIError.invalidResponse
        }

        return MinigameResponse(
            adType: apiResponse.adType ?? "minigame",
            adInserted: apiResponse.adInserted ?? false,
            adId: adId,
            iframeUrl: iframeUrl
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

        let apiResponse = try decoder.decode(MinigameAPIResponse.self, from: data)

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

    /// Tracks an ad impression.
    /// Translates `trackImpression()` from api.ts
    public func trackImpression(adId: String, apiKey: String) async {
        guard let url = URL(string: "\(API_BASE_URL)/track/engagement/impression/\(adId)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(makeHeaders(apiKey: apiKey), to: &request)
        request.httpBody = "{}".data(using: .utf8)

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
}
