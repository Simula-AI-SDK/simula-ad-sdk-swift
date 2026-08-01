import Foundation
#if os(iOS)
import UIKit
import AVFoundation
import os
#endif

/// Device-context signals attached as individual `X-*` headers to every first-party Simula API +
/// telemetry request (merged in at `SimulaAPI.makeHeaders`):
///
/// - `X-Timezone` — IANA time-zone id.
/// - `X-Memory-Free` — memory available to the process (`os_proc_available_memory`).
/// - `X-Battery-Level` — 0–100 (omitted when unknown).
/// - `X-Battery-State` — `charging` | `full` | `unplugged` | `unknown`.
/// - `X-Volume` — 0–100 output volume (ads tend to perform better with audio).
///
/// iOS exposes no public silent-switch API, so there is no `X-Ringer-Mode` header here (Android
/// only); output volume is still sent.
///
/// There is deliberately no `X-Storage-Free` header on iOS (Android only): every free-disk-space API
/// (`volumeAvailableCapacity*`, `statfs`, …) is on Apple's Disk Space required-reason list, and none
/// of the approved reasons permit sending the value off-device, so it cannot be collected here.
///
/// Performance: the request path only ever reads a pre-built cached dictionary (`headers()`) — no
/// syscalls, never blocks. The snapshot is computed off the main thread at `start()` and refreshed
/// lazily on a short TTL with a single-flight guard. Mirrors `SimulaConnectionType`.
///
/// Crash-free: every device read is individually guarded and omitted on failure, so a signal can
/// never throw into the host or the request. No new permissions, no third-party dependencies.
///
/// `@unchecked Sendable` is safe: all mutable state is guarded by `lock`.
final class SimulaDeviceSignals: @unchecked Sendable {
    static let shared = SimulaDeviceSignals()

    /// How long a computed snapshot is served before a background refresh is triggered.
    private static let ttl: TimeInterval = 10

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ad.simula.network.devicesignals", qos: .utility)
    private var snapshot: [String: String] = [:]
    private var computedAt: Date = .distantPast
    private var started = false
    private var refreshing = false

    private init() {}

    /// Starts signal collection (idempotent — safe to call from `SimulaProvider.init` /
    /// `SimulaAds.initialize` on every re-init). Enables battery monitoring on the main thread
    /// (iOS) and computes the first snapshot off-thread. Until it completes `headers()` is empty and
    /// the signals are simply omitted — the same first-request contract as `X-Device-Id`.
    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        #if os(iOS)
        // Battery reads go through BatteryMonitor's MAIN-thread snapshot (AGENTS.md hard rule:
        // UIDevice battery APIs are main-thread-only — this class reads them on a utility
        // queue). The monitor self-hops to main and enables monitoring itself; idempotent.
        BatteryMonitor.shared.start()
        #endif

        launchRefresh()
    }

    /// The current signals as request headers. O(1) read of the cached snapshot; if it is older than
    /// the TTL a single background refresh is dispatched (never blocking the caller) so the *next*
    /// request picks up fresher values.
    func headers() -> [String: String] {
        lock.lock()
        let current = snapshot
        let stale = started && Date().timeIntervalSince(computedAt) > Self.ttl
        lock.unlock()

        if stale { launchRefresh() }
        return current
    }

    /// Dispatch a snapshot refresh at most once at a time. The `refreshing` guard is acquired here
    /// and released only when that same dispatched `refresh()` completes — so a `start()`-time
    /// refresh and a TTL-driven refresh from `headers()` can never overlap or clear each other's flag.
    private func launchRefresh() {
        lock.lock()
        if refreshing { lock.unlock(); return }
        refreshing = true
        lock.unlock()
        queue.async { [weak self] in self?.refresh() }
    }

    /// Recompute the snapshot from live device state. Runs off the main thread (on `queue`).
    private func refresh() {
        let built = Self.buildHeaders(
            timezone: TimeZone.current.identifier,
            memoryFreeBytes: Self.availableMemoryBytes(),
            batteryLevel: Self.currentBatteryLevel(),
            batteryStateRaw: Self.currentBatteryStateRaw(),
            outputVolume: Self.currentOutputVolume()
        )
        lock.lock()
        snapshot = built
        computedAt = Date()
        refreshing = false
        lock.unlock()
    }

    // MARK: - Device reads (guarded, platform-specific)

    private static func availableMemoryBytes() -> Int64? {
        #if os(iOS)
        return Int64(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    private static func currentBatteryLevel() -> Float? {
        #if os(iOS)
        // Main-thread snapshot via BatteryMonitor — never UIDevice off-main (AGENTS.md rule).
        guard let info = BatteryMonitor.shared.current else { return nil }
        return Float(info.level)
        #else
        return nil
        #endif
    }

    private static func currentBatteryStateRaw() -> Int? {
        #if os(iOS)
        return BatteryMonitor.shared.current?.stateRaw
        #else
        return nil
        #endif
    }

    private static func currentOutputVolume() -> Float? {
        #if os(iOS)
        return AVAudioSession.sharedInstance().outputVolume
        #else
        return nil
        #endif
    }

    // MARK: - Pure mappers (unit-testable on any platform)

    /// Output/media volume (0.0–1.0) as a 0–100 percentage; nil when unreadable/out of range.
    static func volumePercent(_ volume: Float?) -> Int? {
        guard let volume, volume.isFinite, volume >= 0 else { return nil }
        return min(max(Int((volume * 100).rounded()), 0), 100)
    }

    /// Battery level (0.0–1.0, or `-1` when unknown) as a 0–100 percentage; nil when unknown.
    static func batteryPercent(_ level: Float?) -> Int? {
        guard let level, level.isFinite, level >= 0 else { return nil }
        return min(max(Int((level * 100).rounded()), 0), 100)
    }

    /// Maps a `UIDevice.BatteryState.rawValue` (unknown=0, unplugged=1, charging=2, full=3) to a
    /// stable label; nil for any unexpected value.
    static func batteryStateLabel(_ raw: Int?) -> String? {
        switch raw {
        case 0: return "unknown"
        case 1: return "unplugged"
        case 2: return "charging"
        case 3: return "full"
        default: return nil
        }
    }

    /// Assembles the header map from raw signal values, omitting any that are unavailable. Pure.
    static func buildHeaders(
        timezone: String?,
        memoryFreeBytes: Int64?,
        batteryLevel: Float?,
        batteryStateRaw: Int?,
        outputVolume: Float?
    ) -> [String: String] {
        var headers: [String: String] = [:]
        if let timezone, !timezone.isEmpty { headers["X-Timezone"] = timezone }
        if let memoryFreeBytes, memoryFreeBytes >= 0 { headers["X-Memory-Free"] = String(memoryFreeBytes) }
        if let level = batteryPercent(batteryLevel) { headers["X-Battery-Level"] = String(level) }
        if let state = batteryStateLabel(batteryStateRaw) { headers["X-Battery-State"] = state }
        if let volume = volumePercent(outputVolume) { headers["X-Volume"] = String(volume) }
        return headers
    }
}
