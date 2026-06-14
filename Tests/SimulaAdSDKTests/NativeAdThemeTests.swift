import XCTest
@testable import SimulaAdSDK

/// Tests for `NativeAdTheme.resolve` — the client-side `"system"` → `"dark"`/`"light"` resolution
/// behind `NativeAdSlot(theme:)` and `SimulaAds.preloadNativeAd(theme:)`. The appearance source
/// (SwiftUI `colorScheme` vs `UITraitCollection`) is supplied as `isDark`, so the logic is pure.
final class NativeAdThemeTests: XCTestCase {

    func testNilStaysNil() {
        XCTAssertNil(NativeAdTheme.resolve(nil, isDark: true))
        XCTAssertNil(NativeAdTheme.resolve(nil, isDark: false))
    }

    func testSystemResolvesToDarkWhenDark() {
        XCTAssertEqual(NativeAdTheme.resolve("system", isDark: true), "dark")
    }

    func testSystemResolvesToLightWhenLight() {
        XCTAssertEqual(NativeAdTheme.resolve("system", isDark: false), "light")
    }

    func testDarkPassesThroughRegardlessOfAppearance() {
        XCTAssertEqual(NativeAdTheme.resolve("dark", isDark: false), "dark")
        XCTAssertEqual(NativeAdTheme.resolve("dark", isDark: true), "dark")
    }

    func testLightPassesThroughRegardlessOfAppearance() {
        XCTAssertEqual(NativeAdTheme.resolve("light", isDark: true), "light")
        XCTAssertEqual(NativeAdTheme.resolve("light", isDark: false), "light")
    }
}
