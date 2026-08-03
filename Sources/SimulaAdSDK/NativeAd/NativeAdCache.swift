#if os(iOS)
import Foundation
import CoreGraphics

/// Per-slot cache of resolved native ads, keyed by `"adUnitId:position"`.
///
/// A `NativeAdSlot` lives inside a lazy stack, which disposes and recreates off-screen rows. Without
/// this cache, scrolling a slot out and back would re-run `POST /load/native` and re-fire the
/// impression every time — over-serving and inflating impression counts. With it, the first
/// appearance fetches once; every later remount renders the same ad from memory (no network, no
/// shimmer) and the impression fires exactly once per served ad. The reported height is cached too,
/// so a recycled row sizes correctly on its first frame.
///
/// The store is an access-ordered LRU bounded by `maxEntries`: a long feed would otherwise accrue one
/// entry (each holding a full rendered creative) per scrolled-past position for the life of the
/// process. The cap is far above the handful of slots ever on screen, so eviction only targets
/// long-scrolled-past positions — which simply re-fetch (and fire a fresh impression) if revisited.
///
/// Cleared with `SimulaAds.invalidateNativeAd` when the publisher wants a fresh ad for a slot.
/// Lock-guarded so the slot's `init` can read it synchronously off any actor.
final class NativeAdCache: @unchecked Sendable {
    static let shared = NativeAdCache()

    /// A cached entry: `response != nil` is a fill (with its measured height + whether its impression
    /// already fired); `response == nil` is a no-fill. A reference type so the slot can update its
    /// height / fired flag in place.
    ///
    /// `@unchecked Sendable` is sound by **confinement, not synchronization**: `response` is immutable,
    /// and the two mutable fields are only ever written from the main actor — `heightPt` by SwiftUI's
    /// layout pass and `impressionFired` by `NativeAdSlot.fireImpression` (a `@MainActor` method). The
    /// cross-slot, process-wide impression dedupe is handled separately by the lock-guarded
    /// `firedImpressions` set (`markImpressionFired`), not by this per-entry flag. Do not write these
    /// fields off the main actor.
    final class Entry: @unchecked Sendable {
        let response: NativeAdResponse?
        /// Immutable publisher metadata captured for the load that produced `response`.
        let metadata: [String: String]?
        var heightPt: CGFloat = 0 // main-actor only
        var impressionFired = false // main-actor only
        init(response: NativeAdResponse?, metadata: [String: String]? = nil) {
            self.response = response
            self.metadata = metadata
        }
    }

    /// Hard cap on retained slot entries. Generous relative to on-screen slot count; keeps process
    /// memory bounded regardless of feed length.
    private let maxEntries = 64

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// LRU recency for `entries`: front = least-recently used, back = most-recent. Kept in sync with
    /// `entries` under `lock` so the eldest key can be evicted once the cap is exceeded.
    private var accessOrder: [String] = []
    /// Impression ids whose impression already fired, so the same served ad reports at most one
    /// impression process-wide — even if shown in two slots (same cache key) or re-composed —
    /// independent of the per-slot `Entry.impressionFired` flag. Bounded: an id is dropped when its
    /// entry is evicted or invalidated.
    private var firedImpressions: Set<String> = []

    private init() {}

    private func key(_ adUnitId: String?, _ position: Int) -> String { "\(adUnitId ?? ""):\(position)" }

    /// Marks `k` as most-recently used. Caller must hold `lock`.
    private func touch(_ k: String) {
        if let idx = accessOrder.firstIndex(of: k) { accessOrder.remove(at: idx) }
        accessOrder.append(k)
    }

    /// Evicts least-recently-used entries until within `maxEntries`, dropping each evicted fill's
    /// impression mark. Returns the evicted fills' impression ids so the caller can (off-lock)
    /// evict their retained web views too — the fill is gone, so a retained view for it could
    /// never be legitimately reattached. Caller must hold `lock`.
    private func evictIfNeeded() -> [String] {
        var evictedIds: [String] = []
        while entries.count > maxEntries, !accessOrder.isEmpty {
            let oldest = accessOrder.removeFirst()
            if let removed = entries.removeValue(forKey: oldest),
               let id = removed.response?.impressionId, !id.isEmpty {
                firedImpressions.remove(id)
                evictedIds.append(id)
            }
        }
        return evictedIds
    }

    /// Drops the retained rendered web views for fills this cache just evicted, keeping the two
    /// LRUs from disagreeing about which serves are alive. Called OFF-lock (the store is
    /// `@MainActor`; hopping while holding `lock` is forbidden). Single-call task closure — see
    /// the task-shape note in TelemetryManager.
    private func evictRetainedWebViews(_ impressionIds: [String]) {
        guard !impressionIds.isEmpty else { return }
        Task { @MainActor in NativeAdWebViewStore.shared.evictAll(impressionIds: impressionIds) }
    }

    /// Atomically marks `impressionId` as having fired. Returns `true` only the first time, so callers
    /// fire the impression (callback + server beacon) at most once per served ad. Blank ids (previews)
    /// are never tracked and always return `false`.
    func markImpressionFired(_ impressionId: String) -> Bool {
        guard !impressionId.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return firedImpressions.insert(impressionId).inserted
    }

    func get(_ adUnitId: String?, _ position: Int) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        let k = key(adUnitId, position)
        guard let entry = entries[k] else { return nil }
        touch(k)
        return entry
    }

    @discardableResult
    func putFill(
        _ adUnitId: String?,
        _ position: Int,
        _ response: NativeAdResponse,
        metadata: [String: String]?
    ) -> Entry {
        let entry = Entry(response: response, metadata: metadata)
        lock.lock()
        let k = key(adUnitId, position)
        entries[k] = entry
        touch(k)
        let evicted = evictIfNeeded()
        lock.unlock()
        evictRetainedWebViews(evicted)
        return entry
    }

    func putNoFill(_ adUnitId: String?, _ position: Int) {
        lock.lock()
        let k = key(adUnitId, position)
        entries[k] = Entry(response: nil)
        touch(k)
        let evicted = evictIfNeeded()
        lock.unlock()
        evictRetainedWebViews(evicted)
    }

    /// Returns the invalidated fill's impression id (nil for a no-fill / unknown slot) so the caller
    /// can evict the matching retained web view from `NativeAdWebViewStore` too.
    @discardableResult
    func invalidate(_ adUnitId: String?, _ position: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        let k = key(adUnitId, position)
        var invalidatedId: String?
        // Drop the impression-id mark too so a deliberately-refreshed slot can fire again.
        if let removed = entries.removeValue(forKey: k),
           let id = removed.response?.impressionId, !id.isEmpty {
            firedImpressions.remove(id)
            invalidatedId = id
        }
        if let idx = accessOrder.firstIndex(of: k) { accessOrder.remove(at: idx) }
        return invalidatedId
    }

    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        accessOrder.removeAll()
        firedImpressions.removeAll()
        lock.unlock()
    }
}
#endif
