import XCTest
@testable import SimulaAdSDK

final class CatalogLaunchTests: XCTestCase {
    @MainActor
    func testInitialAttResolutionDoesNotCancelOrReplaceCatalogSession() async throws {
        CatalogLaunchProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogLaunchProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let privacy = CatalogPrivacyState(ConsentSnapshot())
        let catalog = SimulaGameCatalog(
            api: SimulaAPI(session: session, environment: .production), apiKey: "test",
            privacySnapshot: { privacy.read() }, startup: {}
        )
        CatalogLaunchProtocol.beforeSessionResponse = { privacy.write(ConsentSnapshot(attStatus: 0)) }
        for _ in 0..<2 {
            let url = try await catalog.load(
                menuId: "menu", gameId: "chess", width: 390, height: 844,
                charId: "", charName: "", charImage: ""
            )
            XCTAssertEqual(url, "https://example.com/game")
        }
        XCTAssertEqual(CatalogLaunchProtocol.requests.filter { $0.url?.path.hasSuffix("session/create") == true }.count, 1)

        CatalogLaunchProtocol.beforeSessionResponse = nil
        privacy.write(ConsentSnapshot(attStatus: 3))
        _ = try await catalog.load(
            menuId: "menu", gameId: "chess", width: 390, height: 844,
            charId: "", charName: "", charImage: ""
        )
        XCTAssertEqual(CatalogLaunchProtocol.requests.filter { $0.url?.path.hasSuffix("session/create") == true }.count, 2)
    }

    @MainActor
    func testCatalogReusesOnlySessionsWithMatchingConsentAndSuppressesRestrictedIdentity() async throws {
        CatalogLaunchProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogLaunchProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var privacy = ConsentSnapshot()
        let catalog = SimulaGameCatalog(
            api: SimulaAPI(session: session, environment: .production), apiKey: "test",
            primaryUserID: "publisher-user", privacySnapshot: { privacy }, startup: {}
        )
        for snapshot in [ConsentSnapshot(), ConsentSnapshot(), ConsentSnapshot(hasPrivacyConsent: false), ConsentSnapshot(coppaApplies: true)] {
            privacy = snapshot
            _ = try await catalog.load(
                menuId: "menu", gameId: "chess", width: 390, height: 844,
                charId: "", charName: "", charImage: ""
            )
        }
        let requests = CatalogLaunchProtocol.requests.filter { $0.url?.path.hasSuffix("session/create") == true }
        XCTAssertEqual(requests.count, 3, "Reuse only while consent is unchanged")
        for (index, request) in requests.enumerated() {
            let data = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["ppid"] as? String, index == 0 ? "publisher-user" : nil)
            XCTAssertNotNil(json["privacy"])
        }
    }

    func testSessionSerializationSuppressesRawIdentifiersWhenConsentDisallowsThem() async throws {
        CatalogLaunchProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogLaunchProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = SimulaAPI(session: session, environment: .production)
        for privacy in [ConsentSnapshot(hasPrivacyConsent: false), ConsentSnapshot(coppaApplies: true)] {
            _ = try await api.createSession(apiKey: "test", primaryUserID: "publisher-user", privacy: privacy, applyTelemetryConfig: false)
        }
        for request in CatalogLaunchProtocol.requests {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertNil(json["ppid"])
        }
    }

    @MainActor
    func testPreparedPlayerRendersWithoutReadingAHostProvider() {
        let view = GameIframeView(
            gameId: "catalog", charID: "", charName: "", charImage: "",
            onClose: {}, preparedIframeUrl: "https://example.com/game"
        )
        // Accessing an absent EnvironmentObject would trap before returning this body.
        XCTAssertFalse(String(describing: view.body).isEmpty)
    }

    @MainActor
    func testCompletionFetchUsesTheScopedAPI() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogLaunchProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let catalog = SimulaGameCatalog(api: SimulaAPI(session: session, environment: .production), apiKey: "test")
        let completed = expectation(description: "completion")
        catalog.fetch { result in
            switch result {
            case .success(let value):
                XCTAssertEqual(value.menuId, "catalog-menu")
                XCTAssertEqual(value.games.first?.id, "chess")
            case .failure(let error): XCTFail("Unexpected fetch failure: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
    }

    @MainActor
    func testCancelledCompletionFetchDoesNotDeliverSuccess() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogLaunchProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let catalog = SimulaGameCatalog(api: SimulaAPI(session: session, environment: .production), apiKey: "test")
        let cancelled = expectation(description: "cancelled")
        let request = catalog.fetch { result in
            if case .success = result { XCTFail("Cancelled request delivered success") }
            cancelled.fulfill()
        }
        request.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testLaunchOptionsRemainScopedToTheirRequestAndEnvironment() async throws {
        CatalogLaunchProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogLaunchProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for (environment, enabled) in [(SimulaAPIEnvironment.staging, false), (.production, true), (.staging, true)] {
            let api = SimulaAPI(session: session, environment: environment)
            _ = try await api.getMinigame(InitMinigameRequest(
                gameType: "chess__exp", sessionId: "scoped-session", w: 390, h: 844, menuId: "simula-menu"
            ), companionEnabled: enabled)
        }

        let requests = CatalogLaunchProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-Simula-Dev-Companion") }, ["disabled", "enabled", "enabled"])
        XCTAssertEqual(requests[1].url?.host, "simula-api-701226639755.us-central1.run.app")
        #if SIMULA_DEV_ARTIFACT
        XCTAssertEqual(requests[0].url?.host, "simula-api-staging-701226639755.us-central1.run.app")
        XCTAssertEqual(requests[2].url?.host, requests[0].url?.host)
        #endif
        for request in requests {
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["game_id"] as? String, "chess__exp")
            XCTAssertEqual(json["menu_id"] as? String, "simula-menu")
            XCTAssertEqual(json["session_id"] as? String, "scoped-session")
        }
    }
}

private final class CatalogLaunchProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    private static var sessionResponseHook: (@Sendable () -> Void)?
    static var beforeSessionResponse: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return sessionResponseHook }
        set { lock.lock(); sessionResponseHook = newValue; lock.unlock() }
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); captured.removeAll(); sessionResponseHook = nil; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            captured.httpBody = body
        }
        Self.lock.lock(); Self.captured.append(captured); Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: String
        if url.path.hasSuffix("session/create") {
            Self.beforeSessionResponse?()
            body = #"{"sessionId":"catalog-session"}"#
        } else if url.path.hasSuffix("catalogv2") {
            body = #"{"menu_id":"catalog-menu","catalog":[{"id":"chess","name":"Chess"}]}"#
        } else {
            body = #"{"adType":"minigame","adInserted":true,"adResponse":{"ad_id":"ad","serve_id":"serve","iframe_url":"https://example.com/game"}}"#
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CatalogPrivacyState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConsentSnapshot
    init(_ value: ConsentSnapshot) { self.value = value }
    func read() -> ConsentSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: ConsentSnapshot) { lock.lock(); self.value = value; lock.unlock() }
}
