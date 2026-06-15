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
/// Cleared with `SimulaAds.invalidateNativeAd` when the publisher wants a fresh ad for a slot.
/// Lock-guarded so the slot's `init` can read it synchronously off any actor.
final class NativeAdCache: @unchecked Sendable {
    static let shared = NativeAdCache()

    /// A cached entry: `response != nil` is a fill (with its measured height + whether its impression
    /// already fired); `response == nil` is a no-fill. A reference type so the slot can update its
    /// height / fired flag in place.
    final class Entry: @unchecked Sendable {
        let response: NativeAdResponse?
        var heightPt: CGFloat = 0
        var impressionFired = false
        init(response: NativeAdResponse?) { self.response = response }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Impression ids whose impression already fired, so the same served ad reports at most one
    /// impression process-wide — even if shown in two slots (same cache key) or re-composed —
    /// independent of the per-slot `Entry.impressionFired` flag.
    private var firedImpressions: Set<String> = []

    private init() {}

    private func key(_ adUnitId: String?, _ position: Int) -> String { "\(adUnitId ?? ""):\(position)" }

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
        return entries[key(adUnitId, position)]
    }

    @discardableResult
    func putFill(_ adUnitId: String?, _ position: Int, _ response: NativeAdResponse) -> Entry {
        let entry = Entry(response: response)
        lock.lock(); entries[key(adUnitId, position)] = entry; lock.unlock()
        return entry
    }

    func putNoFill(_ adUnitId: String?, _ position: Int) {
        lock.lock(); entries[key(adUnitId, position)] = Entry(response: nil); lock.unlock()
    }

    func invalidate(_ adUnitId: String?, _ position: Int) {
        lock.lock(); defer { lock.unlock() }
        // Drop the impression-id mark too so a deliberately-refreshed slot can fire again.
        if let removed = entries.removeValue(forKey: key(adUnitId, position)),
           let id = removed.response?.impressionId, !id.isEmpty {
            firedImpressions.remove(id)
        }
    }

    func invalidateAll() {
        lock.lock(); entries.removeAll(); firedImpressions.removeAll(); lock.unlock()
    }
}
#endif
