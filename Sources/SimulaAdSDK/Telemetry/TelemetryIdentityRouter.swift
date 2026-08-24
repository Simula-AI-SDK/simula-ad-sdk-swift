import Foundation

/// One coherent envelope identity resolved live at telemetry flush time.
struct TelemetryIdentity: Equatable, Sendable {
    let sessionId: String?
    let primaryUserId: String?
    let advertisingId: String?

    init(sessionId: String?, primaryUserId: String?, advertisingId: String? = nil) {
        self.sessionId = sessionId
        self.primaryUserId = primaryUserId
        self.advertisingId = advertisingId
    }
}

/// Stable lifetime key for one provider without retaining the provider itself.
struct TelemetryProviderIdentityToken: Hashable, Sendable {
    private let value = UUID()
}

/// Small provider-owned identity holder. It intentionally retains no provider or UI object.
final class TelemetryIdentitySource: @unchecked Sendable {
    let apiKey: String
    private let lock = NSLock()
    private var value: TelemetryIdentity

    init(apiKey: String, sessionId: String? = nil, primaryUserId: String?) {
        self.apiKey = apiKey
        value = TelemetryIdentity(sessionId: sessionId, primaryUserId: primaryUserId)
    }

    func identity() -> TelemetryIdentity {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func setSessionId(_ sessionId: String?) {
        lock.lock()
        value = TelemetryIdentity(
            sessionId: sessionId,
            primaryUserId: value.primaryUserId,
            advertisingId: value.advertisingId
        )
        lock.unlock()
    }

    func setPrimaryUserId(_ primaryUserId: String?) {
        lock.lock()
        value = TelemetryIdentity(
            sessionId: value.sessionId,
            primaryUserId: primaryUserId,
            advertisingId: value.advertisingId
        )
        lock.unlock()
    }

    func setIdentity(sessionId: String?, primaryUserId: String?) {
        lock.lock()
        value = TelemetryIdentity(sessionId: sessionId, primaryUserId: primaryUserId)
        lock.unlock()
    }
}

/// Routes process telemetry identity without retaining a host entry point. A matching imperative
/// source wins; otherwise the latest matching provider whose startup committed supplies identity.
final class TelemetryIdentityRouter: @unchecked Sendable {
    private struct ProviderBinding {
        let token: TelemetryProviderIdentityToken
        let source: TelemetryIdentitySource
    }

    private let lock = NSLock()
    private var providerBindings: [ProviderBinding] = []
    private var imperativeSource: TelemetryIdentitySource?

    func bindProvider(token: TelemetryProviderIdentityToken, source: TelemetryIdentitySource) {
        lock.lock()
        if let index = providerBindings.firstIndex(where: { $0.token == token }) {
            providerBindings[index] = ProviderBinding(token: token, source: source)
        } else {
            providerBindings.append(ProviderBinding(token: token, source: source))
        }
        lock.unlock()
    }

    func unbindProvider(_ token: TelemetryProviderIdentityToken) {
        lock.lock()
        providerBindings.removeAll { $0.token == token }
        lock.unlock()
    }

    func bindImperative(_ source: TelemetryIdentitySource) {
        lock.lock(); imperativeSource = source; lock.unlock()
    }

    func identity(apiKey: String) -> TelemetryIdentity {
        lock.lock()
        let source: TelemetryIdentitySource?
        if imperativeSource?.apiKey == apiKey {
            source = imperativeSource
        } else {
            source = providerBindings.last { $0.source.apiKey == apiKey }?.source
        }
        lock.unlock()
        return source?.identity() ?? TelemetryIdentity(sessionId: nil, primaryUserId: nil)
    }
}

let processTelemetryIdentityRouter = TelemetryIdentityRouter()
