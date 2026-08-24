import XCTest
@testable import SimulaAdSDK

@MainActor
final class ProcessApiKeyOwnershipTests: XCTestCase {
    func testInvalidProviderClaimDoesNotConsumeOwnershipBeforeValidImperativeClaim() {
        let ownership = ProcessApiKeyOwnership()
        let errors = OwnershipErrorRecorder()

        let invalidCompatible = claimProcessApiKeyIfValid(
            "   ",
            ownership: ownership,
            reportInvalid: { errors.append($0) }
        )

        XCTAssertFalse(invalidCompatible)
        XCTAssertNil(ownership.effectiveApiKey)
        XCTAssertEqual(errors.values.count, 1)
        XCTAssertTrue(SimulaAds.claimApiKeyForInitialization("valid-key", ownership: ownership))
        XCTAssertEqual(ownership.effectiveApiKey, "valid-key")
    }

    func testProviderFirstAllowsMatchingImperativeAndRejectsDifferentKey() {
        let ownership = ProcessApiKeyOwnership()
        let provider = SimulaProvider(testApiKey: "key-a", apiKeyOwnership: ownership)

        XCTAssertTrue(provider.isProcessApiKeyCompatible)
        XCTAssertTrue(SimulaAds.claimApiKeyForInitialization("key-a", ownership: ownership))
        XCTAssertFalse(SimulaAds.claimApiKeyForInitialization("key-b", ownership: ownership))
        XCTAssertEqual(ownership.effectiveApiKey, "key-a")
    }

    func testImperativeFirstAllowsMatchingProviderAndMakesDifferentProviderInert() async {
        let ownership = ProcessApiKeyOwnership()
        XCTAssertTrue(SimulaAds.claimApiKeyForInitialization("key-a", ownership: ownership))

        let matching = SimulaProvider(testApiKey: "key-a", apiKeyOwnership: ownership)
        let mismatched = SimulaProvider(testApiKey: "key-b", apiKeyOwnership: ownership)

        XCTAssertTrue(matching.isProcessApiKeyCompatible)
        XCTAssertFalse(mismatched.isProcessApiKeyCompatible)
        XCTAssertFalse(mismatched.canMakeRequests)
        let sessionId = await mismatched.ensureSession()
        XCTAssertNil(sessionId)
    }

    func testSameKeyProvidersRemainCompatible() {
        let ownership = ProcessApiKeyOwnership()
        let first = SimulaProvider(testApiKey: "same-key", apiKeyOwnership: ownership)
        let second = SimulaProvider(testApiKey: "same-key", apiKeyOwnership: ownership)

        XCTAssertTrue(first.isProcessApiKeyCompatible)
        XCTAssertTrue(second.isProcessApiKeyCompatible)
        XCTAssertEqual(ownership.effectiveApiKey, "same-key")
    }

    func testDifferentKeyProviderCannotReplaceOwner() async {
        let ownership = ProcessApiKeyOwnership()
        let first = SimulaProvider(testApiKey: "key-a", apiKeyOwnership: ownership)
        let second = SimulaProvider(testApiKey: "key-b", apiKeyOwnership: ownership)

        XCTAssertTrue(first.isProcessApiKeyCompatible)
        XCTAssertFalse(second.isProcessApiKeyCompatible)
        XCTAssertEqual(ownership.effectiveApiKey, "key-a")
        let sessionId = await second.ensureSession()
        XCTAssertNil(sessionId)

        second.updatePrimaryUserID("ignored-user")
        second.cacheHeight(slot: "slot", position: 1, height: 200)
        second.markNoFill(slot: "slot", position: 1)
        XCTAssertNil(second.primaryUserID)
        XCTAssertNil(second.getCachedHeight(slot: "slot", position: 1))
        XCTAssertFalse(second.hasNoFill(slot: "slot", position: 1))
    }

