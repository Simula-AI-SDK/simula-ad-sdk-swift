import Foundation

/// Session-scoped cache for `SimulaAds.checkFrequencyCap`: remembers a `true` (cap reached) result
/// for the rest of the local day, resetting when local device time crosses midnight — matching the
/// PRD's "cache a true result for the rest of the session, unless local device time crosses midnight
/// (cap resets daily)".
///
/// Only a `true` result is ever cached: a `false` (eligible) is never stored, since a user can become
/// capped later in the same session and every call already fails open to `false` on error. Keyed by
/// (adUnitId, ppid) via a `Hashable` struct so a mid-session `SimulaAds.updatePrimaryUserID`
/// (login/logout) can't leak a prior user's cached cap, and no delimiter concatenation can make two
/// distinct pairs collide.
///
/// Bounding: the cache holds only the CURRENT local day's capped keys. The first read/mark on a new
/// day clears the whole set (midnight reset), so entries never accumulate across days — memory is
/// bounded to a single day's distinct capped keys and self-resets, with no fixed cap that could evict
/// a still-valid same-day entry (which would violate the "rest of the day" guarantee).
///
/// `@unchecked Sendable` guarded by an internal lock (mirrors `PPIDStore`) so it's safely callable
/// off the main actor.
final class FrequencyCapCache: @unchecked Sendable {
    static let shared = FrequencyCapCache()

    private let lock = NSLock()
    private var currentDay: String?
    private var cappedKeys: Set<CacheKey> = []

    /// `autoupdatingCurrent` so a mid-session time-zone change is reflected (the cap resets at the
    /// new local midnight) rather than snapshotting the zone at first access.
    private let calendar = Calendar.autoupdatingCurrent

    private struct CacheKey: Hashable {
        let adUnitId: String
        let ppid: String?
    }

    /// A key that's stable for a given calendar day (in the device's current time zone) and distinct
    /// across any different day — used only for equality, not ordering.
    private func localDay(_ date: Date) -> String {
        let comps = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(comps.era ?? 0)-\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    /// Returns `true` only if `adUnitId`/`ppid` was marked capped on the current local day.
    func isCapped(adUnitId: String, ppid: String?, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded(localDay(now))
        return cappedKeys.contains(CacheKey(adUnitId: adUnitId, ppid: ppid))
    }

    /// Marks `adUnitId`/`ppid` as capped for the rest of the current local day.
    func markCapped(adUnitId: String, ppid: String?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded(localDay(now))
        cappedKeys.insert(CacheKey(adUnitId: adUnitId, ppid: ppid))
    }

    /// Clears the set whenever the local day changes, so cached caps never survive past local midnight.
    private func rolloverIfNeeded(_ today: String) {
        if today != currentDay {
            currentDay = today
            cappedKeys.removeAll()
        }
    }

    /// Clears every cached entry. Exposed for tests.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        cappedKeys.removeAll()
        currentDay = nil
    }
}
