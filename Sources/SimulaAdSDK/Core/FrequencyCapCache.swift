import Foundation

/// Session-scoped cache for `SimulaAds.checkFrequencyCap`: caches a `true` (cap reached) result
/// for the rest of the local day, unless local device time crosses midnight — matching the PRD's
/// "cache a true result for the rest of the session, unless local device time crosses midnight
/// (cap resets daily)".
///
/// Only a `true` result is ever cached: a `false` (eligible) is never stored, since a user can
/// become capped later in the same session and every call already fails open to `false` on error.
/// Keyed by `adUnitId|ppid` so a mid-session `SimulaAds.updatePrimaryUserID` (login/logout) can't
/// leak a prior user's cached cap onto the new identity.
///
/// `@unchecked Sendable` guarded by an internal lock (mirrors `PPIDStore`) so it's safely callable
/// off the main actor from `SimulaAPI`'s async call sites.
final class FrequencyCapCache: @unchecked Sendable {
    static let shared = FrequencyCapCache()

    private let lock = NSLock()
    // key -> local calendar day the `true` result was cached on, plus an insertion-order list so
    // the store can evict its oldest entry once past `maxEntries`.
    private var cappedDays: [String: String] = [:]
    private var order: [String] = []

    /// Upper bound on distinct (adUnitId, ppid) entries retained, so a host that checks many ad
    /// units / users across a long-lived process can't grow this without bound. Mirrors the SDK's
    /// other bounded caches (`BoundedStore` in `SimulaProvider`).
    private let maxEntries = 64

    /// `autoupdatingCurrent` so a mid-session time-zone change is reflected (the cap resets at the
    /// new local midnight) rather than snapshotting the zone at first access.
    private let calendar = Calendar.autoupdatingCurrent

    private func key(adUnitId: String, ppid: String?) -> String {
        "\(adUnitId)|\(ppid ?? "")"
    }

    /// A key that's stable for a given calendar day (in the device's current time zone) and
    /// distinct across any different day — used only for equality, not ordering.
    private func localDay(_ date: Date) -> String {
        let comps = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(comps.era ?? 0)-\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    /// Returns `true` only if `adUnitId`/`ppid` was marked capped on the current local day.
    func isCapped(adUnitId: String, ppid: String?, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let cachedDay = cappedDays[key(adUnitId: adUnitId, ppid: ppid)] else { return false }
        return cachedDay == localDay(now)
    }

    /// Marks `adUnitId`/`ppid` as capped for the rest of the current local day.
    func markCapped(adUnitId: String, ppid: String?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let k = key(adUnitId: adUnitId, ppid: ppid)
        if cappedDays[k] == nil { order.append(k) }
        cappedDays[k] = localDay(now)
        while cappedDays.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            cappedDays.removeValue(forKey: oldest)
        }
    }

    /// Clears every cached entry. Exposed for tests.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        cappedDays.removeAll()
        order.removeAll()
    }
}
