#if os(iOS)
import XCTest
@testable import SimulaAdSDK

/// Slot-identity tests for `NativeAdCache` — the preload-scoped keying that keeps same-position
/// preloaded slots (a host that never passes `position`, leaving every slot at the default 0) from
/// clobbering each other's entry and converging to one ad as rows recycle.
///
/// The cache is a shared singleton, so every test namespaces its entries under a fresh UUID
/// adUnitId and invalidates what it created.
final class NativeAdCacheTests: XCTestCase {

    private func response(_ impressionId: String) -> NativeAdResponse {
        NativeAdResponse(
            impressionId: impressionId,
            adInserted: true,
            adFormat: "character_ad",
            renderedHtml: "<html></html>"
        )
    }

    /// The regression this keying exists for: two preloaded slots sharing (adUnitId, position)
    /// must keep distinct entries — previously the second putFill overwrote the first.
    func testSamePositionPreloadedSlotsKeepDistinctEntries() {
        let unit = UUID().uuidString
        NativeAdCache.shared.putFill(unit, 0, response("imp-a"), preloadedAdId: "preload-a")
        NativeAdCache.shared.putFill(unit, 0, response("imp-b"), preloadedAdId: "preload-b")

        XCTAssertEqual(NativeAdCache.shared.get(unit, 0, "preload-a")?.response?.impressionId, "imp-a")
        XCTAssertEqual(NativeAdCache.shared.get(unit, 0, "preload-b")?.response?.impressionId, "imp-b")
        XCTAssertNil(NativeAdCache.shared.get(unit, 0),
                     "preload-scoped fills must not populate the un-scoped slot entry")
        _ = NativeAdCache.shared.invalidate(unit, 0)
    }

    /// A preloaded slot must replay only ITS OWN serve — never another slot's live fill at the
    /// same position (and vice versa).
    func testScopedAndUnscopedLookupsAreIsolated() {
        let unit = UUID().uuidString
        NativeAdCache.shared.putFill(unit, 0, response("imp-live"))

        XCTAssertNil(NativeAdCache.shared.get(unit, 0, "preload-x"),
                     "a preloaded slot must not replay another slot's live serve")
        XCTAssertEqual(NativeAdCache.shared.get(unit, 0)?.response?.impressionId, "imp-live")
        _ = NativeAdCache.shared.invalidate(unit, 0)
    }

    /// A blank preloadedAdId (defensive: bridges normalize empty strings) addresses the plain
    /// slot key, identical to passing nil.
    func testEmptyPreloadedAdIdFallsBackToSlotKey() {
        let unit = UUID().uuidString
        NativeAdCache.shared.putFill(unit, 0, response("imp-live"), preloadedAdId: "")

        XCTAssertEqual(NativeAdCache.shared.get(unit, 0)?.response?.impressionId, "imp-live")
        XCTAssertEqual(NativeAdCache.shared.get(unit, 0, "")?.response?.impressionId, "imp-live")
        _ = NativeAdCache.shared.invalidate(unit, 0)
    }

    /// invalidate(adUnitId, position) addresses the placement: it drops the un-scoped entry AND
    /// every preload-scoped entry at that position (returning all their impression ids for web
    /// view eviction), while other positions stay untouched.
    func testInvalidateDropsScopedEntriesAndReturnsAllImpressionIds() {
        let unit = UUID().uuidString
        NativeAdCache.shared.putFill(unit, 0, response("imp-live"))
        NativeAdCache.shared.putFill(unit, 0, response("imp-a"), preloadedAdId: "preload-a")
        NativeAdCache.shared.putFill(unit, 0, response("imp-b"), preloadedAdId: "preload-b")
        NativeAdCache.shared.putFill(unit, 1, response("imp-other"), preloadedAdId: "preload-c")

        let invalidated = NativeAdCache.shared.invalidate(unit, 0)

        XCTAssertEqual(Set(invalidated), ["imp-live", "imp-a", "imp-b"])
        XCTAssertNil(NativeAdCache.shared.get(unit, 0))
        XCTAssertNil(NativeAdCache.shared.get(unit, 0, "preload-a"))
        XCTAssertNil(NativeAdCache.shared.get(unit, 0, "preload-b"))
        XCTAssertEqual(NativeAdCache.shared.get(unit, 1, "preload-c")?.response?.impressionId, "imp-other")
        _ = NativeAdCache.shared.invalidate(unit, 1)
    }

    /// Invalidating a preload-scoped fill drops its fired-impression mark, so a deliberately
    /// refreshed slot can fire again (parity with the un-scoped path).
    func testInvalidateDropsFiredMarkOfScopedEntries() {
        let unit = UUID().uuidString
        let impressionId = "imp-\(UUID().uuidString)"
        NativeAdCache.shared.putFill(unit, 0, response(impressionId), preloadedAdId: "preload-a")

        XCTAssertTrue(NativeAdCache.shared.markImpressionFired(impressionId))
        XCTAssertFalse(NativeAdCache.shared.markImpressionFired(impressionId),
                       "second fire of the same serve must dedup")

        _ = NativeAdCache.shared.invalidate(unit, 0)
        XCTAssertTrue(NativeAdCache.shared.markImpressionFired(impressionId),
                      "invalidate must drop the fired mark so a refreshed slot can fire again")
        _ = NativeAdCache.shared.invalidate(unit, 0)
    }

    /// No-fill outcomes are preload-scoped too: one slot's no-fill must not collapse a sibling
    /// slot at the same position.
    func testNoFillIsScopedPerPreloadedSlot() {
        let unit = UUID().uuidString
        NativeAdCache.shared.putNoFill(unit, 0, preloadedAdId: "preload-a")
        NativeAdCache.shared.putFill(unit, 0, response("imp-b"), preloadedAdId: "preload-b")

        XCTAssertNotNil(NativeAdCache.shared.get(unit, 0, "preload-a"))
        XCTAssertNil(NativeAdCache.shared.get(unit, 0, "preload-a")?.response, "a cached no-fill")
        XCTAssertEqual(NativeAdCache.shared.get(unit, 0, "preload-b")?.response?.impressionId, "imp-b")
        _ = NativeAdCache.shared.invalidate(unit, 0)
    }
}
#endif
