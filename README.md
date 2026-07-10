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

## Installation

From 1.1.4 the SDK ships as a **prebuilt, module-stable XCFramework** (dSYMs embedded). Your
Xcode links it but never compiles SDK source — this insulates host apps from Swift-toolchain
optimizer bugs and keeps build times down.

**Swift Package Manager** — pin a version; release tags resolve to the binary artifact:

```swift
.package(url: "https://github.com/Simula-AI-SDK/simula-ad-sdk-swift.git", from: "1.1.4")
```

**CocoaPods:**

```ruby
pod 'SimulaAdSDK', '~> 1.1.4'
```

Building from source remains possible (depend on the `main` branch, which keeps the source
manifest), but is not recommended for production: source builds re-expose your app to the
Swift 6.1–6.3 optimizer task-teardown bug the binary distribution exists to avoid.

## Getting Started

Full integration guides, API references, and examples are available at:

**[docs.simula.ad/swift-sdk](https://docs.simula.ad/swift-sdk/quick-start)**

- [Quick Start](https://docs.simula.ad/swift-sdk/quick-start) -- installation, provider setup, privacy, ATT, and error handling
- [NativeAdSlot](https://docs.simula.ad/swift-sdk/native-ad-slot) -- inline ad view
- [Interstitial Ad](https://docs.simula.ad/swift-sdk/interstitial-ad) -- full-screen ad
- [Rewarded Ad](https://docs.simula.ad/swift-sdk/rewarded-ad) -- rewarded ad with server-side verification

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
