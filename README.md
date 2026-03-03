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
    .package(url: "https://github.com/Simula-AI-SDK/simula-ad-sdk-swift.git", from: "1.0.0")
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
    @EnvironmentObject var provider: SimulaProvider
    @State private var showGames = false

    var body: some View {
        VStack {
            Button("Play Games") { showGames = true }

            MiniGameMenu(
                isOpen: $showGames,
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

The SDK provides three invite components for triggering the game menu:

```swift
// CTA Button with pulsating animation
MiniGameInviteKit.Button(onClick: { showGames = true })

// Top banner invitation card
MiniGameInviteKit.Invitation(
    isOpen: $showInvitation,
    onPlay: { showGames = true },
    charName: "Luna",
    charImage: "https://example.com/avatar.png"
)

// Full-screen interstitial overlay
MiniGameInviteKit.Interstitial(
    isOpen: $showInterstitial,
    onPlay: { showGames = true },
    charName: "Luna",
    charImage: "https://example.com/avatar.png"
)
```

## Components

| Component | Description |
|-----------|-------------|
| `SimulaProviderView` | Required wrapper that manages API session and state |
| `MiniGameMenu` | Modal game catalog with search, pagination, and ad display |
| `MiniGameButton` | Animated CTA button to launch the game menu |
| `MiniGameInvitation` | Slide-in banner card with character image |
| `MiniGameInterstitial` | Full-screen overlay invitation |

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
    charName: "Luna",
    charID: "char_123",
    theme: menuTheme
)
```

See `MiniGameTheme`, `MiniGameInvitationTheme`, `MiniGameButtonTheme`, and `MiniGameInterstitialTheme` for all available properties.

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

[Full Documentation](https://simula-ad.notion.site/Simula-x-Saylo-Minigame-SDK-2f4af70f6f0d804e805dcb2726f29079)

## Support

- Email: admin@simula.ad
- Website: [simula.ad](https://simula.ad)

## License

MIT
