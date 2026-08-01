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
}
