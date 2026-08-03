#if os(iOS)
import Foundation

/// Imperative one-at-a-time preload registry behind `SimulaAds.preloadNativeAd` /
/// `SimulaAds.destroyPreloadedAd`.
///
/// Each `preload` fires exactly one `POST /load/native` (using the current provider context +
/// session) into a held `Task`, and returns a `preloadedAdId`. When a `NativeAdSlot` mounts with
/// that id it `consume`s the entry — rendering from cache with no live network call — and the entry
/// is evicted. Unconsumed ids must be released with `destroy`.
///
/// At most `maxEntries` ads are kept at once; further preloads are dropped (PRD: "cap silently at 5")
/// with sampled telemetry. MainActor-isolated: everything runs on the main thread, matching the
/// rest of the imperative ad path.
@MainActor
final class NativeAdPreloadCache {
    static let shared = NativeAdPreloadCache()

    private let maxEntries = 5
    private var tasks: [String: Task<NativeAdResponse, Error>] = [:]

    private init() {}

    /// Fire one preload and return its id, or nil if the cap is already reached. `theme` is resolved
    /// here (imperative context → `UITraitCollection`) since there's no SwiftUI environment.
    func preload(provider: SimulaProvider, adUnitId: String?, position: Int, theme: String?) -> String? {
        guard tasks.count < maxEntries else {
            Telemetry.shared.recordOperation(name: "native_preload_capped", durationMs: 0, success: false)
            return nil
        }
        let resolvedTheme = NativeAdTheme.resolve(theme, isDark: NativeAdTheme.systemIsDark)
        let id = UUID().uuidString
        // Single-call task closure — see the task-shape note in TelemetryManager.
        tasks[id] = Task { @MainActor in try await NativeAdController.load(provider: provider, adUnitId: adUnitId, position: position, theme: resolvedTheme) }
        return id
    }

    /// Await and remove the preloaded ad for `id`. Returns nil if the id is unknown (expired,
    /// destroyed, already consumed) or its load failed — the caller then falls back to a live
    /// request, surfacing no error (PRD).
    func consume(_ id: String) async -> NativeAdResponse? {
        guard let task = tasks.removeValue(forKey: id) else { return nil }
        // do/catch, not `try?` around an await — see the task-shape note in TelemetryManager.
        do { return try await task.value } catch { return nil }
    }

    /// Release a preloaded ad that was never consumed, cancelling its request if still in flight.
    func destroy(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
    }
}
#endif
