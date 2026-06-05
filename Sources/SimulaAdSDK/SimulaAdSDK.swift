// SimulaAdSDK — Public API Surface
//
// Two distinct full-screen surfaces coexist:
//  • Declarative `MiniGameInterstitial` — a SwiftUI overlay that invites the user to
//    play a mini-game (also grouped under `MiniGameInviteKit.Interstitial`).
//  • Imperative `SimulaInterstitialAd` — a preloadable native ad, initialized via
//    `SimulaAds.initialize(apiKey:)`.
// The mini-game invite components are exported from their respective files.

import SwiftUI

// MARK: - MiniGameInviteKit (grouped access for the declarative invite components)

/// Grouped access to the declarative mini game invite components.
///
/// Usage:
/// ```swift
/// MiniGameInviteKit.Invitation(...)
/// MiniGameInviteKit.Button(...)
/// MiniGameInviteKit.Interstitial(...)
/// ```
///
/// Note: `MiniGameInviteKit.Interstitial` is the *declarative* mini-game invite
/// overlay. For the *imperative* native interstitial ad, use `SimulaInterstitialAd`
/// (configured with `SimulaAds.initialize(apiKey:)`).
public enum MiniGameInviteKit {
    public typealias Invitation = MiniGameInvitation
    public typealias Button = MiniGameButton
    public typealias Interstitial = MiniGameInterstitial
}
