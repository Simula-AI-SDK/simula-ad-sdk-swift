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

    // MARK: - session-consistency gate (stale-session identity fix)

    func testSessionIdSentWhenItMatchesCheckedPpid() {
        XCTAssertEqual(SimulaAds.consistentSessionId("sess_1", sessionUserID: "user_1", ppid: "user_1"), "sess_1")
    }

    func testSessionIdDroppedWhenIdentityDiverges() {
        // Session still represents user_1 but we're checking user_2 (mid-session switch/login).
        XCTAssertNil(SimulaAds.consistentSessionId("sess_1", sessionUserID: "user_1", ppid: "user_2"))
    }

    func testSessionIdDroppedAfterLogoutWhenSessionHoldsPriorUser() {
        // ppid cleared (logout) but the server session can't be cleared, so it still holds user_1.
        XCTAssertNil(SimulaAds.consistentSessionId("sess_1", sessionUserID: "user_1", ppid: nil))
    }

    func testAnonymousSessionMatchesAnonymousCheck() {
        XCTAssertEqual(SimulaAds.consistentSessionId("sess_1", sessionUserID: nil, ppid: nil), "sess_1")
    }

    func testNoSessionIdYieldsNil() {
        XCTAssertNil(SimulaAds.consistentSessionId(nil, sessionUserID: nil, ppid: nil))
        XCTAssertNil(SimulaAds.consistentSessionId(nil, sessionUserID: "user_1", ppid: "user_1"))
    }

    // MARK: - FrequencyCapCache

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var oneDay: TimeInterval { 86_400 }

    override func setUp() {
        super.setUp()
        FrequencyCapCache.shared.clear()
    }

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

    func testSameDayCappedEntriesAreNeverEvictedRegardlessOfCount() {
        // The "cache true for the rest of the day" guarantee must hold no matter how many distinct
        // ad units are checked in a day — there is no fixed cap that could drop a valid entry.
        for i in 0..<500 {
            FrequencyCapCache.shared.markCapped(adUnitId: "unit_\(i)", ppid: "user_1", now: referenceDate)
        }
        XCTAssertTrue(FrequencyCapCache.shared.isCapped(adUnitId: "unit_0", ppid: "user_1", now: referenceDate))
        XCTAssertTrue(FrequencyCapCache.shared.isCapped(adUnitId: "unit_499", ppid: "user_1", now: referenceDate))
    }

    func testCrossingMidnightClearsAllCachedCaps() {
        FrequencyCapCache.shared.markCapped(adUnitId: "unit_1", ppid: "user_1", now: referenceDate)
        FrequencyCapCache.shared.markCapped(adUnitId: "unit_2", ppid: "user_2", now: referenceDate)
        let nextDay = referenceDate.addingTimeInterval(oneDay)
        XCTAssertFalse(FrequencyCapCache.shared.isCapped(adUnitId: "unit_1", ppid: "user_1", now: nextDay))
        XCTAssertFalse(FrequencyCapCache.shared.isCapped(adUnitId: "unit_2", ppid: "user_2", now: nextDay))
    }

    func testALatePriorDayMarkDoesNotWipeCurrentDayEntries() {
        let nextDay = referenceDate.addingTimeInterval(oneDay)
        // A request on the new day establishes the current day and caps "current".
        FrequencyCapCache.shared.markCapped(adUnitId: "current", ppid: "user_1", now: nextDay)
        // A request that STARTED before midnight finishes now and marks with its prior-day start time;
        // it must neither rewind the day (wiping "current") nor resurrect the reset prior-day cap.
        FrequencyCapCache.shared.markCapped(adUnitId: "late", ppid: "user_1", now: referenceDate)
        XCTAssertTrue(FrequencyCapCache.shared.isCapped(adUnitId: "current", ppid: "user_1", now: nextDay))
        XCTAssertFalse(FrequencyCapCache.shared.isCapped(adUnitId: "late", ppid: "user_1", now: nextDay))
    }

    func testPipeCharactersInIdsDoNotCollideAcrossPairs() {
        // "foo" + "bar|baz" and "foo|bar" + "baz" must be distinct keys (a naive concatenation with a
        // '|' delimiter would collide them into "foo|bar|baz").
        FrequencyCapCache.shared.markCapped(adUnitId: "foo", ppid: "bar|baz", now: referenceDate)
        XCTAssertTrue(FrequencyCapCache.shared.isCapped(adUnitId: "foo", ppid: "bar|baz", now: referenceDate))
        XCTAssertFalse(FrequencyCapCache.shared.isCapped(adUnitId: "foo|bar", ppid: "baz", now: referenceDate))
    }
}
