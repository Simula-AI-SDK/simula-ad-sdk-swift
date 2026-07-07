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
    private var currentDay = Int.min
    private var cappedKeys: Set<CacheKey> = []

    private struct CacheKey: Hashable {
        let adUnitId: String
        let ppid: String?
    }

    /// Ordered day number in the device's current time zone (days since the Unix epoch), so a later
    /// local day is always numerically greater — required to only ever roll FORWARD. `TimeZone.current`
    /// is read per call, so a mid-session time-zone change is reflected.
    private func localDay(_ date: Date) -> Int {
        let offset = TimeZone.current.secondsFromGMT(for: date)
        return Int((date.timeIntervalSince1970 + Double(offset)) / 86_400)
    }

    /// Returns `true` only if `adUnitId`/`ppid` was marked capped on the current local day.
    func isCapped(adUnitId: String, ppid: String?, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let today = localDay(now)
        rolloverIfNeeded(today)
        // `today < currentDay` is a stale read (a request whose start time predates a rollover
        // another call already advanced): that day's cap has reset, so report not-capped.
        return today == currentDay && cappedKeys.contains(CacheKey(adUnitId: adUnitId, ppid: ppid))
    }

    /// Marks `adUnitId`/`ppid` as capped for the rest of the current local day.
    func markCapped(adUnitId: String, ppid: String?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let today = localDay(now)
        rolloverIfNeeded(today)
        // Ignore a mark carrying an already-past day: it must neither resurrect a reset cap nor
        // (via a rewind) wipe the current day's still-valid entries.
        if today == currentDay { cappedKeys.insert(CacheKey(adUnitId: adUnitId, ppid: ppid)) }
    }

    /// Advances to a NEWER local day only, clearing the prior day's caps (the midnight reset). It
    /// never rewinds: a late call carrying an older day (e.g. a check whose start time was captured
    /// before midnight but that completes after) must not wipe the current day's valid entries.
    private func rolloverIfNeeded(_ today: Int) {
        if today > currentDay {
            currentDay = today
            cappedKeys.removeAll()
        }
    }

    /// Clears every cached entry. Exposed for tests.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        cappedKeys.removeAll()
        currentDay = .min
    }
}
