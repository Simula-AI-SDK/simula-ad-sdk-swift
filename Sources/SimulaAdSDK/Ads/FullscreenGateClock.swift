import Foundation

struct FullscreenGateClock {
    private(set) var elapsed: TimeInterval = 0
    private var resumedAt: TimeInterval?

    mutating func resume(at now: TimeInterval) {
        guard resumedAt == nil, now.isFinite else { return }
        resumedAt = now
    }

    mutating func update(at now: TimeInterval, total: TimeInterval) {
        guard let resumedAt, now.isFinite, now >= resumedAt else { return }
        let boundedTotal = total.isFinite ? max(0, total) : 0
        elapsed = min(boundedTotal, elapsed + now - resumedAt)
        self.resumedAt = now
    }

    mutating func pause(at now: TimeInterval, total: TimeInterval) {
        update(at: now, total: total)
        resumedAt = nil
    }

    func remaining(total: TimeInterval) -> TimeInterval {
        guard total.isFinite else { return 0 }
        return max(0, total - elapsed)
    }

    func progress(total: TimeInterval) -> Double {
        guard total.isFinite, total > 0 else { return 1 }
        return min(1, max(0, elapsed / total))
    }

    func secondsRemaining(total: TimeInterval) -> Int {
        Int(exactly: ceil(remaining(total: total))) ?? 0
    }

    func timeUntilNextTick(total: TimeInterval) -> TimeInterval {
        let remaining = remaining(total: total)
        guard remaining > 0 else { return 0 }
        return min(remaining, max(0, floor(elapsed) + 1 - elapsed))
    }
}
