import XCTest
@testable import SimulaAdSDK

final class WeakPresentationSlotTests: XCTestCase {
    private final class Sheet {}

    func testOccupiedWhilePresentedObjectIsAlive() {
        let slot = WeakPresentationSlot<Sheet>()
        XCTAssertFalse(slot.isOccupied)
        let sheet = Sheet()
        slot.occupy(sheet)
        XCTAssertTrue(slot.isOccupied)
        slot.clear()
        XCTAssertFalse(slot.isOccupied)
    }

    func testSlotClearsItselfWhenThePresentedObjectIsDestroyed() {
        // The wedge-fix property: a sheet destroyed without its dismissal delegate firing
        // (window teardown, host VC dismissed under the sheet, StoreKit swipe-down) must not
        // block future presentations — the weak slot self-clears.
        let slot = WeakPresentationSlot<Sheet>()
        var sheet: Sheet? = Sheet()
        slot.occupy(sheet!)
        XCTAssertTrue(slot.isOccupied)
        sheet = nil
        XCTAssertFalse(slot.isOccupied)
    }

    func testReoccupyAfterUndismissedDestroyIsNotWedged() {
        let slot = WeakPresentationSlot<Sheet>()
        var first: Sheet? = Sheet()
        slot.occupy(first!)
        first = nil // destroyed with no clear() call — the old boolean flag would stick true
        let second = Sheet()
        slot.occupy(second)
        XCTAssertTrue(slot.isOccupied)
    }

    func testStaleFinishCannotClearNewerPresentation() {
        let slot = WeakPresentationSlot<Sheet>()
        var first: Sheet? = Sheet()
        let firstIdentity = slot.occupy(first!)
        first = nil // weak occupancy opens, but the first relay may finish later

        let second = Sheet()
        let secondIdentity = slot.occupy(second)

        XCTAssertFalse(slot.clear(ifMatches: firstIdentity))
        XCTAssertTrue(slot.isOccupied, "a stale relay must leave the newer sheet tracked")
        XCTAssertTrue(slot.clear(ifMatches: secondIdentity))
        XCTAssertFalse(slot.isOccupied)
    }

    func testSilentTeardownIdentityCanFinishBeforeAReplacementAppears() {
        let slot = WeakPresentationSlot<Sheet>()
        var sheet: Sheet? = Sheet()
        let identity = slot.occupy(sheet!)
        sheet = nil

        XCTAssertTrue(slot.clear(ifMatches: identity))
        XCTAssertFalse(slot.isOccupied)
    }
}