    func testIncompatibleProviderWithPreloadedCatalogPlansNoMenuOrGameEffects() {
        let ownership = ProcessApiKeyOwnership()
        _ = SimulaProvider(testApiKey: "winning-key", apiKeyOwnership: ownership)
        let incompatible = SimulaProvider(testApiKey: "losing-key", apiKeyOwnership: ownership)
        let preloaded = CatalogResponse(menuId: "menu", games: [])

        let plan = miniGameCompatibilityPlan(
            providerCompatible: incompatible.canMakeRequests,
            hasPreloadedCatalog: preloaded.menuId.isEmpty == false
        )

        XCTAssertFalse(plan.rendersContent)
        XCTAssertFalse(plan.seedsPreloadedCatalog)
        XCTAssertFalse(plan.prewarmsWebView)
        XCTAssertFalse(plan.fetchesCatalog)
        XCTAssertFalse(plan.tracksClick)
        XCTAssertFalse(plan.loadsGame)
        XCTAssertFalse(plan.fetchesFallbacks)
    }

    func testIncompatibleProviderWithPreloadedNativeAdPlansNoSharedStateAccess() {
        let plan = nativeAdSlotStartupPlan(
            providerCompatible: false,
            hasPreview: false,
            hasPreloadedAd: true
        )

        XCTAssertFalse(plan.rendersContent)
        XCTAssertFalse(plan.readsPreload)
        XCTAssertFalse(plan.readsCache)
        XCTAssertFalse(plan.restoresRetainedCreative)
        XCTAssertFalse(plan.loadsNetwork)
    }

    func testCompatibleNativeSlotPreservesPreloadCacheAndNetworkFallbacks() {
        let plan = nativeAdSlotStartupPlan(
            providerCompatible: true,
            hasPreview: false,
            hasPreloadedAd: true
        )

        XCTAssertTrue(plan.rendersContent)
        XCTAssertTrue(plan.readsPreload)
        XCTAssertTrue(plan.readsCache)
        XCTAssertTrue(plan.restoresRetainedCreative)
        XCTAssertTrue(plan.loadsNetwork)
    }

    func testConcurrentDifferentKeyClaimsChooseExactlyOneOwner() async {
        let ownership = ProcessApiKeyOwnership()
        let claims = ApiKeyClaimRecorder()
        await runConcurrentClaims(keys: ["key-a", "key-b"], ownership: ownership, recorder: claims)

        let recorded = claims.values
        XCTAssertEqual(recorded.filter { $0.claim == .owner }.count, 1)
        XCTAssertEqual(recorded.filter { $0.claim.isCompatible }.count, 1)
        XCTAssertEqual(recorded.filter { !$0.claim.isCompatible }.count, 1)
        let ownerKey = recorded.first { $0.claim == .owner }?.key
        XCTAssertEqual(ownership.effectiveApiKey, ownerKey)
    }

    func testConcurrentSameKeyClaimsAreAllCompatible() async {
        let ownership = ProcessApiKeyOwnership()
        let claims = ApiKeyClaimRecorder()
        await runConcurrentClaims(
            keys: Array(repeating: "same-key", count: 16),
            ownership: ownership,
            recorder: claims
        )

        XCTAssertEqual(claims.values.filter { $0.claim == .owner }.count, 1)
        XCTAssertTrue(claims.values.allSatisfy { $0.claim.isCompatible })
        XCTAssertEqual(ownership.effectiveApiKey, "same-key")
    }

