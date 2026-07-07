import XCTest
@testable import SimulaAdSDK

/// Verifies frequency-cap URL construction (`SimulaAPI.frequencyCapURL`) and the session-scoped
/// `FrequencyCapCache` day-rollover / ppid / ad-unit keying — no network.
final class FrequencyCapTests: XCTestCase {

    // MARK: - URL construction

    func testURLAlwaysCarriesAdUnitId() {
        let url = SimulaAPI.frequencyCapURL(adUnitId: "unit_1")
        XCTAssertEqual(url?.query, "ad_unit_id=unit_1")
    }

    func testURLAppendsPpidAndSessionIdWhenPresent() {
        let url = SimulaAPI.frequencyCapURL(adUnitId: "unit_1", ppid: "user_9", sessionId: "sess_9")
        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("ad_unit_id=unit_1"))
        XCTAssertTrue(query.contains("ppid=user_9"))
        XCTAssertTrue(query.contains("session_id=sess_9"))
    }

    func testURLOmitsEmptyPpidAndSessionId() {
        let url = SimulaAPI.frequencyCapURL(adUnitId: "unit_1", ppid: "", sessionId: nil)
        let query = url?.query ?? ""
        XCTAssertFalse(query.contains("ppid"))
        XCTAssertFalse(query.contains("session_id"))
    }

    // MARK: - FrequencyCapCache

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var oneDay: TimeInterval { 86_400 }

    override func tearDown() {
        FrequencyCapCache.shared.clear()
        super.tearDown()
    }

    func testUncachedAdUnitIsNotCapped() {
        XCTAssertFalse(FrequencyCapCache.shared.isCapped(adUnitId: "unit_1", ppid: "user_1", now: referenceDate))
    }

    func testMarkedCappedIsCappedLaterTheSameDay() {
        FrequencyCapCache.shared.markCapped(adUnitId: "unit_1", ppid: "user_1", now: referenceDate)
        XCTAssertTrue(
            FrequencyCapCache.shared.isCapped(adUnitId: "unit_1", ppid: "user_1", now: referenceDate.addingTimeInterval(10))
        )
    }

    func testCappedResetsAfterCrossingADayBoundary() {
        FrequencyCapCache.shared.markCapped(adUnitId: "unit_1", ppid: "user_1", now: referenceDate)
        XCTAssertFalse(
            FrequencyCapCache.shared.isCapped(adUnitId: "unit_1", ppid: "user_1", now: referenceDate.addingTimeInterval(oneDay))
        )
    }

    func testCappedStateIsKeyedPerPpid() {
        FrequencyCapCache.shared.markCapped(adUnitId: "unit_1", ppid: "user_1", now: referenceDate)
        XCTAssertFalse(FrequencyCapCache.shared.isCapped(adUnitId: "unit_1", ppid: "user_2", now: referenceDate))
        XCTAssertFalse(FrequencyCapCache.shared.isCapped(adUnitId: "unit_1", ppid: nil, now: referenceDate))
    }

    func testCappedStateIsKeyedPerAdUnit() {
        FrequencyCapCache.shared.markCapped(adUnitId: "unit_1", ppid: "user_1", now: referenceDate)
        XCTAssertFalse(FrequencyCapCache.shared.isCapped(adUnitId: "unit_2", ppid: "user_1", now: referenceDate))
    }

    func testCacheIsBoundedAndEvictsTheEldestEntry() {
        // Mark more than the cap (64) distinct ad units; the earliest inserted must be evicted so
        // the store can never grow without bound for the process lifetime.
        for i in 0...64 {
            FrequencyCapCache.shared.markCapped(adUnitId: "unit_\(i)", ppid: "user_1", now: referenceDate)
        }
        XCTAssertFalse(FrequencyCapCache.shared.isCapped(adUnitId: "unit_0", ppid: "user_1", now: referenceDate))
        XCTAssertTrue(FrequencyCapCache.shared.isCapped(adUnitId: "unit_64", ppid: "user_1", now: referenceDate))
    }
}
