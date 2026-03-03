// SimulaAdSDK — Public API Surface
// Translates `index.ts` from the React SDK.
//
// All public types and views are exported from their respective files.
// This file provides the MiniGameInviteKit namespace for grouped access,
// matching React's:
//   export const MiniGameInviteKit = { Invitation, Button, Interstitial }

import SwiftUI

// MARK: - MiniGameInviteKit (matching React's grouped export)

/// Grouped access to mini game invite components.
///
/// Usage:
/// ```swift
/// MiniGameInviteKit.Invitation(...)
/// MiniGameInviteKit.Button(...)
/// MiniGameInviteKit.Interstitial(...)
/// ```
public enum MiniGameInviteKit {
    public typealias Invitation = MiniGameInvitation
    public typealias Button = MiniGameButton
    public typealias Interstitial = MiniGameInterstitial
}