    func testConcurrentProviderStartupUsesWinningTelemetryForCrashAndBeacon() async {
        let store = OwnershipTelemetryStore()
        let sender = OwnershipTelemetrySender()
        let manager = TelemetryManager(
            ctx: TelemetryContext(
                sdkVersion: "test", osVersion: "test", deviceModel: "test",
                hostAppId: "test", devMode: true
            ),
            store: store,
            sender: sender,
            identityProvider: { TelemetryIdentity(sessionId: nil, primaryUserId: nil) },
            launchGate: ImmediateLaunchSettledGate.shared
        )
        let factoryStarted = OwnershipSignal()
        let factoryGate = ControllableLaunchSettledGate()
        let telemetry = Telemetry(managerFactory: { _, _ in
            factoryStarted.signal()
            await factoryGate.waitUntilSettled()
            return manager
        })
        let infrastructure = TelemetryInfrastructureRecorder()
        let secondStarted = OwnershipSignal()

        let first = Task { @MainActor in
            await Self.runStartup(
                telemetry: telemetry,
                apiKey: "winning-key",
                enabled: true,
                infrastructure: infrastructure
            )
        }
        await factoryStarted.wait()
        let second = Task { @MainActor in
            await Self.runStartupAfterSignal(
                secondStarted,
                telemetry: telemetry,
                apiKey: "winning-key",
                enabled: false,
                infrastructure: infrastructure
            )
        }
        await secondStarted.wait()
        await factoryGate.open()
        await first.value
        await second.value
        await manager.waitForRecoveryForTests()

        XCTAssertEqual(infrastructure.crashStates, [true, true])
        XCTAssertEqual(infrastructure.beaconKeys, ["winning-key", "winning-key"])
    }

    private static func runStartupAfterSignal(
        _ signal: OwnershipSignal,
        telemetry: Telemetry,
        apiKey: String,
        enabled: Bool,
        infrastructure: TelemetryInfrastructureRecorder
    ) async {
        signal.signal()
        await runStartup(
            telemetry: telemetry,
            apiKey: apiKey,
            enabled: enabled,
            infrastructure: infrastructure
        )
    }

    private static func runStartup(
        telemetry: Telemetry,
        apiKey: String,
        enabled: Bool,
        infrastructure: TelemetryInfrastructureRecorder
    ) async {
        let effective = await telemetry.initialize(apiKey: apiKey, devMode: true, enabled: enabled)
        SimulaProvider.installTelemetryDependentInfrastructure(
            effective,
            installCrashGuard: { infrastructure.recordCrash($0) },
            configureBeaconManager: { infrastructure.recordBeacon($0) }
        )
    }
}

private final class ApiKeyClaimRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(key: String, claim: ProcessApiKeyClaim)] = []

    func append(key: String, claim: ProcessApiKeyClaim) {
        lock.lock(); storage.append((key, claim)); lock.unlock()
    }

    var values: [(key: String, claim: ProcessApiKeyClaim)] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

private final class OwnershipErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class OwnershipSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class TelemetryInfrastructureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var crashes: [Bool] = []
    private var beacons: [String] = []

    func recordCrash(_ enabled: Bool) { lock.lock(); crashes.append(enabled); lock.unlock() }
    func recordBeacon(_ apiKey: String) { lock.lock(); beacons.append(apiKey); lock.unlock() }
    var crashStates: [Bool] { lock.lock(); defer { lock.unlock() }; return crashes }
    var beaconKeys: [String] { lock.lock(); defer { lock.unlock() }; return beacons }
}

private final class OwnershipTelemetryStore: TelemetryStoring, @unchecked Sendable {
    func load() -> [TelemetryEvent] { [] }
    func save(_ events: [TelemetryEvent]) {}
}

private final class OwnershipTelemetrySender: TelemetrySending, @unchecked Sendable {
    func send(_ body: Data) async -> TelemetryAck { .accepted }
}

private func runConcurrentClaims(
    keys: [String],
    ownership: ProcessApiKeyOwnership,
    recorder: ApiKeyClaimRecorder
) async {
    let queue = DispatchQueue(label: "api-key-ownership-claims", attributes: .concurrent)
    let ready = DispatchGroup()
    let completed = DispatchGroup()
    let start = DispatchSemaphore(value: 0)
    for key in keys {
        ready.enter()
        completed.enter()
        queue.async {
            ready.leave()
            start.wait()
            recorder.append(key: key, claim: ownership.claim(key))
            completed.leave()
        }
    }
    await waitForOwnershipGroup(ready, label: "api-key-ownership-ready")
    for _ in keys { start.signal() }
    await waitForOwnershipGroup(completed, label: "api-key-ownership-completed")
}

private func waitForOwnershipGroup(_ group: DispatchGroup, label: String) async {
    await withCheckedContinuation { continuation in
        group.notify(queue: DispatchQueue(label: label)) { continuation.resume() }
    }
}
