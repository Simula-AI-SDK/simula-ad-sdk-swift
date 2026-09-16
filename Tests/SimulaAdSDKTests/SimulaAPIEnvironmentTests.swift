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

    func testPolicyMatrix() {
        let development = SimulaArtifactEnvironmentPolicy(allowsStaging: true)
        let stable = SimulaArtifactEnvironmentPolicy(allowsStaging: false)

        XCTAssertEqual(development.environment(devMode: false), .production)
        XCTAssertEqual(development.environment(devMode: true), .staging)
        XCTAssertEqual(stable.environment(devMode: false), .production)
        XCTAssertEqual(stable.environment(devMode: true), .production)
    }

    func testArtifactVersionMatchesCompiledCapability() {
        let isDevTagged = SIMULA_SDK_VERSION.range(
            of: #"^\d+\.\d+\.\d+-dev\.\d+$"#,
            options: .regularExpression
        ) != nil
        XCTAssertEqual(SimulaArtifactEnvironmentPolicy.current.allowsStaging, isDevTagged)
    }

    func testFirstSelectionWinsAndConflictsAreRejected() {
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(allowsStaging: true)
        )

        let first = selection.claim(devMode: true)
        let matching = selection.claim(devMode: true)
        let conflict = selection.claim(devMode: false)

        XCTAssertEqual(first, ProcessAPIEnvironmentClaim(requested: .staging, effective: .staging))
        XCTAssertTrue(matching.isCompatible)
        XCTAssertFalse(conflict.isCompatible)
        XCTAssertEqual(conflict.effective, .staging)
        XCTAssertEqual(selection.effectiveEnvironment, .staging)
    }

    func testDirectRequestFreezesProductionBeforeLaterEntry() {
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(allowsStaging: true)
        )

        XCTAssertEqual(selection.environmentForRequest(), .production)
        XCTAssertFalse(selection.claim(devMode: true).isCompatible)
        XCTAssertEqual(selection.effectiveEnvironment, .production)
    }

    func testDirectCreateSessionClaimsStagingBeforeConstructingURL() async throws {
        #if SIMULA_DEV_ARTIFACT
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(allowsStaging: true)
        )
        let api = SimulaAPI(
            session: makeCapturingSession(),
            environmentSelection: selection
        )

        XCTAssertNil(selection.effectiveEnvironment, "constructing SimulaAPI must not freeze production")
        let sessionId = try await api.createSession(apiKey: "key", devMode: true)

        XCTAssertEqual(sessionId, "session-from-test")
        XCTAssertEqual(selection.effectiveEnvironment, .staging)
        XCTAssertEqual(SessionEnvironmentURLProtocol.requests.count, 1)
        XCTAssertEqual(
            SessionEnvironmentURLProtocol.requests.first?.url?.host,
            "simula-api-staging-701226639755.us-central1.run.app"
        )
        #endif
    }

    func testDirectCreateSessionConflictPerformsNoRequest() async throws {
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(allowsStaging: true)
        )
        XCTAssertTrue(selection.claim(devMode: false).isCompatible)
        let api = SimulaAPI(
            session: makeCapturingSession(),
            environmentSelection: selection
        )

        let sessionId = try await api.createSession(apiKey: "key", devMode: true)

        XCTAssertNil(sessionId)
        XCTAssertEqual(selection.effectiveEnvironment, .production)
        XCTAssertTrue(SessionEnvironmentURLProtocol.requests.isEmpty)
    }

    func testInvalidEntryDoesNotFreezeEnvironment() {
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(allowsStaging: true)
        )
        var errors: [String] = []

        let claim = claimProcessAPIEnvironmentIfValid(
            apiKey: "   ",
            devMode: true,
            selection: selection,
            reportInvalid: { errors.append($0) }
        )

        XCTAssertNil(claim)
        XCTAssertNil(selection.effectiveEnvironment)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(selection.claim(devMode: false).isCompatible)
    }

    func testConcurrentConflictingClaimsChooseOneEnvironment() async {
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(allowsStaging: true)
        )

        let claims = await withTaskGroup(of: ProcessAPIEnvironmentClaim.self) { group in
            group.addTask { selection.claim(devMode: false) }
            group.addTask { selection.claim(devMode: true) }
            var values: [ProcessAPIEnvironmentClaim] = []
            for await claim in group { values.append(claim) }
            return values
        }

        XCTAssertEqual(claims.filter(\.isCompatible).count, 1)
        XCTAssertEqual(Set(claims.map(\.effective)).count, 1)
        XCTAssertEqual(claims.first?.effective, selection.effectiveEnvironment)
    }

    @MainActor
    func testConflictingProviderIsInert() async {
        let ownership = ProcessApiKeyOwnership()
        let selection = ProcessAPIEnvironmentSelection(
            policy: SimulaArtifactEnvironmentPolicy(allowsStaging: true)
        )
        let staging = SimulaProvider(
            testApiKey: "same-key",
            apiKeyOwnership: ownership,
            devMode: true,
            environmentSelection: selection
        )
        let production = SimulaProvider(
            testApiKey: "same-key",
            apiKeyOwnership: ownership,
            devMode: false,
            environmentSelection: selection
        )

        XCTAssertTrue(staging.canMakeRequests)
        XCTAssertEqual(staging.apiEnvironment, .staging)
        XCTAssertFalse(production.canMakeRequests)
        XCTAssertEqual(production.apiEnvironment, .staging)
        let session = await production.ensureSession()
        XCTAssertNil(session)
    }

    func testEnvironmentURLsRemainCentralized() throws {
        let selected = SimulaArtifactEnvironmentPolicy.current.environment(devMode: true)
        let expectedDevHost = SimulaArtifactEnvironmentPolicy.current.allowsStaging
            ? "simula-api-staging-701226639755.us-central1.run.app"
            : "simula-api-701226639755.us-central1.run.app"
        XCTAssertEqual(
            try XCTUnwrap(SimulaAPI.catalogURL(environment: .production)).absoluteString,
            "https://simula-api-701226639755.us-central1.run.app/minigames/catalogv2"
        )
        XCTAssertEqual(
            try XCTUnwrap(SimulaAPI.catalogURL(environment: selected)).host,
            expectedDevHost
        )
        XCTAssertEqual(
            SimulaAPI.frequencyCapURL(adUnitId: "unit", environment: selected)?.host,
            expectedDevHost
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
