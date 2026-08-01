// No platform guard: pure policy, unit-tested on macOS (the pool itself is iOS-only).

/// Startup-prewarm memory policy. A warm `WKWebView` spins up the WebContent process and
/// holds tens of MB before any ad exists — on the oldest supported devices that's a poor
/// trade at app launch, so the *startup* prewarm (only) is skipped at or below this floor.
/// Normal pooling after an ad request is never gated: by then an ad exists and wants the
/// warm view. Mirrors Android's `isLowRamDevice` skip (see `shouldSkipStartupPrewarm`).
enum WebViewPrewarmPolicy {
    /// 2 GiB — the memory floor of the oldest devices that can run the SDK's minimum iOS
    /// (iPhone 6s / 7 / 8 / SE 1st gen report ~2 GiB); anything at or below skips.
    static let startupMemoryFloorBytes: UInt64 = 2_147_483_648

    static func shouldSkipStartupPrewarm(physicalMemoryBytes: UInt64) -> Bool {
        physicalMemoryBytes <= startupMemoryFloorBytes
    }
}
