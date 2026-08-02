import Foundation

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
    /// Retained independently of the weak object so silent teardown can still identify the
    /// presentation whose relay is finishing. Re-occupying replaces this identity immediately.
    private var identity: PresentationIdentity?

    /// True while a previously-occupied object is still alive.
    var isOccupied: Bool { presented != nil }

    /// Marks the slot occupied. Callers must only call this after a confirmed present —
    /// never on a failed present, mirroring the old flag's discipline.
    @discardableResult
    func occupy(_ value: Presented, identity: PresentationIdentity = PresentationIdentity()) -> PresentationIdentity {
        presented = value
        self.identity = identity
        return identity
    }

    /// Clears the slot explicitly (the normal delegate-driven dismissal path).
    func clear() {
        presented = nil
        identity = nil
    }

    /// Clears only if `expectedIdentity` still owns the slot. A delayed finish relay from a
    /// destroyed sheet must not clear or announce dismissal for a newer live sheet.
    @discardableResult
    func clear(ifMatches expectedIdentity: PresentationIdentity) -> Bool {
        guard identity == expectedIdentity else { return false }
        clear()
        return true
    }
}

/// Stable identity for one presentation attempt. Unlike `ObjectIdentifier`, it cannot be reused
/// when a destroyed sheet and its replacement happen to occupy the same allocator address.
struct PresentationIdentity: Equatable, Sendable {
    private let value = UUID()
}
