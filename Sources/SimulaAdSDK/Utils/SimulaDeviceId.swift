import Foundation
#if os(iOS)
import UIKit
#endif

/// The vendor/install identifier (`UIDevice.current.identifierForVendor`, IDFV) sent as the
/// `X-Device-Id` header on every native request alongside the custom User-Agent. No permission
/// required, and (unlike the advertising id) not consent-gated — it's a device/vendor identifier,
/// not an ad-tracking id. `value` is a lazily-initialized `static let`; nil when the platform can't
/// supply one (e.g. before first unlock, or non-iOS test builds), in which case the header is omitted.
enum SimulaDeviceId {
    static let value: String? = {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }()
}
