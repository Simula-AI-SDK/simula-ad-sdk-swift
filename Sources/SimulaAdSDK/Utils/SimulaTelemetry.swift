import Foundation
import QuartzCore

/// Low-overhead, thread-safe monotonic clock tracing utility.
/// Provides nanosecond-level time measurements immune to system clock shifts.
public final class SimulaTelemetry: @unchecked Sendable {
    public static let shared = SimulaTelemetry()

    private var activeSpans: [String: Double] = [:]
    private let lock = NSLock()

    private init() {}

    /// Starts a telemetry span.
    public func startSpan(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        activeSpans[name] = CACurrentMediaTime()
    }

    /// Ends a telemetry span, prints its duration to the console in milliseconds, and returns the elapsed time.
    @discardableResult
    public func endSpan(_ name: String, additionalInfo: String = "") -> Double {
        lock.lock()
        guard let startTime = activeSpans[name] else {
            lock.unlock()
            return 0
        }
        activeSpans.removeValue(forKey: name)
        lock.unlock()

        let elapsed = CACurrentMediaTime() - startTime
        let elapsedMs = Int(elapsed * 1000)
        
        let infoStr = additionalInfo.isEmpty ? "" : " (\(additionalInfo))"
        print("📊 [SimulaTelemetry] \(name): \(elapsedMs)ms\(infoStr)")
        return elapsed
    }
}
