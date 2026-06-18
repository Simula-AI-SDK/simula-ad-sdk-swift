import Foundation
import Network

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
    /// doesn't churn the buffer.
    /// `primaryUserIDProvider` is read live on every flush so a mid-session `updatePrimaryUserID`
    /// is honored, and it is additionally gated by the live consent snapshot.
    func initialize(apiKey: String, devMode: Bool, enabled: Bool, primaryUserIDProvider: @escaping @Sendable () -> String?) {
        lock.lock()
        if initialized { lock.unlock(); return }
        initialized = true
        lock.unlock()

        guard enabled else { return } // host opt-out: no manager is ever created

        // Start the connection-type monitor once; it caches the latest path so the flush reads it
        // without a synchronous reachability call. Best-effort — never throws.
        ConnectionTypeMonitor.shared.start()

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
            // Read the PPID live so a mid-session updatePrimaryUserID is honored.
            primaryUserIdProvider: { primaryUserIDProvider() },
            advertisingIdProvider: { SimulaPrivacy.shared.currentSnapshot.advertisingId },
            connectionTypeProvider: { ConnectionTypeMonitor.shared.current },
            diagnosticsProvider: { Telemetry.resolveDiagnostics() },
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

    func recordOperation(name: String, durationMs: Int, success: Bool, failureClass: String? = nil, breadcrumb: String? = nil) {
        current?.recordOperation(name: name, durationMs: durationMs, success: success, failureClass: failureClass, breadcrumb: breadcrumb)
    }

    func recordLifecycle(
        stage: String,
        adFormat: String? = nil,
        adUnitId: String? = nil,
        adId: String? = nil,
        serveId: String? = nil,
        durationMs: Int? = nil,
        errorCode: String? = nil,
        trigger: String? = nil,
        cacheSource: String? = nil
    ) {
        current?.recordLifecycle(
            stage: stage, adFormat: adFormat, adUnitId: adUnitId, adId: adId,
            serveId: serveId, durationMs: durationMs, errorCode: errorCode,
            trigger: trigger, cacheSource: cacheSource
        )
    }

    func recordError(signature: String, errorCode: String? = nil, message: String? = nil, breadcrumb: String? = nil) {
        current?.recordError(signature: signature, errorCode: errorCode, message: message, breadcrumb: breadcrumb)
    }

    /// Persist + attempt delivery now (e.g. app background).
    func flush() { current?.flushNow() }

    /// Record the session's experiment assignment (server-driven) for the telemetry envelope.
    func setExperiment(experimentId: String?, variantId: String?) {
        current?.setExperiment(experimentId: experimentId, variantId: variantId)
    }

    /// Best-effort runtime diagnostics breadcrumb for the periodic `diagnostics` event: the process
    /// physical-memory footprint (MB). Wrapped so any failure yields nil (no event) and never throws.
    /// (WebView-pool / image-cache counts are omitted on iOS — those collections are main-actor /
    /// `NSCache`-isolated and can't be safely read from the background flush.)
    static func resolveDiagnostics() -> String? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let memMb = Int(info.phys_footprint) / (1024 * 1024)
        return "mem_used_mb=\(memMb)"
    }
}

/// Best-effort connection-class monitor for the telemetry envelope's `connection_type`. An
/// `NWPathMonitor` runs once and caches the latest class (`wifi` / `cellular` / `none` / `unknown`),
/// so the flush reads a cached value rather than making a synchronous reachability call. All access
/// is lock-guarded; failures degrade to `unknown` and never throw.
final class ConnectionTypeMonitor: @unchecked Sendable {
    static let shared = ConnectionTypeMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ad.simula.telemetry.netpath", qos: .utility)
    private let lock = NSLock()
    private var latest = "unknown"
    private var started = false

    private init() {}

    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            let type: String
            if path.status != .satisfied {
                type = "none"
            } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                type = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                type = "cellular"
            } else {
                type = "unknown"
            }
            self?.set(type)
        }
        monitor.start(queue: queue)
    }

    private func set(_ type: String) { lock.lock(); latest = type; lock.unlock() }

    var current: String { lock.lock(); defer { lock.unlock() }; return latest }
}
