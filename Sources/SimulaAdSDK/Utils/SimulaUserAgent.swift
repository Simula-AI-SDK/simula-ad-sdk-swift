import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds (once) and caches the custom User-Agent the SDK stamps on every native HTTP request
/// (User-Agent for Apps SDK PRD). Format is the standard ad-SDK layout:
///
/// ```
/// Simula-SDK/{sdkVersion} ({os} {osVersion}; {locale}; {deviceModel}; Build/{buildId}; {bundleId})
/// ```
///
/// e.g. `Simula-SDK/1.0.2 (iOS 17.2; en_US; iPhone16,1; Build/21C52; com.publisher.app)`
///
/// Every field comes from `Foundation` / `Bundle` / `uname` / `sysctl` — no permissions, no UIKit.
/// `value` is a lazily-initialized `static let`, so it self-constructs on first access (the
/// `SimulaAPI` shared session config reads it, and the SDK forces it eagerly at `SimulaAds.initialize`).
enum SimulaUserAgent {

    /// The composed UA string. Computed once, thread-safe via `static let` lazy init.
    static let value: String = build()

    /// The SDK's standard request headers stamped on every outbound request: the custom User-Agent
    /// plus the `X-Device-Id` device identifier (omitted when the platform supplies none).
    static func standardHeaders() -> [String: String] {
        var headers = ["User-Agent": value]
        if let deviceId = SimulaDeviceId.value { headers["X-Device-Id"] = deviceId }
        return headers
    }

