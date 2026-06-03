# Simula MiniGame SDK for Swift

A native Swift SDK for integrating sponsored mini-games into iOS and macOS applications built with SwiftUI.

## Key Features

- Sponsored mini-games that users can play with AI characters
- Native SwiftUI components with smooth animations
- Privacy-first design — no IDFA collection, contextual targeting only
- iOS App Store compliant with bundled Privacy Manifest
- SKAdNetwork support for privacy-preserving ad attribution

## Requirements

- iOS 15.0+ / macOS 12.0+
- Swift 5.9+
- Xcode 15.0+

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Simula-AI-SDK/simula-ad-sdk-swift.git", from: "1.0.1")
]
```

Or in Xcode: **File → Add Package Dependencies** and enter the repository URL.

## Quick Start

### 1. Provider Setup

Wrap your app (or the relevant view hierarchy) with `SimulaProviderView`:

```swift
import SimulaAdSDK

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            SimulaProviderView(apiKey: "YOUR_API_KEY", devMode: true) {
                ContentView()
            }
        }
    }
}
```

### 2. MiniGame Menu Integration

Add the mini-game menu to your view:

```swift
import SimulaAdSDK

struct ChatView: View {
    @State private var showGames = false

    var body: some View {
        VStack {
            Button("Play Games") { showGames = true }

            MiniGameMenu(
                isOpen: $showGames,
                onClose: { showGames = false },
                charName: "Luna",
                charID: "char_123",
                charImage: "https://example.com/avatar.png",
                messages: messages
            )
        }
    }
}
```

### 3. Invitation Components

The SDK provides two declarative invite components for triggering the game menu:

```swift
// CTA Button with pulsating animation
MiniGameButton(onClick: { showGames = true })

// Top banner invitation card
MiniGameInvitation(
    charImage: "https://example.com/avatar.png",
    isOpen: showInvitation,
    onClick: { showGames = true },
    onClose: { showInvitation = false }
)
```

### 4. Interstitial Ad (Imperative)

The interstitial is a preloadable full-screen ad with a standard load/show
lifecycle. Initialize the SDK once, preload with `load()`, then present with
`show()` — no arguments. Showing presents a native full-screen creative
(`DISPLAYED`): a swipeable, paged carousel of the prefetched portrait assets with
an always-visible CTA. Tapping the CTA (`CLICKED`) opens the advertiser's
destination — the App Store (in-app store sheet) or a web page (in-app Safari).

```swift
import SimulaAdSDK

// 1. Initialize once at launch (does not require SimulaProviderView).
SimulaAds.initialize(apiKey: "YOUR_API_KEY", devMode: true)

// 2. Create, configure, and preload.
final class GameAds: SimulaInterstitialAdDelegate {
    let interstitial = SimulaInterstitialAd(adUnitId: "your_placement_id")

    init() {
        interstitial.delegate = self
        interstitial.ctaText = "Learn More"   // optional, defaults to "Learn More"
        interstitial.load()
    }

    func showAd() {
        interstitial.show()
    }

    // 3. Lifecycle events (all optional):
    func interstitialDidLoad(_ ad: SimulaInterstitialAd) { /* ready to show */ }
    func interstitialDidFailToLoad(_ ad: SimulaInterstitialAd, error: SimulaAdError) {}
    func interstitialDidDisplay(_ ad: SimulaInterstitialAd) {}
    func interstitialDidFailToDisplay(_ ad: SimulaInterstitialAd, error: SimulaAdError) {}
    func interstitialDidClick(_ ad: SimulaInterstitialAd) { /* CTA tapped → opens advertiser destination */ }
    func interstitialDidClose(_ ad: SimulaInterstitialAd) { /* next ad auto-preloads */ }
}
```

**Rewarded ads**

Set `rewarded = true` and a `minPlayThreshold` (seconds) to request a rewarded
creative. The close button stays hidden until the threshold elapses; once the user
dismisses the ad after that point, `EARNED_REWARD` fires. A click-through on a
rewarded ad does **not** auto-dismiss — the view gate governs close and reward.

```swift
let rewarded = SimulaInterstitialAd(adUnitId: "your_placement_id", minPlayThreshold: 5)
rewarded.delegate = self
rewarded.rewarded = true
rewarded.load()
// later, once LOADED:
rewarded.show()

