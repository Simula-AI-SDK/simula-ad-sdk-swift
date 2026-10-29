import XCTest
@testable import SimulaAdSDK

final class CatalogLaunchTests: XCTestCase {
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
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); captured.removeAll(); lock.unlock() }
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
        let body = url.path.hasSuffix("catalogv2")
            ? #"{"menu_id":"catalog-menu","catalog":[{"id":"chess","name":"Chess"}]}"#
            : #"{"adType":"minigame","adInserted":true,"adResponse":{"ad_id":"ad","serve_id":"serve","iframe_url":"https://example.com/game"}}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
