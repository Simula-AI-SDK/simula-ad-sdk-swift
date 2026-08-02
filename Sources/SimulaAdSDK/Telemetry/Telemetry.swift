import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import CoreTelephony
#endif

/// SDK version stamped on every telemetry batch. Keep in sync with `SimulaAdSDK.podspec`
/// (`s.version`) and the SPM release tag.
let SIMULA_SDK_VERSION = "1.1.7"

/// Process-wide facade for in-house telemetry (handled errors + performance), mirroring the
/// singleton style of `SimulaPrivacy` / `RewardVerificationManager`. All record calls are cheap
/// no-ops until `initialize` installs a `TelemetryManager`, and a true no-op forever when the
/// host opts out (`telemetryEnabled = false`) — the lowest-overhead path.
///
/// The manager is decoupled from the network layer: `TelemetryURLSessionDelegate` and the ad
/// lifecycle just call these methods; this object owns the device context + live-read PII
/// wiring. `@unchecked Sendable` is safe — the single mutable reference is guarded by `lock`.
final class Telemetry: @unchecked Sendable {
    static let shared = Telemetry()

    private let lock = NSLock()
    private var manager: TelemetryManager?
    private var initialized = false
    /// True only when the first-wins install explicitly opted telemetry out. Distinguishes
    /// "install in progress" (buffer errors) from "disabled forever" (drop them cheaply).
    private var disabled = false
    /// Errors recorded before `initialize` installs the pipeline (e.g. `SimulaAds.initialize`
    /// rejecting an invalid API key). Without the buffer those calls vanished silently — the
    /// exact misconfiguration feedback an integrator needs. Bounded; drained once on install
    /// (and dropped forever on a host opt-out, since no manager is ever created).
    private var preInstallErrors: [(signature: String, errorCode: String?, message: String?, breadcrumb: String?, stack: [String]?)] = []
    private let maxPreInstallErrors = 10
    /// Non-error events can also race the deferred manager construction after `initialized` flips.
    /// Keep a small bounded replay list so those events are delivered without making pre-init
    /// telemetry an unbounded lifetime buffer.
    private var preInstallEvents: [@Sendable (TelemetryManager) -> Void] = []
    private let maxPreInstallEvents = 20
    /// A did-enter-background request received after initialization begins but before persisted
    /// recovery publishes the manager. The hook coalesces notifications, so one slot is sufficient.
    private var pendingBackgroundFlush: BackgroundFlushRequest?

    init(installBackgroundObserver: Bool = true) {
        #if canImport(UIKit)
        if installBackgroundObserver { installBackgroundFlushObserver() }
        #endif
    }

    /// Install the telemetry pipeline. Called once from `SimulaProvider.init` (the choke point
    /// both the imperative and declarative entry points funnel through). First call wins, so the
    /// host's `telemetryEnabled` choice sticks and `SimulaProviderView` recreating a provider
    /// doesn't churn the buffer.
    /// `primaryUserIDProvider` is read live on every flush so a mid-session `updatePrimaryUserID`
    /// is honored. Note the PPID is NOT consent-gated in the telemetry pipeline today —
    /// consent/COPPA gating applies to the advertising id only (see `SimulaPrivacy`). Suppressing
    /// the PPID without consent would also have to cover `/session/create` and the ppid PATCH,
    /// which is a pending product/privacy decision, not a telemetry-local change.
    func initialize(apiKey: String, devMode: Bool, enabled: Bool, primaryUserIDProvider: @escaping @Sendable () -> String?) {
        lock.lock()
        if initialized { lock.unlock(); return }
        initialized = true
        if !enabled {
            disabled = true
            preInstallErrors.removeAll()
            preInstallEvents.removeAll()
            lock.unlock()
            return
        }
        lock.unlock()

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
        completeInstallation(with: mgr)
    }

    /// Completes persisted recovery synchronously on `runStartupPrewarm`'s off-main executor,
    /// publishes/replays, then schedules only network delivery asynchronously. `initialize` does
    /// not return until the manager is live, so the first request can safely apply session/config.
    func completeInstallation(with mgr: TelemetryManager) {
        mgr.recoverPersistedEvents()
        publishRecoveredManager(mgr)
        mgr.flushAsync()
    }

    private func publishRecoveredManager(_ mgr: TelemetryManager) {
        lock.lock()
        manager = mgr
        let events = preInstallEvents
        preInstallEvents.removeAll()
        let pending = preInstallErrors
        preInstallErrors.removeAll()
        let backgroundRequest = pendingBackgroundFlush
        pendingBackgroundFlush = nil
        lock.unlock()
        for replay in events { replay(mgr) }
        for error in pending {
            mgr.recordError(signature: error.signature, errorCode: error.errorCode, message: error.message, breadcrumb: error.breadcrumb, stack: error.stack)
        }
        if let backgroundRequest, !backgroundRequest.isFinished {
            mgr.flushNow { backgroundRequest.finish() }
        }
    }

