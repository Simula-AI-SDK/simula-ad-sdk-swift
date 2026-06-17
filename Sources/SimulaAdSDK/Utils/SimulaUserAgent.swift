import Foundation

/// Builds (once) and caches the custom User-Agent the SDK stamps on every native HTTP request
/// (User-Agent for Apps SDK PRD). Format is AdMob-aligned:
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

    /// A `.default` URLSession configuration carrying the standard headers, for the ancillary
    /// sessions (CTA / tracker clicks) that don't go through `SimulaAPI`'s shared session.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = standardHeaders()
        // Bound these ancillary CTA / redirect-tracker sessions like SimulaAPI's main session, so a
        // connection that stalls can't keep the resolver (and its captured session/delegate) alive for
        // the 7-day system default — the resource timeout guarantees didCompleteWithError fires.
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return config
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