func interstitialDidEarnReward(_ ad: SimulaInterstitialAd) { /* grant the reward */ }
```

**Lifecycle notes**

- A single load is in flight per instance; the next ad is preloaded automatically
  after `CLOSED`.
- `load()` fails fast with `.notInitialized` if `SimulaAds.initialize` was not called,
  or `.noFill` when no creative is available.
- The CTA label is configurable via `ctaText` (defaults to `"Learn More"`). A single
  asset renders without paging dots; multiple assets render as a paged carousel.
- A non-rewarded ad auto-dismisses (firing `CLOSED`) after a CTA tap. `CLICKED` fires
  on tap regardless of whether the store/web open succeeds.
- Imperative presentation is iOS-only; on other platforms `show()` reports
  `DISPLAY_FAILED(.unsupportedPlatform)`.

| Event | Delegate method |
|-------|-----------------|
| LOADED | `interstitialDidLoad(_:)` |
| LOAD_FAILED | `interstitialDidFailToLoad(_:error:)` |
| DISPLAYED | `interstitialDidDisplay(_:)` |
| DISPLAY_FAILED | `interstitialDidFailToDisplay(_:error:)` |
| CLICKED | `interstitialDidClick(_:)` |
| EARNED_REWARD | `interstitialDidEarnReward(_:)` |
| CLOSED | `interstitialDidClose(_:)` |
| REWARD_VERIFICATION_FAILED\* | `interstitialRewardVerificationDidFail(_:)` |

\* Reserved — not emitted yet.

## Components

| Component | Description |
|-----------|-------------|
| `SimulaProviderView` | Required wrapper that manages API session and state |
| `MiniGameMenu` | Modal game catalog with search, pagination, and ad display. Requires `onClose` callback. |
| `MiniGameButton` | Animated CTA button to launch the game menu |
| `MiniGameInvitation` | Slide-in banner card with character image |
| `SimulaAds` | Global entry point — `initialize(apiKey:)` for the imperative API |
| `SimulaInterstitialAd` | Imperative preloadable full-screen interstitial ad |

## Theming

All components accept theme objects for customization:

```swift
let menuTheme = MiniGameTheme(
    backgroundColor: "#1a1a2e",
    headerColor: "#16213e",
    titleFontColor: "#ffffff",
    accentColor: "#e94560"
)

MiniGameMenu(
    isOpen: $showGames,
    onClose: { showGames = false },
    charName: "Luna",
    charID: "char_123",
    charImage: "https://example.com/avatar.png",
    theme: menuTheme
)
```

See `MiniGameTheme`, `MiniGameInvitationTheme`, and `MiniGameButtonTheme` for all available properties. The imperative `SimulaInterstitialAd` renders the advertiser's native creative assets directly; its only customization is the CTA label (`ctaText`).

## Privacy & App Store Compliance

This SDK is designed to be App Store compliant out of the box.

### What's Included

| File | Purpose |
|------|---------|
| `PrivacyInfo.xcprivacy` | iOS 17+ Privacy Manifest (bundled automatically via SPM) |
| `docs/SKAdNetworkItems.plist` | SKAdNetwork identifiers for `Info.plist` |
| `docs/IOS_APP_PRIVACY.md` | Complete App Store privacy label guide |

### Privacy Manifest (Automatic)

The `PrivacyInfo.xcprivacy` is bundled as a package resource and automatically included when you add the SDK via Swift Package Manager. No manual setup required.

### SKAdNetwork Setup

Copy the SKAdNetwork identifiers from `docs/SKAdNetworkItems.plist` into your app's `Info.plist` to enable privacy-preserving ad attribution. See [docs/IOS_APP_PRIVACY.md](docs/IOS_APP_PRIVACY.md) for detailed instructions.

### Data Practices Summary

| Practice | Status |
|----------|--------|
| Cross-app tracking | **No** |
| IDFA collection | **No** |
| User-linked data | **No** |
| Privacy Manifest | **Included** |
| Contextual targeting | **Yes** (content-based, not user-based) |

### Data Collected

- Conversation context (messages) for contextual ad targeting
- Ad interaction events (impressions, clicks)
- Temporary session identifiers (not linked to identity)
- Device type and screen dimensions

### Data NOT Collected

- Apple Advertising Identifier (IDFA)
- Location data
- Personal information (name, email, phone)
- Contacts, photos, or browsing history

For the full App Store privacy guide, see [docs/IOS_APP_PRIVACY.md](docs/IOS_APP_PRIVACY.md).

## Documentation

For complete documentation including all props, theming options, and advanced usage, visit:

[Full Documentation](https://simula-ad.notion.site/Simula-x-Dippy-Swift-Mini-Games-SDK-Overview-321af70f6f0d801ea116d754424f10dd?pvs=73)

## Support

- Email: admin@simula.ad
- Website: [simula.ad](https://simula.ad)

## License

MIT
