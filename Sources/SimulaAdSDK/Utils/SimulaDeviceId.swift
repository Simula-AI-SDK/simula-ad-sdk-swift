import Foundation
#if os(iOS)
import UIKit
#endif

/// The vendor/install identifier (`UIDevice.current.identifierForVendor`, IDFV) sent as the
/// `X-Device-Id` header on every native request alongside the custom User-Agent. No permission
/// required, and (unlike the advertising id) not consent-gated — it's a device/vendor identifier,
/// not an ad-tracking id. Reading `value` is always a non-blocking cache snapshot. The synchronous
/// LaunchServices/XPC lookup only runs through `resolve()`: from deferred startup, or from a
/// cooldown-gated request-path retry — always off the calling thread.
enum SimulaDeviceId {
    private static let cache = SimulaDeviceIdCache {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    static var value: String? { cache.value }

    @discardableResult
    static func resolve() -> String? { cache.resolve() }

    /// Request-path retry nudge (mirrors Kotlin `SimulaDeviceId.retryIfNeeded`). Header
    /// construction calls this before reading `value`, so a blank/failed startup resolution gets
    /// another real attempt. Cooldown-gated and dispatched off the calling thread — it never
    /// performs the LaunchServices lookup inline.
    static func retryIfNeeded() { cache.retryIfNeeded() }
}

/// Single-flight, non-waiting cache for a synchronous device-ID resolver. The resolver runs with no
/// lock held; readers never wait for it and simply observe nil until a successful value is published.
/// A nil/blank result resets `resolving` and arms a retry cooldown, so a later startup attempt or a
/// request-path `retryIfNeeded()` may retry — at most one real attempt per `retryDelay` window
/// (mirrors the Kotlin `DeviceIdPrimer` 30 s cooldown).
final class SimulaDeviceIdCache: @unchecked Sendable {
    private let lock = NSLock()
    private let resolver: @Sendable () -> String?
    private let retryDelay: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private var cachedValue: String?
    private var resolving = false
    private var nextRetryAt: TimeInterval = 0

    init(
        retryDelay: TimeInterval = 30,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        },
        resolver: @escaping @Sendable () -> String?
    ) {
        self.resolver = resolver
        self.retryDelay = retryDelay
        self.now = now
        self.schedule = schedule
    }

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return cachedValue
    }

    @discardableResult
    func resolve() -> String? {
        lock.lock()
        if let cachedValue {
            lock.unlock()
            return cachedValue
        }
        if resolving {
            lock.unlock()
            return nil
        }
        resolving = true
        lock.unlock()

        let resolved = resolver().flatMap { $0.isEmpty ? nil : $0 }

        lock.lock()
        if cachedValue == nil { cachedValue = resolved }
        resolving = false
        // A failed attempt arms the cooldown; a coalesced early return above never reaches this
        // line, so only the flight owner sets it (and exactly once per failed attempt).
        if cachedValue == nil { nextRetryAt = now() + retryDelay }
        let snapshot = cachedValue
        lock.unlock()
        return snapshot
    }

    /// Cooldown-gated, non-blocking retry for the request path. The pre-dispatch check is
    /// advisory: `resolve()` re-does single-flight under the lock, so concurrent nudges coalesce
    /// and the loser returns nil without re-arming the cooldown.
    func retryIfNeeded() {
        lock.lock()
        let shouldRetry = cachedValue == nil && !resolving && now() >= nextRetryAt
        lock.unlock()
        guard shouldRetry else { return }
        schedule { [self] in _ = resolve() }
    }
}