    /// A `.default` URLSession configuration for the ancillary CTA / redirect-tracker sessions
    /// (not `SimulaAPI`'s shared session). Stamps a Safari-style mobile User-Agent instead of the
    /// custom `Simula-SDK/...` UA — and omits `X-Device-Id` — so the click Adjust/AppsFlyer
    /// fingerprints for probabilistic attribution reads like a genuine mobile Safari/WebView
    /// navigation rather than an SDK request. Telemetry / first-party API sessions are unaffected;
    /// they keep the custom UA + device id via `standardHeaders()`.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": safariUserAgent]
        // Bound these ancillary CTA / redirect-tracker sessions like SimulaAPI's main session, so a
        // connection that stalls can't keep the resolver (and its captured session/delegate) alive for
        // the 7-day system default — the resource timeout guarantees didCompleteWithError fires.
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return config
    }

    /// The interface-idiom families the Safari-UA composer distinguishes. Kept as an explicit enum
    /// (rather than a binary iPad/iPhone flag) so a `switch` covers every idiom UIKit can report —
    /// iPhone, iPad, Mac (Catalyst / Designed-for-iPad on Apple Silicon), and the rest — and any
    /// future idiom lands on `.unknown` instead of silently masquerading as an iPhone.
    enum DeviceFamily {
        case phone
        case pad
        case mac
        case tv
        case carPlay
        case unknown
    }

    /// A WebKit/Safari-style mobile User-Agent, built once and cached. Used only for the CTA /
    /// redirect-resolver click (Adjust User-Agent for Apps PRD): Adjust's probabilistic matching
    /// pairs the click's IP + UA against the UA the Adjust SDK reports at install, and a custom
    /// `Simula-SDK/...` UA doesn't resemble the device's standard UA, degrading match confidence.
    ///
    /// The device-family token matches the running device so the click UA resembles that device's
    /// genuine Safari UA:
    /// - iPhone: `Mozilla/5.0 (iPhone; CPU iPhone OS {osVersion} like Mac OS X) AppleWebKit/605.1.15
    ///   (KHTML, like Gecko) Mobile/15E148`
    /// - iPad:   `Mozilla/5.0 (iPad; CPU OS {osVersion} like Mac OS X) AppleWebKit/605.1.15
    ///   (KHTML, like Gecko) Mobile/15E148`
    /// - Mac:    `Mozilla/5.0 (Macintosh; Intel Mac OS X {osVersion} …)` (Mac Catalyst /
    ///   Designed-for-iPad on Apple Silicon).
    ///
    /// The WebKit/Mobile build numbers are fixed shared constants (they don't vary meaningfully across
    /// the OS versions this SDK targets), so only the OS version + device family are live.
    static let safariUserAgent: String = composeSafariUserAgent(
        family: deviceFamily,
        osVersionUnderscore: safariOSVersionString()
    )

    /// Pure assembly of the Safari-style UA, split out so every device family is unit-testable
    /// without a real device. iPad uses `iPad; CPU OS …` (no `iPhone`); Mac uses the desktop
    /// `Macintosh; Intel Mac OS X …` token; everything else falls back to the iPhone token so the
    /// attribution UA stays a plausible mobile Safari string.
    static func composeSafariUserAgent(family: DeviceFamily, osVersionUnderscore: String) -> String {
        switch family {
        case .pad:
            let platform = "iPad; CPU OS \(osVersionUnderscore)"
            return "Mozilla/5.0 (\(platform) like Mac OS X) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        case .mac:
            let platform = "Macintosh; Intel Mac OS X \(osVersionUnderscore)"
            return "Mozilla/5.0 (\(platform)) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        case .phone, .tv, .carPlay, .unknown:
            let platform = "iPhone; CPU iPhone OS \(osVersionUnderscore)"
            return "Mozilla/5.0 (\(platform) like Mac OS X) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }
    }

    /// The running device's interface idiom, resolved once via a `switch` so every case UIKit can
    /// report is handled explicitly. `.phone` on non-iOS (test/host) builds.
    private static let deviceFamily: DeviceFamily = {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return .phone
        case .pad: return .pad
        case .mac: return .mac
        case .tv: return .tv
        case .carPlay: return .carPlay
        // `.unspecified`, `.vision`, and any idiom added in a future SDK land here.
        @unknown default: return .unknown
        }
        #else
        return .phone
        #endif
    }()

    /// Underscore-separated OS version (`17_2`), matching Safari's UA convention (vs. the
    /// dotted `17.2` the custom UA uses).
    private static func safariOSVersionString() -> String {
        osVersionString().replacingOccurrences(of: ".", with: "_")
    }

    /// Hardware model identifier (e.g. `iPhone16,1`) via `uname`. Shared with telemetry so the two
    /// surfaces always report the same model.
    static func deviceModelIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let model = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: Array(bytes))
        }
        return model.isEmpty ? "unknown" : model
    }

    private static func build() -> String {
        compose(
            sdkVersion: SIMULA_SDK_VERSION,
            osVersion: osVersionString(),
            locale: localeString(),
            deviceModel: deviceModelIdentifier(),
            buildId: osBuildId(),
            bundleId: Bundle.main.bundleIdentifier ?? "unknown"
        )
    }

    /// Pure assembly, split out so it's unit-testable without the device statics.
    static func compose(
        sdkVersion: String,
        osVersion: String,
        locale: String,
        deviceModel: String,
        buildId: String,
        bundleId: String
    ) -> String {
        "Simula-SDK/\(sdkVersion) (iOS \(osVersion); \(locale); \(deviceModel); Build/\(buildId); \(bundleId))"
    }

    /// OS version as `major.minor` (or `major.minor.patch` when patch > 0), matching the PRD's `17.2`.
    private static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Underscore locale (en_US) per the PRD — not the hyphenated BCP-47 tag.
    private static func localeString() -> String {
        let loc = Locale.current
        let lang: String
        let region: String
        if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
            lang = loc.language.languageCode?.identifier ?? "und"
            region = loc.region?.identifier ?? ""
        } else {
            lang = loc.languageCode ?? "und"
            region = loc.regionCode ?? ""
        }
        return region.isEmpty ? lang : "\(lang)_\(region)"
    }

    /// OS build number (e.g. `21C52`) via the `kern.osversion` sysctl.
    private static func osBuildId() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }
}
