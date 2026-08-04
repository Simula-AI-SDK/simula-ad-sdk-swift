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
        _ theme: String?
    ) async throws -> NativeAdResponse

    private struct Entry {
        let token: UUID
        let task: Task<NativeAdResponse, Error>
    }

    private let maxEntries = 5
    private let loader: Loader
    private var entries: [String: Entry] = [:]

    init(loader: @escaping Loader = { provider, adUnitId, position, theme in
        try await NativeAdController.load(
            provider: provider,
            adUnitId: adUnitId,
            position: position,
            theme: theme
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
        theme: String?
    ) -> String? {
        guard entries.count < maxEntries else {
            Telemetry.shared.recordOperation(name: "native_preload_capped", durationMs: 0, success: false)
            return nil
        }
        let resolvedTheme = NativeAdTheme.resolve(theme, isDark: NativeAdTheme.systemIsDark)
        let id = UUID().uuidString
        let token = UUID()
        // Single-call task closure — see the task-shape note in TelemetryManager.
        let task = Task { @MainActor in
            try await runLoad(
                provider: provider,
                adUnitId: adUnitId,
                position: position,
                theme: resolvedTheme,
                id: id,
                token: token
            )
        }
        entries[id] = Entry(token: token, task: task)
        return id
    }

    /// Named task entry point required by the optimizer-safe task-shape contract.
    private func runLoad(
        provider: SimulaProvider,
        adUnitId: String?,
        position: Int,
        theme: String?,
        id: String,
        token: UUID
    ) async throws -> NativeAdResponse {
        do {
            return try await loader(provider, adUnitId, position, theme)
        } catch {
            // A terminal preload must release capacity even when no slot is consuming it or the
            // consumer was cancelled. The token prevents an old task touching a replacement entry.
            if entries[id]?.token == token {
                entries.removeValue(forKey: id)
            }
            throw error
        }
    }

    /// Await and remove the preloaded ad for `id`. Returns nil if the id is unknown (expired,
    /// destroyed, already consumed) or its load failed — the caller then falls back to a live
    /// request, surfacing no error (PRD).
    func consume(_ id: String) async -> NativeAdResponse? {
        guard !Task.isCancelled else { return nil }
        guard let entry = entries[id] else { return nil }
        // do/catch, not `try?` around an await — see the task-shape note in TelemetryManager.
        do {
            let response = try await entry.task.value
            // SwiftUI cancelled this slot while the process-owned preload continued. Leave the
            // completed entry available for a remount instead of forcing a duplicate live request.
            guard !Task.isCancelled else { return nil }
            guard entries[id]?.token == entry.token else { return nil }
            entries.removeValue(forKey: id)
            return response
        } catch {
            if !Task.isCancelled, entries[id]?.token == entry.token {
                entries.removeValue(forKey: id)
            }
            return nil
        }
    }

    /// Release a preloaded ad that was never consumed, cancelling its request if still in flight.
    func destroy(_ id: String) {
        entries.removeValue(forKey: id)?.task.cancel()
    }
}
#endif
