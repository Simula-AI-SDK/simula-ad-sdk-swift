import Foundation

/// Process-scoped monotonic origin for telemetry that needs time since the SDK's first entry point.
/// Both `SimulaAds.initialize` and direct `SimulaProvider` construction mark it; the first call wins.
final class SDKInitializationOrigin: @unchecked Sendable {
    static let shared = SDKInitializationOrigin()

    private let lock = NSLock()
    private var originNanos: UInt64?

    @discardableResult
    func markEntry(nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        lock.lock()
        if originNanos == nil { originNanos = nowNanos }
        let origin = originNanos ?? nowNanos
        lock.unlock()
        return origin
    }

    func timeSinceInitMs(nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Int? {
        lock.lock()
        let origin = originNanos
        lock.unlock()
        guard let origin else { return nil }
        guard nowNanos > origin else { return 0 }
        let milliseconds = (nowNanos - origin) / 1_000_000
        return milliseconds > UInt64(Int.max) ? Int.max : Int(milliseconds)
    }
}
