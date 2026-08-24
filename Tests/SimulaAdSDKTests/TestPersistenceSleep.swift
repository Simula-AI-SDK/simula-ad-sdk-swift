import Foundation

final class ControllablePersistenceSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedDelay: TimeInterval?
    private var delayWaiter: CheckedContinuation<TimeInterval, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var requests = 0
    private var completions = 0
    private var completionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }

    func sleep(_ delay: TimeInterval) async {
        let waiter: CheckedContinuation<TimeInterval, Never>?
        lock.lock()
        requests += 1
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

        lock.lock()
        completions += 1
        let ready = completionWaiters.filter { $0.0 <= completions }
        completionWaiters.removeAll { $0.0 <= completions }
        lock.unlock()
        ready.forEach { $0.1.resume() }
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

    func waitForCompletion(_ count: Int = 1) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completions >= count {
                lock.unlock()
                continuation.resume()
            } else {
                completionWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }
}
