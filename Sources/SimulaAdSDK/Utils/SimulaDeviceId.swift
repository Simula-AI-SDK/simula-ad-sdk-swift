import Foundation
#if os(iOS)
import UIKit
#endif

/// The vendor/install identifier (`UIDevice.current.identifierForVendor`, IDFV) sent as the
/// `X-Device-Id` header on every native request alongside the custom User-Agent. No permission
/// required, and (unlike the advertising id) not consent-gated — it's a device/vendor identifier,
/// not an ad-tracking id. Reading `value` is always a non-blocking cache snapshot. The synchronous
/// LaunchServices/XPC lookup only runs through `resolve()`, from deferred startup off the main thread.
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
}

/// Single-flight, non-waiting cache for a synchronous device-ID resolver. The resolver runs with no
/// lock held; readers never wait for it and simply observe nil until a successful value is published.
/// A nil/blank result resets `resolving`, so a later startup attempt may retry.
final class SimulaDeviceIdCache: @unchecked Sendable {
    private let lock = NSLock()
    private let resolver: @Sendable () -> String?
    private var cachedValue: String?
    private var resolving = false

    init(resolver: @escaping @Sendable () -> String?) {
        self.resolver = resolver
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
        let snapshot = cachedValue
        lock.unlock()
        return snapshot
    }
}
