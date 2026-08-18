import Foundation

final class ControllablePersistenceSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedDelay: TimeInterval?
    private var delayWaiter: CheckedContinuation<TimeInterval, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    func sleep(_ delay: TimeInterval) async {
        let waiter: CheckedContinuation<TimeInterval, Never>?
        lock.lock()
        requestedDelay = delay
        waiter = delayWaiter
        delayWaiter = nil
        lock.unlock()
        waiter?.resume(returning: delay)

        await withCheckedContinuation { continuation in
            lock.lock()
            if releaseRequested {
                releaseRequested = false
                lock.unlock()
                continuation.resume()
            } else {
                releaseContinuation = continuation
                lock.unlock()
            }
        }
    }

    func waitForRequest() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let requestedDelay {
                lock.unlock()
                continuation.resume(returning: requestedDelay)
            } else {
                delayWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        let continuation = releaseContinuation
        releaseContinuation = nil
        requestedDelay = nil
        if continuation == nil { releaseRequested = true }
        lock.unlock()
        continuation?.resume()
    }
}
