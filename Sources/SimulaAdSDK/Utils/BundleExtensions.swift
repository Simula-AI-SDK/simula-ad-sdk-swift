import Foundation

#if !SWIFT_PACKAGE
private final class BundleToken {}

extension Bundle {
    static var module: Bundle {
        let bundleName = "SimulaAdSDK"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: BundleToken.self).resourceURL,
            Bundle.main.bundleURL,
        ]
        for candidate in candidates {
            let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
            if let bundle = bundlePath.flatMap(Bundle.init(url:)) {
                return bundle
            }
        }
        return Bundle(for: BundleToken.self)
    }
}
#endif
