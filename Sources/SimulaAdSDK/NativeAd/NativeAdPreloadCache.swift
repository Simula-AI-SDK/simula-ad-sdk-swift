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

    typealias Loader = @MainActor (
        _ provider: SimulaProvider,
        _ adUnitId: String?,
        _ position: Int,
        _ theme: String?,
        _ metadata: [String: String]?
    ) async throws -> NativeAdResponse

    struct PreloadedNativeAd {
        let response: NativeAdResponse
        let metadata: [String: String]?
    }

    private struct Entry {
        let task: Task<NativeAdResponse, Error>
        let metadata: [String: String]?
    }

    private let maxEntries = 5
    private let loader: Loader
    private var entries: [String: Entry] = [:]

    init(loader: @escaping Loader = { provider, adUnitId, position, theme, metadata in
        try await NativeAdController.load(
            provider: provider,
            adUnitId: adUnitId,
            position: position,
            theme: theme,
            metadata: metadata
        )
    }) {
        self.loader = loader
    }

    /// Fire one preload and return its id, or nil if the cap is already reached. `theme` is resolved
    /// here (imperative context → `UITraitCollection`) since there's no SwiftUI environment.
    func preload(
        provider: SimulaProvider,
        adUnitId: String?,
        position: Int,
        theme: String?,
        metadata: [String: String]?
    ) -> String? {
        guard entries.count < maxEntries else {
            Telemetry.shared.recordOperation(name: "native_preload_capped", durationMs: 0, success: false)
            return nil
        }
        let metadataSnapshot = metadata.flatMap { normalizeExtraParameters($0) }
        let resolvedTheme = NativeAdTheme.resolve(theme, isDark: NativeAdTheme.systemIsDark)
        let id = UUID().uuidString
        // Single-call task closure — see the task-shape note in TelemetryManager.
        let task = Task { @MainActor in
            try await runLoad(
                provider: provider,
                adUnitId: adUnitId,
                position: position,
                theme: resolvedTheme,
                metadata: metadataSnapshot
            )
        }
        entries[id] = Entry(task: task, metadata: metadataSnapshot)
        return id
    }

    /// Named task entry point required by the optimizer-safe task-shape contract.
    private func runLoad(
        provider: SimulaProvider,
        adUnitId: String?,
        position: Int,
        theme: String?,
        metadata: [String: String]?
    ) async throws -> NativeAdResponse {
        try await loader(provider, adUnitId, position, theme, metadata)
    }

    /// Await and remove the preloaded ad for `id`. Returns nil if the id is unknown (expired,
    /// destroyed, already consumed) or its load failed — the caller then falls back to a live
    /// request, surfacing no error (PRD).
    func consume(_ id: String) async -> PreloadedNativeAd? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        // do/catch, not `try?` around an await — see the task-shape note in TelemetryManager.
        do {
            return PreloadedNativeAd(response: try await entry.task.value, metadata: entry.metadata)
        } catch {
            return nil
        }
    }

    /// Release a preloaded ad that was never consumed, cancelling its request if still in flight.
    func destroy(_ id: String) {
        entries.removeValue(forKey: id)?.task.cancel()
    }
}
#endif
