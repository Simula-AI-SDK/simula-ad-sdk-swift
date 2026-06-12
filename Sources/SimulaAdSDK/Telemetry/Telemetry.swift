import Foundation

/// SDK version stamped on every telemetry batch. Keep in sync with `SimulaAdSDK.podspec`
/// (`s.version`) and the SPM release tag.
let SIMULA_SDK_VERSION = "1.1.0"

/// Process-wide facade for in-house telemetry (handled errors + performance), mirroring the
/// singleton style of `SimulaPrivacy` / `RewardVerificationManager`. All record calls are cheap
/// no-ops until `initialize` installs a `TelemetryManager`, and a true no-op forever when the
/// host opts out (`telemetryEnabled = false`) — the lowest-overhead path.
///
/// The manager is decoupled from the network layer: `TelemetryURLSessionDelegate` and the ad
/// lifecycle just call these methods; this object owns the device context + consent-gated PII
/// wiring. `@unchecked Sendable` is safe — the single mutable reference is guarded by `lock`.
final class Telemetry: @unchecked Sendable {
    static let shared = Telemetry()

    private let lock = NSLock()
    private var manager: TelemetryManager?
    private var initialized = false

    private init() {}

    /// Install the telemetry pipeline. Called once from `SimulaProvider.init` (the choke point
    /// both the imperative and declarative entry points funnel through). First call wins, so the
    /// host's `telemetryEnabled` choice sticks and `SimulaProviderView` recreating a provider
    /// doesn't churn the buffer. `primaryUserID` is gated dynamically by the live consent snapshot.
    func initialize(apiKey: String, devMode: Bool, enabled: Bool, primaryUserID: String?) {
        lock.lock()
        if initialized { lock.unlock(); return }
        initialized = true
        lock.unlock()

        guard enabled else { return } // host opt-out: no manager is ever created

        let ctx = TelemetryContext(
            sdkVersion: SIMULA_SDK_VERSION,
            osVersion: DeviceCapabilities.current.osVersion,
            deviceModel: SimulaUserAgent.deviceModelIdentifier(),
            hostAppId: Bundle.main.bundleIdentifier ?? "unknown",
            devMode: devMode
        )
        // In dev mode, mirror every (redacted) event to the console for local verification.
        var consoleLog: (@Sendable (String) -> Void)?
        if devMode { consoleLog = { line in print("[SimulaTelemetry] \(line)") } }
        let mgr = TelemetryManager(
            ctx: ctx,
            store: UserDefaultsTelemetryStore(),
            sender: ApiTelemetrySender(apiKey: apiKey),
            // Re-gate on every flush: ppid only with consent (& not under COPPA); the advertising
            // id is already nil'd by the snapshot when not collectible.
            primaryUserIdProvider: { SimulaPrivacy.shared.currentSnapshot.allowsPrimaryUserID ? primaryUserID : nil },
            advertisingIdProvider: { SimulaPrivacy.shared.currentSnapshot.advertisingId },
            debugLog: consoleLog
        )
        lock.lock(); manager = mgr; lock.unlock()
        mgr.start()
    }

    private var current: TelemetryManager? {
        lock.lock(); defer { lock.unlock() }; return manager
    }

    /// Push the live session id (from `SimulaProvider`) so telemetry batches can be correlated.
    func setSessionId(_ id: String?) { current?.setSessionId(id) }

    /// Apply a server-side directive (kill-switch / sampling) from `/session/create`.
    func applyServerConfig(enabled: Bool, sampleRate: Double) {
        current?.applyServerConfig(enabled: enabled, sampleRate: sampleRate)
    }

    func recordNetwork(
        path: String,
        method: String,
        statusCode: Int?,
        durationMs: Int,
        requestBytes: Int64,
        responseBytes: Int64,
        failureClass: String?
    ) {
        current?.recordNetwork(
            path: path, method: method, statusCode: statusCode, durationMs: durationMs,
            requestBytes: requestBytes, responseBytes: responseBytes, failureClass: failureClass
        )
    }

    func recordOperation(name: String, durationMs: Int, success: Bool) {
        current?.recordOperation(name: name, durationMs: durationMs, success: success)
    }

    func recordLifecycle(
        stage: String,
        adFormat: String? = nil,
        adUnitId: String? = nil,
        adId: String? = nil,
        serveId: String? = nil,
        durationMs: Int? = nil,
        errorCode: String? = nil
    ) {
        current?.recordLifecycle(
            stage: stage, adFormat: adFormat, adUnitId: adUnitId, adId: adId,
            serveId: serveId, durationMs: durationMs, errorCode: errorCode
        )
    }

    func recordError(signature: String, errorCode: String? = nil, message: String? = nil, breadcrumb: String? = nil) {
        current?.recordError(signature: signature, errorCode: errorCode, message: message, breadcrumb: breadcrumb)
    }

    /// Persist + attempt delivery now (e.g. app background).
    func flush() { current?.flushNow() }
}
