import Foundation
#if os(iOS)
import UIKit
#endif

/// Single-flight lazy cache. Forcing reads wait for the one resolver so request headers remain
/// consistent; resolved-only reads use a try-lock and never wait behind an in-progress platform read.
final class SimulaDeviceIdCache: @unchecked Sendable {
    private let lock = NSLock()
    private let resolver: @Sendable () -> String?
    private var didResolve = false
    private var cachedValue: String?

    init(resolver: @escaping @Sendable () -> String?) {
        self.resolver = resolver
    }

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        if !didResolve {
            cachedValue = resolver()
            didResolve = true
        }
        return cachedValue
    }

    var valueIfResolved: String? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return didResolve ? cachedValue : nil
    }
}

/// The vendor/install identifier (`UIDevice.current.identifierForVendor`, IDFV) sent as the
/// `X-Device-Id` header on every native request alongside the custom User-Agent. No permission
/// required, and (unlike the advertising id) not consent-gated. The forcing `value` accessor is
/// used by startup and request headers; `valueIfResolved` is safe for synchronous UI-facing reads.
enum SimulaDeviceId {
    private static let cache = SimulaDeviceIdCache {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    static var value: String? { cache.value }
    static var valueIfResolved: String? { cache.valueIfResolved }
}
