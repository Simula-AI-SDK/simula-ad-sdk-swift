import Foundation

/// One coherent envelope identity resolved live at telemetry flush time.
struct TelemetryIdentity: Equatable, Sendable {
    let sessionId: String?
    let primaryUserId: String?
}

/// Stable lifetime key for one provider without retaining the provider itself.
struct TelemetryProviderIdentityToken: Hashable, Sendable {
    private let value = UUID()
}

/// Small provider-owned identity holder. It intentionally retains no provider or UI object.
final class TelemetryIdentitySource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TelemetryIdentity

    init(sessionId: String? = nil, primaryUserId: String?) {
        value = TelemetryIdentity(sessionId: sessionId, primaryUserId: primaryUserId)
    }

    func identity() -> TelemetryIdentity {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func setSessionId(_ sessionId: String?) {
        lock.lock()
        value = TelemetryIdentity(sessionId: sessionId, primaryUserId: value.primaryUserId)
        lock.unlock()
    }

    func setPrimaryUserId(_ primaryUserId: String?) {
        lock.lock()
        value = TelemetryIdentity(sessionId: value.sessionId, primaryUserId: primaryUserId)
        lock.unlock()
    }

    func setIdentity(sessionId: String?, primaryUserId: String?) {
        lock.lock()
        value = TelemetryIdentity(sessionId: sessionId, primaryUserId: primaryUserId)
        lock.unlock()
    }
}

/// Routes process telemetry identity without retaining the first host entry point. Once bound, the
/// imperative source wins; provider-only hosts follow the latest provider whose startup committed.
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
        providerBindings.removeAll { $0.token == token }
        providerBindings.append(ProviderBinding(token: token, source: source))
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

    func identity() -> TelemetryIdentity {
        lock.lock()
        let source = imperativeSource ?? providerBindings.last?.source
        lock.unlock()
        return source?.identity() ?? TelemetryIdentity(sessionId: nil, primaryUserId: nil)
    }
}

let processTelemetryIdentityRouter = TelemetryIdentityRouter()
