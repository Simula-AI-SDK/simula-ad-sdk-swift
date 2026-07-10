import SwiftUI
import SimulaAdSDK

/// Compile-and-link smoke over the SDK's public surface, exercised through the binary
/// `.swiftinterface`. Nothing here runs — building this target is the test. Touches one
/// symbol from each public area so a symbol dropped from the artifact fails the release,
/// not a host integration.
enum BinarySmoke {
    @MainActor
    static func exercise() {
        _ = SimulaAds.initialize(apiKey: "smoke-key", telemetryEnabled: false)
        _ = SimulaAds.isInitialized

        let interstitial = SimulaInterstitialAd(adUnitId: "smoke-unit")
        interstitial.load()

        let rewarded = SimulaRewardedAd(adUnitId: "smoke-unit")
        rewarded.load()
    }

    @MainActor
    @ViewBuilder
    static func views() -> some View {
        SimulaProviderView(apiKey: "smoke-key") {
            NativeAdSlot(adUnitId: "smoke-unit", position: 0)
        }
    }
}
