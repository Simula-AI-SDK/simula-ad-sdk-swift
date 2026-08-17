import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import CoreTelephony
#endif

/// SDK version stamped on every telemetry batch. Keep in sync with `SimulaAdSDK.podspec`
/// (`s.version`) and the SPM release tag.
let SIMULA_SDK_VERSION = "1.1.9-dev.4"

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

        // `SimulaConnectionType` is started independently (from `SimulaProvider.init`, ahead of
        // telemetry install) since the `X-Connection-Type` header must work even when telemetry is
        // disabled. No separate monitor here — the flush just reads its cached label below.
        #if canImport(UIKit)
        // UIDevice battery APIs are main-thread-only; the monitor enables monitoring + caches
        // level/state on the main thread so the (background) flush reads a snapshot, never UIDevice
        // off-main.
        BatteryMonitor.shared.start()
        #endif

        let ctx = TelemetryContext(
            sdkVersion: SIMULA_SDK_VERSION,
            osVersion: DeviceCapabilities.current.osVersion,
            deviceModel: SimulaUserAgent.deviceModelIdentifier(),
            hostAppId: Bundle.main.bundleIdentifier ?? "unknown",
            devMode: devMode,
            // Always-on device diagnostics, resolved once (constant per process).
            manufacturer: "Apple",
            locale: Telemetry.resolveLocale(),
            deviceRamMb: Telemetry.resolveRamMb(),
            buildType: Telemetry.resolveBuildType()
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
            connectionTypeProvider: { SimulaConnectionType.shared.label },
            diagnosticsProvider: { Telemetry.resolveDiagnostics() },
            batteryProvider: { Telemetry.resolveBattery() },
            carrierProvider: { Telemetry.resolveCarrier() },
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
        cacheSource: String? = nil,
        breadcrumb: String? = nil
    ) {
        current?.recordLifecycle(
            stage: stage, adFormat: adFormat, adUnitId: adUnitId, adId: adId,
            serveId: serveId, durationMs: durationMs, errorCode: errorCode,
            trigger: trigger, cacheSource: cacheSource, breadcrumb: breadcrumb
        )
    }

    func recordError(
        signature: String,
        errorCode: String? = nil,
        message: String? = nil,
        breadcrumb: String? = nil,
        stack: [String]? = nil,
        dedupeDiscriminator: String? = nil
    ) {
        current?.recordError(
            signature: signature,
            errorCode: errorCode,
            message: message,
            breadcrumb: breadcrumb,
            stack: stack,
            dedupeDiscriminator: dedupeDiscriminator
        )
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

    // MARK: - Always-on device diagnostics (resolved at init/flush; best-effort, never throw)

    /// Current locale as a BCP-47 tag (e.g. "en-US").
    static func resolveLocale() -> String? {
        let tag = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return tag.isEmpty ? nil : tag
    }

    /// Total physical RAM in MB.
    static func resolveRamMb() -> Int? {
        let mb = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        return mb > 0 ? mb : nil
    }

    /// The build configuration this SDK binary was compiled with.
    static func resolveBuildType() -> String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// Battery level (0..1) + charging, via UIDevice (monitoring enabled at init). nil off iOS or
    /// when the level is unknown.
    static func resolveBattery() -> BatteryInfo? {
        #if canImport(UIKit)
        return BatteryMonitor.shared.current  // main-thread snapshot; safe to read off-main
        #else
        return nil
        #endif
    }

    /// Carrier name is intentionally nil on iOS (CTCarrier is deprecated and returns placeholders on
    /// iOS 16+); only the non-deprecated radio-access type is reported.
    static func resolveCarrier() -> CarrierInfo? {
        guard let radio = resolveRadio() else { return nil }
        return CarrierInfo(carrier: nil, radio: radio)
    }

    /// Coarse generation label for the current data radio (5G/LTE/3G/2G), via CoreTelephony. nil on
    /// Wi-Fi-only, when undeterminable, or off iOS.
    static func resolveRadio() -> String? {
        #if os(iOS)
        let info = CTTelephonyNetworkInfo()
        guard let techs = info.serviceCurrentRadioAccessTechnology, !techs.isEmpty else { return nil }
        // On dual-SIM, report the DATA SIM's radio (the service network requests actually use);
        // fall back to any service when the data service id is unknown. `.values.first` alone
        // would pick an arbitrary SIM.
        guard let tech = info.dataServiceIdentifier.flatMap({ techs[$0] }) ?? techs.values.first else {
            return nil
        }
        return radioLabel(tech)
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private static func radioLabel(_ tech: String) -> String? {
        if #available(iOS 14.1, *) {
            if tech == CTRadioAccessTechnologyNR || tech == CTRadioAccessTechnologyNRNSA { return "5G" }
        }
        switch tech {
        case CTRadioAccessTechnologyLTE:
            return "LTE"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
            return "3G"
        case CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyCDMA1x:
            return "2G"
        default:
            return nil
        }
    }
    #endif
}

#if canImport(UIKit)
/// Caches the battery level/state, refreshed on the MAIN thread (UIDevice battery APIs are
/// main-thread-only), so the background telemetry flush reads a snapshot instead of touching
/// UIKit off-main. Mirrors `SimulaConnectionType`. Lock-guarded; nil until the first reading.
final class BatteryMonitor: @unchecked Sendable {
    static let shared = BatteryMonitor()

    private let lock = NSLock()
    private var snapshot: DeviceBatterySnapshot?
    private var started = false

    private init() {}

    func start() {
        // The monitoring toggle + UIDevice reads must happen on the main thread.
        if Thread.isMainThread {
            startOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in self?.startOnMain() }
        }
    }

    private func startOnMain() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        UIDevice.current.isBatteryMonitoringEnabled = true  // never disabled (a host may read it too)
        let center = NotificationCenter.default
        // Named `onChange` (not `refresh`) so it doesn't shadow the refresh() method below.
        let onChange: @Sendable (Notification) -> Void = { [weak self] _ in self?.refresh() }
        center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main, using: onChange)
        center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main, using: onChange)
        refresh()
    }

    /// Always invoked on the main queue (initial call from startOnMain + observers with queue: .main).
    private func refresh() {
        let device = UIDevice.current
        let snap = DeviceBatterySnapshot(
            level: device.batteryLevel,
            stateRaw: device.batteryState.rawValue
        )
        lock.lock(); snapshot = snap; lock.unlock()
    }

    var current: BatteryInfo? {
        DeviceBatterySnapshot.telemetryInfo(from: currentDeviceSnapshot)
    }

    var currentDeviceSnapshot: DeviceBatterySnapshot? {
        lock.lock(); defer { lock.unlock() }; return snapshot
    }
}
#endif
