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

    func testDeclarativeBeforeImperativeAdoptsProviderWhenOnlyLaterDevModeDiffers() {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let requested = coreConfiguration()
        let declarative = makeProvider(configuration: requested, ownership: ownership, registry: registry)
        let imperative = SimulaProviderCoreConfiguration(
            apiKey: requested.apiKey,
            devMode: !requested.devMode,
            primaryUserID: requested.primaryUserID,
            hasPrivacyConsent: requested.hasPrivacyConsent,
            telemetryEnabled: requested.telemetryEnabled
        )

        guard case .adopt(let adopted) = registry.resolve(imperative) else {
            return XCTFail("imperative initialization must reuse the first declarative provider")
        }
        XCTAssertTrue(adopted === declarative)
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

    func testImperativeBeforeDeclarativeReusesProviderWhenOnlyLaterDevModeDiffers() {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let activeConfiguration = coreConfiguration()
        let shared = makeProvider(
            configuration: activeConfiguration,
            ownership: ownership,
            registry: registry
        )
        let viewConfiguration = SimulaProviderCoreConfiguration(
            apiKey: activeConfiguration.apiKey,
            devMode: !activeConfiguration.devMode,
            primaryUserID: activeConfiguration.primaryUserID,
            hasPrivacyConsent: activeConfiguration.hasPrivacyConsent,
            telemetryEnabled: activeConfiguration.telemetryEnabled
        )
        var created = false

        let selected = selectSimulaProvider(shared: shared, configuration: viewConfiguration) {
            created = true
            return self.makeProvider(
                configuration: viewConfiguration,
                ownership: ownership,
                registry: registry
            )
        }

        XCTAssertTrue(selected === shared)
        XCTAssertFalse(created)
    }

    func testCoreConfigurationDifferencesOtherThanDevModeRemainConflicts() {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let configuration = coreConfiguration()
        let provider = makeProvider(
            configuration: configuration,
            ownership: ownership,
            registry: registry
        )
        let conflicts = [
            SimulaProviderCoreConfiguration(
                apiKey: "different-key",
                devMode: configuration.devMode,
                primaryUserID: configuration.primaryUserID,
                hasPrivacyConsent: configuration.hasPrivacyConsent,
                telemetryEnabled: configuration.telemetryEnabled
            ),
            SimulaProviderCoreConfiguration(
                apiKey: configuration.apiKey,
                devMode: configuration.devMode,
                primaryUserID: "different-user",
                hasPrivacyConsent: configuration.hasPrivacyConsent,
                telemetryEnabled: configuration.telemetryEnabled
            ),
            SimulaProviderCoreConfiguration(
                apiKey: configuration.apiKey,
                devMode: configuration.devMode,
                primaryUserID: configuration.primaryUserID,
                hasPrivacyConsent: !configuration.hasPrivacyConsent,
                telemetryEnabled: configuration.telemetryEnabled
            ),
            SimulaProviderCoreConfiguration(
                apiKey: configuration.apiKey,
                devMode: configuration.devMode,
                primaryUserID: configuration.primaryUserID,
                hasPrivacyConsent: configuration.hasPrivacyConsent,
                telemetryEnabled: !configuration.telemetryEnabled
            ),
        ]

        withExtendedLifetime(provider) {
            for conflicting in conflicts {
                guard case .conflict = registry.resolve(conflicting) else {
                    return XCTFail("API key, PPID, consent, and telemetry differences must conflict")
                }
            }
        }
    }

    func testLivePPIDUpdateDoesNotChangeProviderMatchingConfiguration() {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let configuration = coreConfiguration()
        let provider = makeProvider(
            configuration: configuration,
            ownership: ownership,
            registry: registry
        )

        provider.telemetryIdentitySource.setPrimaryUserId("updated-user")

        XCTAssertEqual(provider.primaryUserID, "updated-user")
        guard case .adopt(let adopted) = registry.resolve(configuration) else {
            return XCTFail("a live PPID update must not change construction-time provider matching")
        }
        XCTAssertTrue(adopted === provider)
    }

    func testLivePPIDUpdateStillRejectsDifferentConstructionConfiguration() {
        let registry = ActiveSimulaProviderRegistry()
        let ownership = ProcessApiKeyOwnership()
        let configuration = coreConfiguration()
        let provider = makeProvider(
            configuration: configuration,
            ownership: ownership,
            registry: registry
        )
        provider.telemetryIdentitySource.setPrimaryUserId("updated-user")
        let different = SimulaProviderCoreConfiguration(
            apiKey: configuration.apiKey,
            devMode: configuration.devMode,
            primaryUserID: "different-initial-user",
            hasPrivacyConsent: configuration.hasPrivacyConsent,
            telemetryEnabled: configuration.telemetryEnabled
        )

        guard case .conflict = registry.resolve(different) else {
            return XCTFail("different construction-time PPIDs must remain incompatible")
        }
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
