import Foundation
@testable import SimulaAdSDK

actor ControllableLaunchSettledGate: LaunchSettling {
    private nonisolated let settledSnapshot = LockedLaunchGateState()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitCount = 0

    nonisolated var isSettled: Bool { settledSnapshot.value }

    func waitUntilSettled() async {
        waitCount += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        settledSnapshot.setOpen()
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class LockedLaunchGateState: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    func setOpen() {
        lock.lock(); open = true; lock.unlock()
    }
}
