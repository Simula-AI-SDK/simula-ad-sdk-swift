// SimulaAdSDK — Public API Surface
//
// The mini-game invite components (Invitation, Button) are exported from their
// respective files. The interstitial is an imperative ad (`SimulaInterstitialAd`),
// initialized via `SimulaAds.initialize(apiKey:)` — see those types.

import SwiftUI

// MARK: - MiniGameInviteKit (grouped access for the declarative invite components)

/// Grouped access to the declarative mini game invite components.
///
/// Usage:
/// ```swift
/// MiniGameInviteKit.Invitation(...)
/// MiniGameInviteKit.Button(...)
/// ```
///
/// The interstitial is no longer a declarative view. Use the imperative
/// `SimulaInterstitialAd` (configured with `SimulaAds.initialize(apiKey:)`) instead.
public enum MiniGameInviteKit {
    public typealias Invitation = MiniGameInvitation
    public typealias Button = MiniGameButton
}
