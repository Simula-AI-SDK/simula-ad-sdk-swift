import Foundation

struct SimulaProviderCoreConfiguration: Equatable, Sendable {
    let apiKey: String
    let devMode: Bool
    let primaryUserID: String?
    let hasPrivacyConsent: Bool
    let telemetryEnabled: Bool
}

struct ActiveSimulaProviderToken: Hashable, Sendable {
    private let value = UUID()
}

enum ActiveSimulaProviderResolution {
    case none
    case adopt(SimulaProvider)
    case conflict
}

/// Process registry of constructed providers. Bindings are weak so speculative/nested SwiftUI
/// providers never become process-lifetime UI roots; registration order makes the latest live
/// provider deterministic and removing it restores the previous provider.
final class ActiveSimulaProviderRegistry: @unchecked Sendable {
    private final class Binding {
        let token: ActiveSimulaProviderToken
        weak var provider: SimulaProvider?

        init(token: ActiveSimulaProviderToken, provider: SimulaProvider) {
            self.token = token
            self.provider = provider
        }
    }

    private let lock = NSLock()
    private var bindings: [Binding] = []

    func register(token: ActiveSimulaProviderToken, provider: SimulaProvider) {
        lock.lock()
        bindings.removeAll { $0.provider == nil || $0.token == token }
        bindings.append(Binding(token: token, provider: provider))
        lock.unlock()
    }

    func unregister(_ token: ActiveSimulaProviderToken) {
        lock.lock()
        bindings.removeAll { $0.provider == nil || $0.token == token }
        lock.unlock()
    }

    func resolve(_ configuration: SimulaProviderCoreConfiguration) -> ActiveSimulaProviderResolution {
        lock.lock()
        bindings.removeAll { $0.provider == nil }
        let provider = bindings.last?.provider
        lock.unlock()

        guard let provider else { return .none }
        return provider.matchesCoreConfiguration(configuration) ? .adopt(provider) : .conflict
    }
}

let processActiveSimulaProviderRegistry = ActiveSimulaProviderRegistry()

func selectSimulaProvider(
    shared: SimulaProvider?,
    configuration: SimulaProviderCoreConfiguration,
    create: () -> SimulaProvider
) -> SimulaProvider {
    guard let shared, shared.matchesCoreConfiguration(configuration) else { return create() }
    return shared
}
