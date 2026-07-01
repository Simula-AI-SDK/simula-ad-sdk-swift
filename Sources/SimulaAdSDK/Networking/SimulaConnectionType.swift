import Foundation
import Network
#if os(iOS)
import CoreTelephony
#endif

/// Live network-connection-type signal for the `X-Connection-Type` request header (OpenRTB
/// `device.connectiontype` enum) and the telemetry envelope's `connection_type` label.
///
/// One `NWPathMonitor` runs for the life of the process — started once from `SimulaProvider.init`,
/// **independent of the telemetry opt-out** — and caches the latest classification, so every
/// request reads a cached value with zero syscalls on the ad path. A network change (e.g.
/// Wi-Fi → cellular) updates the cache via `pathUpdateHandler`, so the very next request carries
/// the new value.
///
/// OpenRTB `connectiontype`: `0` unknown/offline · `1` wired · `2` wifi · `3` cellular (unknown
/// gen) · `4` 2G · `5` 3G · `6` 4G · `7` 5G.
///
/// `@unchecked Sendable` is safe: the only mutable state (`latestValue`/`latestLabel`/`started`)
/// is guarded by `lock`.
final class SimulaConnectionType: @unchecked Sendable {
    static let shared = SimulaConnectionType()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ad.simula.network.connectiontype", qos: .utility)
    private let lock = NSLock()
    private var latestValue = 0
    private var latestLabel = "unknown"
    private var started = false

    private init() {}

    /// Starts the monitor (idempotent — safe to call from `SimulaProvider.init` on every
    /// re-init). Cheap; the OS delivers the current path shortly after `start(queue:)`, so
    /// `current`/`label` self-correct from `0`/`unknown` within milliseconds.
    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(for: path)
        }
        monitor.start(queue: queue)
    }

    /// The current OpenRTB `connectiontype` value. `0` (unknown/offline) until the first path
    /// update lands (shortly after `start()`) — the very first request may go without a
    /// meaningful value, exactly like `X-Device-Id` before it resolves.
    var current: Int { lock.lock(); defer { lock.unlock() }; return latestValue }

    /// The current coarse label (`wifi` / `cellular` / `none` / `unknown`) for the telemetry
    /// envelope's `connection_type` field — kept in lockstep with `current`.
    var label: String { lock.lock(); defer { lock.unlock() }; return latestLabel }

    private func update(for path: NWPath) {
        let (value, label) = Self.classify(
            satisfied: path.status == .satisfied,
            isWifi: path.usesInterfaceType(.wifi),
            isWiredEthernet: path.usesInterfaceType(.wiredEthernet),
            isCellular: path.usesInterfaceType(.cellular),
            cellularGeneration: Self.cellularGeneration()
        )
        lock.lock()
        latestValue = value
        latestLabel = label
        lock.unlock()
    }

    /// Pure classification — testable without a live `NWPath`. `cellularGeneration` is an
    /// autoclosure so the (only-relevant-when-cellular) CoreTelephony read is skipped on
    /// wifi/wired/offline paths.
    static func classify(
        satisfied: Bool,
        isWifi: Bool,
        isWiredEthernet: Bool,
        isCellular: Bool,
        cellularGeneration: @autoclosure () -> Int
    ) -> (value: Int, label: String) {
        guard satisfied else { return (0, "none") }
        if isWifi { return (2, "wifi") }
        // Grouped under the "wifi" label for telemetry continuity (matches the pre-existing
        // `ConnectionTypeMonitor` behavior); the OpenRTB value still distinguishes wired (1) from wifi (2).
        if isWiredEthernet { return (1, "wifi") }
        if isCellular { return (cellularGeneration(), "cellular") }
        return (0, "unknown")
    }

    /// Refines a cellular connection to its OpenRTB generation (4-7) via CoreTelephony's
    /// `serviceCurrentRadioAccessTechnology` — no permission required, so iOS can report the
    /// full range. Falls back to `3` (cellular, unknown gen) when undeterminable. Best-effort:
    /// CoreTelephony never throws here, so this can't crash the host.
    private static func cellularGeneration() -> Int {
        #if os(iOS)
        let info = CTTelephonyNetworkInfo()
        guard let techs = info.serviceCurrentRadioAccessTechnology, !techs.isEmpty else { return 3 }
        // On dual-SIM, report the DATA SIM's radio (the service network requests actually use);
        // fall back to any service when the data service id is unknown.
        guard let tech = info.dataServiceIdentifier.flatMap({ techs[$0] }) ?? techs.values.first else {
            return 3
        }
        return generation(forRadioAccessTechnology: tech)
        #else
        return 3
        #endif
    }

    #if os(iOS)
    /// Pure mapping from a `CTRadioAccessTechnology*` constant to its OpenRTB generation,
    /// factored out so it's unit-testable without a live `CTTelephonyNetworkInfo`.
    static func generation(forRadioAccessTechnology tech: String) -> Int {
        if #available(iOS 14.1, *) {
            if tech == CTRadioAccessTechnologyNR || tech == CTRadioAccessTechnologyNRNSA { return 7 }
        }
        switch tech {
        case CTRadioAccessTechnologyLTE:
            return 6
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
            return 5
        case CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyCDMA1x:
            return 4
        default:
            return 3
        }
    }
    #endif
}