    /// Opens the same manager-construction window as `initialize`, without constructing production
    /// collaborators. Used only by tests of the bounded non-error replay behavior.
    func beginInstallationForTesting() {
        lock.lock(); initialized = true; lock.unlock()
    }

    #if canImport(UIKit)
    /// Installed when the facade is created, before deferred manager construction can begin. The
    /// observer itself is cheap; UIKit work happens only when the lifecycle notification fires.
    private func installBackgroundFlushObserver() {
        TelemetryBackgroundFlush.shared.install(
            name: UIApplication.didEnterBackgroundNotification,
            beginBackgroundTask: { expiration in
                TelemetryBackgroundFlush.beginUIKitBackgroundTask(expirationHandler: expiration)
            }
        ) { [weak self] request in
            DispatchQueue.global(qos: .utility).async {
                guard let self else { request.finish(); return }
                self.requestBackgroundFlush(request)
            }
        }
    }
    #endif

    /// Defers one background request while recovery is in progress. Once a recovered manager is
    /// published, `flushNow` joins any active send and finishes the request after that send/drain.
    func requestBackgroundFlush(_ request: BackgroundFlushRequest) {
        lock.lock()
        let currentManager = manager
        var finishWithoutFlush = false
        if currentManager == nil, initialized, !disabled, !request.isFinished {
            if pendingBackgroundFlush == nil {
                pendingBackgroundFlush = request
            } else {
                finishWithoutFlush = true
            }
        } else if currentManager == nil {
            finishWithoutFlush = true
        }
        lock.unlock()

        if let currentManager {
            currentManager.flushNow { request.finish() }
        } else if finishWithoutFlush {
            request.finish()
        }
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
        bufferOrRecord { manager in
            manager.recordNetwork(
                path: path, method: method, statusCode: statusCode, durationMs: durationMs,
                requestBytes: requestBytes, responseBytes: responseBytes, failureClass: failureClass
            )
        }
    }

    func recordOperation(name: String, durationMs: Int, success: Bool, failureClass: String? = nil, breadcrumb: String? = nil) {
        bufferOrRecord { manager in
            manager.recordOperation(
                name: name, durationMs: durationMs, success: success,
                failureClass: failureClass, breadcrumb: breadcrumb
            )
        }
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
        bufferOrRecord { manager in
            manager.recordLifecycle(
                stage: stage, adFormat: adFormat, adUnitId: adUnitId, adId: adId,
                serveId: serveId, durationMs: durationMs, errorCode: errorCode,
                trigger: trigger, cacheSource: cacheSource, breadcrumb: breadcrumb
            )
        }
    }

    private func bufferOrRecord(_ replay: @escaping @Sendable (TelemetryManager) -> Void) {
        lock.lock()
        let currentManager = manager
        if currentManager == nil, initialized, !disabled,
           preInstallEvents.count < maxPreInstallEvents {
            preInstallEvents.append(replay)
        }
        lock.unlock()
        if let currentManager { replay(currentManager) }
    }

    func recordError(signature: String, errorCode: String? = nil, message: String? = nil, breadcrumb: String? = nil, stack: [String]? = nil) {
        lock.lock()
        let currentManager = manager
        if currentManager == nil, !disabled, preInstallErrors.count < maxPreInstallErrors {
            // Pre-install OR install-in-progress (e.g. an invalid-API-key `initialize` racing
            // the manager build): buffer instead of dropping — drained once install completes.
            // An explicit host opt-out sets `disabled`, keeping this a permanent no-op.
            preInstallErrors.append((signature, errorCode, message, breadcrumb, stack))
        }
        lock.unlock()
        currentManager?.recordError(signature: signature, errorCode: errorCode, message: message, breadcrumb: breadcrumb, stack: stack)
    }

    /// Persist + attempt delivery now (e.g. app background).
    func flush(completion: (@Sendable () -> Void)? = nil) {
        let request = BackgroundFlushRequest(onFinish: completion ?? {})
        requestBackgroundFlush(request)
    }

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
    private var snapshot: BatteryInfo?
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
        let level = device.batteryLevel
        let stateRaw = device.batteryState.rawValue
        let charging = device.batteryState == .charging || device.batteryState == .full
        let snap = level >= 0 ? BatteryInfo(level: Double(level), charging: charging, stateRaw: stateRaw) : nil
        lock.lock(); snapshot = snap; lock.unlock()
    }

    var current: BatteryInfo? {
        lock.lock(); defer { lock.unlock() }; return snapshot
    }
}
#endif
