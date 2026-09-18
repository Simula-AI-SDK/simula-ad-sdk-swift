import XCTest
@testable import SimulaAdSDK

final class SimulaAPIEnvironmentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SessionEnvironmentURLProtocol.reset()
    }

    override func tearDown() {
        SessionEnvironmentURLProtocol.reset()
        super.tearDown()
    }

    func testEnvironmentGateMatrix() {
        for allowsStaging in [false, true] {
            for stagingOptInEnabled in [false, true] {
                let policy = SimulaArtifactEnvironmentPolicy(
                    allowsStaging: allowsStaging,
                    stagingOptInEnabled: stagingOptInEnabled
                )
                XCTAssertEqual(
                    policy.defaultEnvironment,
                    allowsStaging && stagingOptInEnabled ? .staging : .production
                )
            }
        }
    }

    func testInfoPlistGateAcceptsOnlyBooleanTrue() {
        XCTAssertTrue(
            SimulaArtifactEnvironmentPolicy.isEnabled(infoDictionaryValue: NSNumber(value: true))
        )
        XCTAssertFalse(
            SimulaArtifactEnvironmentPolicy.isEnabled(infoDictionaryValue: NSNumber(value: false))
        )
        XCTAssertFalse(SimulaArtifactEnvironmentPolicy.isEnabled(infoDictionaryValue: "true"))
        XCTAssertFalse(
            SimulaArtifactEnvironmentPolicy.isEnabled(infoDictionaryValue: NSNumber(value: 1))
        )
        XCTAssertFalse(SimulaArtifactEnvironmentPolicy.isEnabled(infoDictionaryValue: nil))
    }

    func testArtifactVersionMatchesCompiledCapability() {
        let isDevTagged = SIMULA_SDK_VERSION.range(
            of: #"^\d+\.\d+\.\d+-dev\.\d+$"#,
            options: .regularExpression
        ) != nil
        XCTAssertEqual(SimulaArtifactEnvironmentPolicy.current.allowsStaging, isDevTagged)
    }

    func testDirectRequestFreezesHostStagingDefault() {
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(
                allowsStaging: true,
                stagingOptInEnabled: true
            )
        )

        XCTAssertEqual(selection.environmentForRequest(), .staging)
        XCTAssertEqual(selection.environmentForRequest(), .staging)
        XCTAssertEqual(selection.effectiveEnvironment, .staging)
    }

    func testExplicitEnvironmentRequiresDevelopmentHostCapability() {
        let denied = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(allowsStaging: false, stagingOptInEnabled: true)
        )
        XCTAssertFalse(denied.configure(.staging))
        XCTAssertNil(denied.effectiveEnvironment)
        XCTAssertTrue(denied.configure(.production))

        let allowed = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(allowsStaging: true, stagingOptInEnabled: true)
        )
        XCTAssertTrue(allowed.configure(.staging))
        XCTAssertFalse(allowed.configure(.production))
        XCTAssertEqual(allowed.effectiveEnvironment, .staging)
    }

    func testEffectiveEnvironmentReadDoesNotFreezeHostDefault() {
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(
                allowsStaging: true,
                stagingOptInEnabled: true
            )
        )

        XCTAssertEqual(SimulaAds.apiEnvironment(selection: selection), .production)
        XCTAssertNil(selection.effectiveEnvironment)
        XCTAssertEqual(selection.environmentForRequest(), .staging)
        XCTAssertEqual(SimulaAds.apiEnvironment(selection: selection), .staging)
    }

    func testHostConfiguredStagingCreateSessionUsesStagingURL() async throws {
        let allowsStaging = SimulaArtifactEnvironmentPolicy.current.allowsStaging
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(
                allowsStaging: allowsStaging,
                stagingOptInEnabled: true
            )
        )
        let api = SimulaAPI(
            session: makeCapturingSession(),
            environmentSelection: selection
        )

        let sessionId = try await api.createSession(apiKey: "key", devMode: false)

        XCTAssertEqual(sessionId, "session-from-test")
        XCTAssertEqual(selection.effectiveEnvironment, allowsStaging ? .staging : .production)
        XCTAssertEqual(SessionEnvironmentURLProtocol.requests.count, 1)
        XCTAssertEqual(
            SessionEnvironmentURLProtocol.requests.first?.url?.host,
            allowsStaging
                ? "simula-api-staging-701226639755.us-central1.run.app"
                : "simula-api-701226639755.us-central1.run.app"
        )
    }

    func testDirectCreateSessionUsesHostDefaultIndependentlyOfDevMode() async throws {
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(
                allowsStaging: true,
                stagingOptInEnabled: true
            )
        )
        let api = SimulaAPI(
            session: makeCapturingSession(),
            environmentSelection: selection
        )

        let sessionId = try await api.createSession(apiKey: "key", devMode: true)

        XCTAssertEqual(sessionId, "session-from-test")
        XCTAssertEqual(selection.effectiveEnvironment, .staging)
        XCTAssertEqual(
            SessionEnvironmentURLProtocol.requests.first?.url?.host,
            "simula-api-staging-701226639755.us-central1.run.app"
        )
    }

    @MainActor
    func testProviderDevModeDoesNotOverrideHostConfiguredStaging() {
        let ownership = ProcessApiKeyOwnership()
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(
                allowsStaging: true,
                stagingOptInEnabled: true
            )
        )
        let normalMode = SimulaProvider(
            testApiKey: "same-key",
            apiKeyOwnership: ownership,
            devMode: false,
            environmentSelection: selection
        )
        let devMode = SimulaProvider(
            testApiKey: "same-key",
            apiKeyOwnership: ownership,
            devMode: true,
            environmentSelection: selection
        )

        XCTAssertTrue(normalMode.isProcessApiKeyCompatible)
        XCTAssertEqual(normalMode.apiEnvironment, .staging)
        XCTAssertTrue(devMode.isProcessApiKeyCompatible)
        XCTAssertEqual(devMode.apiEnvironment, .staging)
    }

    func testEnvironmentURLsRemainCentralized() throws {
        XCTAssertEqual(
            try XCTUnwrap(SimulaAPI.catalogURL(environment: .production)).absoluteString,
            "https://simula-api-701226639755.us-central1.run.app/minigames/catalogv2"
        )
        let expectedStagingHost = SimulaArtifactEnvironmentPolicy.current.allowsStaging
            ? "simula-api-staging-701226639755.us-central1.run.app"
            : "simula-api-701226639755.us-central1.run.app"
        XCTAssertEqual(
            try XCTUnwrap(SimulaAPI.catalogURL(environment: .staging)).host,
            expectedStagingHost
        )
        XCTAssertEqual(
            SimulaAPI.frequencyCapURL(adUnitId: "unit", environment: .staging)?.host,
            expectedStagingHost
        )
    }

    func testProductionStorageNamesAndMigrationsArePreserved() {
        XCTAssertEqual(SimulaEnvironmentStorageNames.beaconFileName(for: .production), "pending_beacons.json")
        XCTAssertEqual(SimulaEnvironmentStorageNames.beaconLegacyKey(for: .production), "simula_pending_beacons")
        XCTAssertEqual(
            SimulaEnvironmentStorageNames.rewardFileName(for: .production),
            "pending_reward_verifications.json"
        )
        XCTAssertEqual(
            SimulaEnvironmentStorageNames.rewardLegacyKey(for: .production),
            "simula_pending_reward_verifications"
        )
        XCTAssertEqual(
            SimulaEnvironmentStorageNames.telemetryKey(for: .production),
            "simula_pending_telemetry_events"
        )
        XCTAssertEqual(SimulaEnvironmentStorageNames.crashFileName(for: .production), "pending_crashes.txt")
        XCTAssertEqual(SimulaEnvironmentStorageNames.sdkLastVersionKey(for: .production), "simula_sdk_last_version")
    }

    func testStagingStorageNamesNeverOverlapProduction() {
        XCTAssertEqual(SimulaEnvironmentStorageNames.beaconFileName(for: .staging), "pending_beacons_staging.json")
        XCTAssertEqual(SimulaEnvironmentStorageNames.beaconLegacyKey(for: .staging), "simula_pending_beacons_staging")
        XCTAssertEqual(
            SimulaEnvironmentStorageNames.rewardFileName(for: .staging),
            "pending_reward_verifications_staging.json"
        )
        XCTAssertEqual(
            SimulaEnvironmentStorageNames.rewardLegacyKey(for: .staging),
            "simula_pending_reward_verifications_staging"
        )
        XCTAssertEqual(
            SimulaEnvironmentStorageNames.telemetryKey(for: .staging),
            "simula_pending_telemetry_events_staging"
        )
        XCTAssertEqual(SimulaEnvironmentStorageNames.crashFileName(for: .staging), "pending_crashes_staging.txt")
        XCTAssertEqual(
            SimulaEnvironmentStorageNames.sdkLastVersionKey(for: .staging),
            "simula_sdk_last_version_staging"
        )
    }

    func testTelemetryStoresAreEnvironmentIsolated() {
        let suite = "SimulaAPIEnvironmentTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let production = UserDefaultsTelemetryStore(defaults: defaults, environment: .production)
        let staging = UserDefaultsTelemetryStore(defaults: defaults, environment: .staging)
        let productionEvent = TelemetryEvent(type: TelemetryType.meta, name: "production", eventId: "p", timestamp: 1)
        let stagingEvent = TelemetryEvent(type: TelemetryType.meta, name: "staging", eventId: "s", timestamp: 2)

        production.save([productionEvent])
        XCTAssertEqual(production.load(), [productionEvent])
        XCTAssertTrue(staging.load().isEmpty)

        staging.save([stagingEvent])
        XCTAssertEqual(production.load(), [productionEvent])
        XCTAssertEqual(staging.load(), [stagingEvent])
    }

    func testIPv4BeaconIsProductionOnly() {
        XCTAssertTrue(SimulaAPIEnvironment.production.sendsIPv4Beacon)
        XCTAssertFalse(SimulaAPIEnvironment.staging.sendsIPv4Beacon)
    }

    private func makeCapturingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionEnvironmentURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class SessionEnvironmentURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    static func reset() {
        lock.lock(); captured.removeAll(); lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.captured.append(request); Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"sessionId":"session-from-test"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
