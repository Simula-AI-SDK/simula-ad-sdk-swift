# Simula Ad SDK for iOS

AI-powered native ads, interstitial ads, and rewarded ads for iOS apps using SwiftUI.

Simula delivers ads that feel native to AI chat and character-driven applications. The SDK handles ad rendering, contextual targeting, privacy compliance, and server-side reward verification out of the box.

## Ad Formats

| Format | Description |
|---|---|
| **NativeAdSlot** | Inline ad card that fits naturally into SwiftUI layouts |
| **Interstitial Ad** | Full-screen ad with preload/show lifecycle |
| **Rewarded Ad** | Play-to-earn ad with server-side reward verification |

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15+

## Getting Started

Full integration guides, API references, and examples are available at:

**[docs.simula.ad/swift-sdk](https://docs.simula.ad/swift-sdk/quick-start)**

- [Quick Start](https://docs.simula.ad/swift-sdk/quick-start) -- installation, provider setup, privacy, ATT, and error handling
- [NativeAdSlot](https://docs.simula.ad/swift-sdk/native-ad-slot) -- inline ad view
- [Interstitial Ad](https://docs.simula.ad/swift-sdk/interstitial-ad) -- full-screen ad
- [Rewarded Ad](https://docs.simula.ad/swift-sdk/rewarded-ad) -- rewarded ad with server-side verification

## Publisher Metadata

Publisher metadata is scoped to an individual ad load. The SDK snapshots the normalized values when
the load begins and uses that same snapshot for the load request and the impression's billable
`/seen` beacon. Updating metadata after `load()` does not alter an already loaded ad.

```swift
let interstitial = SimulaInterstitialAd(adUnitId: "home")
interstitial.setMetadata(["placement": "home", "surface": "feed"])
interstitial.load()

NativeAdSlot(
    adUnitId: "chat",
    metadata: ["conversation_type": "group"]
)
```

Metadata accepts at most 10 entries. Keys must be non-empty, at most 64 Unicode scalars, must not
start with `$`, and must not contain `.`. Values are limited to 256 Unicode scalars. Invalid or excess
entries are ignored without failing the ad load. `SimulaRewardedAd` exposes the same
`setMetadata(_:_:)` and `setMetadata(_:)` overloads as `SimulaInterstitialAd`. The current native
preload API has no metadata argument, so mounting a `preloadedAdId` does not retroactively attach the
slot's metadata to that already loaded impression.

## Privacy & App Store Compliance

The SDK bundles a `PrivacyInfo.xcprivacy` manifest and supports IAB consent frameworks (TCF, CCPA, GPP), COPPA, and App Tracking Transparency. See the [Quick Start guide](https://docs.simula.ad/swift-sdk/quick-start#privacy-att) for details.

## Dashboard

Create and manage ad units, view analytics, and configure server-side verification at [publisher.simula.ad](https://publisher.simula.ad).

## Support

- Documentation: [docs.simula.ad](https://docs.simula.ad)
- Email: admin@simula.ad
- Website: [simula.ad](https://simula.ad)

## License

MIT
