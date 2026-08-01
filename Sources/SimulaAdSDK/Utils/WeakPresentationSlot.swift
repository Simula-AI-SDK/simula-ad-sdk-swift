/// Tracks a single in-flight presented object (e.g. an in-app store/Safari sheet) by WEAK
/// reference. Replaces a boolean "is presenting" flag, which wedges shut forever when the
/// sheet is destroyed without its dismissal delegate firing (the presenter tears down its
/// window, the host dismisses its own view controller under the sheet, or StoreKit's
/// swipe-down misses `productViewControllerDidFinish`). A weak slot clears itself in all of
/// those paths, so future presentations are never permanently blocked.
///
/// Not platform-bound (generic over AnyObject) so the wedge-fix property is unit-testable on
/// macOS. Callers are main-confined (presentation code), so no synchronization is needed.
final class WeakPresentationSlot<Presented: AnyObject> {
    private weak var presented: Presented?

    /// True while a previously-occupied object is still alive.
    var isOccupied: Bool { presented != nil }

    /// Marks the slot occupied. Callers must only call this after a confirmed present —
    /// never on a failed present, mirroring the old flag's discipline.
    func occupy(_ value: Presented) { presented = value }

    /// Clears the slot explicitly (the normal delegate-driven dismissal path).
    func clear() { presented = nil }
}
