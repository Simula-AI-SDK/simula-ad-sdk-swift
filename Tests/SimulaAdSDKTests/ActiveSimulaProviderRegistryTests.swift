import XCTest
@testable import SimulaAdSDK

final class ActiveSimulaProviderRegistryTests: XCTestCase {
    func testDeclarativeBeforeImperativeAdoptsLatestCompatibleProviderAndIdentity() throws {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let configuration = coreConfiguration()
        let declarative = makeProvider(
            configuration: configuration,
            ownership: ownership,
            registry: registry
        )
        declarative.telemetryIdentitySource.setSessionId("shared-session")

        guard case .adopt(let adopted) = registry.resolve(configuration) else {
            return XCTFail("compatible declarative provider must be adopted")
        }
        XCTAssertTrue(adopted === declarative)
        XCTAssertTrue(adopted.telemetryIdentitySource === declarative.telemetryIdentitySource)

        let router = TelemetryIdentityRouter()
        router.bindImperative(adopted.telemetryIdentitySource)
        XCTAssertEqual(
            router.identity(apiKey: configuration.apiKey),
            TelemetryIdentity(sessionId: "shared-session", primaryUserId: "user")
        )
    }

    func testLatestSameKeyProviderWithConflictingCoreConfigIsRejected() {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let requested = coreConfiguration()
        _ = makeProvider(configuration: requested, ownership: ownership, registry: registry)
        let conflicting = SimulaProviderCoreConfiguration(
            apiKey: requested.apiKey,
            devMode: true,
            primaryUserID: requested.primaryUserID,
            hasPrivacyConsent: requested.hasPrivacyConsent,
            telemetryEnabled: requested.telemetryEnabled
        )
        let latest = makeProvider(
            configuration: conflicting,
            ownership: ownership,
            registry: registry
        )
        withExtendedLifetime(latest) {
            guard case .conflict = registry.resolve(requested) else {
                return XCTFail("latest conflicting provider must block split initialization")
            }
        }
    }

    func testNestedProviderDeinitRestoresPreviousActiveProvider() {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let configuration = coreConfiguration()
        let outer = makeProvider(configuration: configuration, ownership: ownership, registry: registry)
        var inner: SimulaProvider? = makeProvider(
            configuration: configuration,
            ownership: ownership,
            registry: registry
        )
        weak let weakInner = inner

        XCTAssertEqual(resolvedProviderID(registry, configuration), inner.map(ObjectIdentifier.init))

        inner = nil
        XCTAssertNil(weakInner)
        XCTAssertEqual(resolvedProviderID(registry, configuration), ObjectIdentifier(outer))
    }

    func testImperativeFirstResolutionStillCreatesProvider() {
        let registry = ActiveSimulaProviderRegistry()

        guard case .none = registry.resolve(coreConfiguration()) else {
            return XCTFail("empty registry must preserve imperative creation path")
        }
    }

    func testProviderViewReusesProviderPreviouslyAdoptedAsShared() {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let configuration = coreConfiguration()
        let adopted = makeProvider(configuration: configuration, ownership: ownership, registry: registry)
        var created = false

        let selected = selectSimulaProvider(shared: adopted, configuration: configuration) {
            created = true
            return self.makeProvider(
                configuration: configuration,
                ownership: ownership,
                registry: registry
            )
        }

        XCTAssertTrue(selected === adopted)
        XCTAssertFalse(created)
    }

    private func coreConfiguration() -> SimulaProviderCoreConfiguration {
        SimulaProviderCoreConfiguration(
            apiKey: "same-key",
            devMode: false,
            primaryUserID: "user",
            hasPrivacyConsent: true,
            telemetryEnabled: true
        )
    }

    private func makeProvider(
        configuration: SimulaProviderCoreConfiguration,
        ownership: ProcessApiKeyOwnership,
        registry: ActiveSimulaProviderRegistry
    ) -> SimulaProvider {
        SimulaProvider(
            testApiKey: configuration.apiKey,
            apiKeyOwnership: ownership,
            devMode: configuration.devMode,
            primaryUserID: configuration.primaryUserID,
            hasPrivacyConsent: configuration.hasPrivacyConsent,
            telemetryEnabled: configuration.telemetryEnabled,
            activeProviderRegistry: registry
        )
    }

    private func resolvedProviderID(
        _ registry: ActiveSimulaProviderRegistry,
        _ configuration: SimulaProviderCoreConfiguration
    ) -> ObjectIdentifier? {
        guard case .adopt(let provider) = registry.resolve(configuration) else { return nil }
        return ObjectIdentifier(provider)
    }
}
