import Foundation
import SwiftUI

// MARK: - Message

/// A chat message with role and content (translates `Message` from types.ts)
public struct Message: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case role, content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.role = try container.decode(String.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
    }
}

// MARK: - AdData

/// Represents a single ad returned by the server (translates `AdData` from types.ts)
public struct AdData: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let format: String
    public let iframeUrl: String?
    public let html: String?

    public init(id: String, format: String, iframeUrl: String? = nil, html: String? = nil) {
        self.id = id
        self.format = format
        self.iframeUrl = iframeUrl
        self.html = html
    }

    enum CodingKeys: String, CodingKey {
        case id, format
        case iframeUrl = "iframe_url"
        case html
    }
}

// MARK: - GameData

/// A single game in the catalog (translates `GameData` from types.ts)
public struct GameData: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let iconUrl: String
    public let description: String
    public let iconFallback: String?
    public let gifCover: String?

    public init(id: String, name: String, iconUrl: String, description: String, iconFallback: String? = nil, gifCover: String? = nil) {
        self.id = id
        self.name = name
        self.iconUrl = iconUrl
        self.description = description
        self.iconFallback = iconFallback
        self.gifCover = gifCover
    }
}

// MARK: - CharacterData

/// A selectable character in `CharacterSelector`. `imageUrl` is a 1:1 portrait URL.
/// Maps to the backend `PublicCharacter` (`character_id`→id, `character_name`→name,
/// `images_1_1[0]`/`avatar_url`→imageUrl, `description`→description).
public struct CharacterData: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let imageUrl: String
    public let description: String

    public init(id: String, name: String, imageUrl: String, description: String) {
        self.id = id
        self.name = name
        self.imageUrl = imageUrl
        self.description = description
    }
}

// MARK: - CharacterSelectorTheme

/// Theme for `CharacterSelector`. Colors are CSS strings (hex/rgba); a nil field falls
/// back to a `resolved*` value mirroring the reference HTML. Sizes are in points.
public struct CharacterSelectorTheme: Sendable, Equatable {
    /// Sheet/page background. Default `#000000`.
    public var backgroundColor: String?
    /// Title heading color. Default `#FFFFFF`.
    public var titleFontColor: String?
    /// Character name label color. Default `#FFFFFF`.
    public var secondaryFontColor: String?
    /// Selected-card border, active CTA bg + border, and glow. Default `#3D9A66`.
    public var accentColor: String?
    /// CTA button text (active). Default `#FFFFFF`.
    public var ctaFontColor: String?
    /// Card fill. Default `#14161A`.
    public var cardBackgroundColor: String?
    /// Default card border. Default `#343A42`.
    public var cardBorderColor: String?
    /// Card corner radius in points. Default `18`.
    public var cardCornerRadius: CGFloat?
    /// Font family name (e.g. "Inter"). Default: system font.
    public var fontFamily: String?

    public init(
        backgroundColor: String? = nil,
        titleFontColor: String? = nil,
        secondaryFontColor: String? = nil,
        accentColor: String? = nil,
        ctaFontColor: String? = nil,
        cardBackgroundColor: String? = nil,
        cardBorderColor: String? = nil,
        cardCornerRadius: CGFloat? = nil,
        fontFamily: String? = nil
    ) {
        self.backgroundColor = backgroundColor
        self.titleFontColor = titleFontColor
        self.secondaryFontColor = secondaryFontColor
        self.accentColor = accentColor
        self.ctaFontColor = ctaFontColor
        self.cardBackgroundColor = cardBackgroundColor
        self.cardBorderColor = cardBorderColor
        self.cardCornerRadius = cardCornerRadius
        self.fontFamily = fontFamily
    }

    // Resolved defaults mirror the reference "Select Your Game Partner" HTML.
    public var resolvedBackgroundColor: String { backgroundColor ?? "#000000" }
    public var resolvedTitleFontColor: String { titleFontColor ?? "#FFFFFF" }
    public var resolvedSecondaryFontColor: String { secondaryFontColor ?? "#FFFFFF" }
    public var resolvedAccentColor: String { accentColor ?? "#3D9A66" }
    public var resolvedCtaFontColor: String { ctaFontColor ?? "#FFFFFF" }
    public var resolvedCardBackgroundColor: String { cardBackgroundColor ?? "#14161A" }
    public var resolvedCardBorderColor: String { cardBorderColor ?? "#343A42" }
    public var resolvedCardCornerRadius: CGFloat { cardCornerRadius ?? 18 }
    /// nil → system font (matches the HTML's `-apple-system` stack).
    public var resolvedFontFamily: String? { fontFamily }
}

// MARK: - PlayableHeight

/// Represents the height of the Mini Game iframe in bottom sheet mode.
/// Matches Kotlin's `Any?` pattern which accepts Number (px), String (%), or null (fullscreen).
public enum PlayableHeight: Sendable, Equatable {
    /// Fixed pixel height (minimum 500px enforced)
    case pixels(CGFloat)
    /// Percentage of screen height (0.0–1.0, minimum 500px enforced)
    case percent(Double)
}

// MARK: - MiniGameTheme

/// Theme configuration for the MiniGameMenu (translates `MiniGameTheme` from types.ts)
public struct MiniGameTheme: Sendable, Equatable {
    public var backgroundColor: String?
    public var headerColor: String?
    public var borderColor: String?
    public var titleFont: String?
    public var secondaryFont: String?
    public var titleFontColor: String?
    public var secondaryFontColor: String?
    public var iconCornerRadius: CGFloat?
    /// Unified accent color for interactive elements (search bar focus, pagination). Default: '#3B82F6'
    public var accentColor: String?
    /// Controls the height of the Mini Game iframe.
    /// - `.pixels(CGFloat)`: fixed pixel height (minimum 500px)
    /// - `.percent(Double)`: percentage of screen height (0.0–1.0)
    /// - `nil`: full screen (default behavior)
    public var playableHeight: PlayableHeight?
    /// Controls the background color of the curved border area above the playable
    /// when playableHeight is set (bottom sheet mode). Default: '#262626'
    public var playableBorderColor: String?

    public init(
        backgroundColor: String? = nil,
        headerColor: String? = nil,
        borderColor: String? = nil,
        titleFont: String? = nil,
        secondaryFont: String? = nil,
        titleFontColor: String? = nil,
        secondaryFontColor: String? = nil,
        iconCornerRadius: CGFloat? = nil,
        accentColor: String? = nil,
        playableHeight: PlayableHeight? = nil,
        playableBorderColor: String? = nil
    ) {
        self.backgroundColor = backgroundColor
        self.headerColor = headerColor
        self.borderColor = borderColor
        self.titleFont = titleFont
        self.secondaryFont = secondaryFont
        self.titleFontColor = titleFontColor
        self.secondaryFontColor = secondaryFontColor
        self.iconCornerRadius = iconCornerRadius
        self.accentColor = accentColor
        self.playableHeight = playableHeight
        self.playableBorderColor = playableBorderColor
    }

    // Resolved defaults matching React's defaultTheme
    public var resolvedTitleFont: String { titleFont ?? "Inter" }
    public var resolvedSecondaryFont: String { secondaryFont ?? "Inter" }
    public var resolvedTitleFontColor: String { titleFontColor ?? "#ffffff" }
    public var resolvedSecondaryFontColor: String { secondaryFontColor ?? "rgba(255, 255, 255, 0.75)" }
    public var resolvedIconCornerRadius: CGFloat { iconCornerRadius ?? 8 }
    public var resolvedBorderColor: String { borderColor ?? "rgba(255, 255, 255, 0.06)" }
    public var resolvedAccentColor: String { accentColor ?? "#3B82F6" }
    public var resolvedBackgroundColor: String { backgroundColor ?? "#0b0b0f" }
    public var resolvedPlayableBorderColor: String { playableBorderColor ?? "#262626" }
}

// MARK: - MiniGameInvitationAnimation

/// Animation type for MiniGameInvitation entry/exit (translates `MiniGameInvitationAnimation` from types.ts)
public enum MiniGameInvitationAnimation: String, Sendable, Equatable {
    case auto
    case slideDown
    case slideUp
    case fadeIn
    case none
}

// MARK: - MiniGameInvitationTheme

/// Theme configuration for MiniGameInvitation (translates `MiniGameInvitationTheme` from types.ts)
public struct MiniGameInvitationTheme: Sendable, Equatable {
    public var cornerRadius: CGFloat?
    public var backgroundColor: String?
    /// Fallback text color used when individual colors are not set
    public var textColor: String?
    /// Title text color. Falls back to `textColor` then `#FFFFFF`.
    public var titleTextColor: String?
    /// Subtitle text color. Falls back to `textColor` then `#FFFFFF`.
    public var subTextColor: String?
    /// CTA button text color. Falls back to `textColor` then `#FFFFFF`.
    public var ctaTextColor: String?
    public var ctaColor: String?
    public var charImageCornerRadius: CGFloat?
    /// Which side the character image appears on. Default: 'left'.
    public var charImageAnchor: CharImageAnchor?
    public var borderWidth: CGFloat?
    public var borderColor: String?
    /// Font family name (e.g. "Inter"). Default: system font.
    public var fontFamily: String?
    public enum CharImageAnchor: String, Sendable, Equatable {
        case left
        case right
    }

    public init(
        cornerRadius: CGFloat? = nil,
        backgroundColor: String? = nil,
        textColor: String? = nil,
        titleTextColor: String? = nil,
        subTextColor: String? = nil,
        ctaTextColor: String? = nil,
        ctaColor: String? = nil,
        charImageCornerRadius: CGFloat? = nil,
        charImageAnchor: CharImageAnchor? = nil,
        borderWidth: CGFloat? = nil,
        borderColor: String? = nil,
        fontFamily: String? = nil
    ) {
        self.cornerRadius = cornerRadius
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.titleTextColor = titleTextColor
        self.subTextColor = subTextColor
        self.ctaTextColor = ctaTextColor
        self.ctaColor = ctaColor
        self.charImageCornerRadius = charImageCornerRadius
        self.charImageAnchor = charImageAnchor
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.fontFamily = fontFamily
    }

    // Resolved defaults matching Kotlin's fallback pattern
    public var resolvedCornerRadius: CGFloat { cornerRadius ?? 16 }
    public var resolvedBackgroundColor: String { backgroundColor ?? "rgba(0, 0, 0, 0.65)" }
    public var resolvedTextColor: String { textColor ?? "#FFFFFF" }
    public var resolvedTitleTextColor: String { titleTextColor ?? textColor ?? "#FFFFFF" }
    public var resolvedSubTextColor: String { subTextColor ?? textColor ?? "#FFFFFF" }
    public var resolvedCtaTextColor: String { ctaTextColor ?? textColor ?? "#FFFFFF" }
    public var resolvedCtaColor: String { ctaColor ?? "#3B82F6" }
    public var resolvedCharImageCornerRadius: CGFloat { charImageCornerRadius ?? 12 }
    public var resolvedCharImageAnchor: CharImageAnchor { charImageAnchor ?? .left }
    public var resolvedBorderWidth: CGFloat { borderWidth ?? 1 }
    public var resolvedBorderColor: String { borderColor ?? "rgba(255, 255, 255, 0.1)" }
}

// MARK: - MiniGameButtonTheme

/// Theme configuration for MiniGameButton (translates `MiniGameButtonTheme` from types.ts)
public struct MiniGameButtonTheme: Sendable, Equatable {
    public var cornerRadius: CGFloat?
    public var backgroundColor: String?
    public var textColor: String?
    public var fontSize: CGFloat?
    /// Font family name (e.g. "Inter"). Default: system font.
    public var fontFamily: String?
    public var paddingHorizontal: CGFloat?
    public var paddingVertical: CGFloat?
    public var borderWidth: CGFloat?
    public var borderColor: String?
    /// Pulsate glow color. Defaults to backgroundColor.
    public var pulsateColor: String?
    /// Badge dot color. Defaults to '#EF4444'.
    public var badgeColor: String?

    public init(
        cornerRadius: CGFloat? = nil,
        backgroundColor: String? = nil,
        textColor: String? = nil,
        fontSize: CGFloat? = nil,
        fontFamily: String? = nil,
        paddingHorizontal: CGFloat? = nil,
        paddingVertical: CGFloat? = nil,
        borderWidth: CGFloat? = nil,
        borderColor: String? = nil,
        pulsateColor: String? = nil,
        badgeColor: String? = nil
    ) {
        self.cornerRadius = cornerRadius
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.paddingHorizontal = paddingHorizontal
        self.paddingVertical = paddingVertical
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.pulsateColor = pulsateColor
        self.badgeColor = badgeColor
    }

    // Resolved defaults matching React's defaultTheme
    public var resolvedCornerRadius: CGFloat { cornerRadius ?? 8 }
    public var resolvedBackgroundColor: String { backgroundColor ?? "#3B82F6" }
    public var resolvedTextColor: String { textColor ?? "#FFFFFF" }
    public var resolvedFontSize: CGFloat { fontSize ?? 14 }
    public var resolvedPaddingHorizontal: CGFloat { paddingHorizontal ?? 20 }
    public var resolvedPaddingVertical: CGFloat { paddingVertical ?? 10 }
    public var resolvedBorderWidth: CGFloat { borderWidth ?? 0 }
    public var resolvedBorderColor: String { borderColor ?? "transparent" }
    public var resolvedPulsateColor: String { pulsateColor ?? resolvedBackgroundColor }
    public var resolvedBadgeColor: String { badgeColor ?? "#EF4444" }
}

// MARK: - MiniGameInterstitialTheme

/// Theme configuration for MiniGameInterstitial (translates `MiniGameInterstitialTheme` from types.ts)
public struct MiniGameInterstitialTheme: Sendable, Equatable {
    /// Corner radius for the CTA button. Matches Kotlin's `ctaCornerRadius`.
    public var ctaCornerRadius: CGFloat?
    public var characterSize: CGFloat?
    /// Title text color. Matches Kotlin's `titleTextColor`.
    public var titleTextColor: String?
    /// Title font size. Matches Kotlin's `titleFontSize`.
    public var titleFontSize: CGFloat?
    /// CTA button text color. Matches Kotlin's `ctaTextColor`.
    public var ctaTextColor: String?
    /// CTA button font size. Matches Kotlin's `ctaFontSize`.
    public var ctaFontSize: CGFloat?
    public var ctaColor: String?
    /// Font family name (e.g. "Inter"). Default: system font.
    public var fontFamily: String?

    public init(
        ctaCornerRadius: CGFloat? = nil,
        characterSize: CGFloat? = nil,
        titleTextColor: String? = nil,
        titleFontSize: CGFloat? = nil,
        ctaTextColor: String? = nil,
        ctaFontSize: CGFloat? = nil,
        ctaColor: String? = nil,
        fontFamily: String? = nil
    ) {
        self.ctaCornerRadius = ctaCornerRadius
        self.characterSize = characterSize
        self.titleTextColor = titleTextColor
        self.titleFontSize = titleFontSize
        self.ctaTextColor = ctaTextColor
        self.ctaFontSize = ctaFontSize
        self.ctaColor = ctaColor
        self.fontFamily = fontFamily
    }

    // Resolved defaults matching Kotlin's MiniGameInterstitialDefaults
    public var resolvedCtaCornerRadius: CGFloat { ctaCornerRadius ?? 16 }
    public var resolvedCharacterSize: CGFloat { characterSize ?? 120 }
    public var resolvedTitleTextColor: String { titleTextColor ?? "#FFFFFF" }
    public var resolvedTitleFontSize: CGFloat { titleFontSize ?? 24 }
    public var resolvedCtaTextColor: String { ctaTextColor ?? "#FFFFFF" }
    public var resolvedCtaFontSize: CGFloat { ctaFontSize ?? 16 }
    public var resolvedCtaColor: String { ctaColor ?? "#3B82F6" }
}

// MARK: - MaxGamesToShow

/// The allowed values for maxGamesToShow (translates the 3 | 6 | 9 union from types.ts)
public enum MaxGamesToShow: Int, Sendable, Equatable {
    case three = 3
    case six = 6
    case nine = 9
}

// MARK: - Ad Behavior (server-driven A/B config)

/// Lowercases and normalizes hyphens to underscores so the tolerant enum factories
/// accept either wire spelling (`circular-progress` ≡ `circular_progress`).
private func normalizeBehaviorToken(_ raw: String?) -> String {
    (raw ?? "").lowercased().replacingOccurrences(of: "-", with: "_")
}

/// Hard cap on the server-driven close delay. The close button (and, on Android, the system
/// Back button) is blocked until the delay elapses, so an out-of-range value would otherwise
/// trap the user with no exit. The `close_chrome` experiment arms are 20/30/45s (default 30),
/// so the cap is 45 to honor the largest authored value while still bounding a malformed one.
let maxCloseDelaySeconds = 45

/// Independent cap for delayed SKOverlay presentation. It intentionally does not reuse the close
/// gate's safety constant: changing close-button experiment arms must not change install timing.
let maxSKOverlayDelaySeconds = 300

/// Validates a server-supplied progress-bar color. Accepts an optional leading `#` followed by
/// exactly 6 hex digits; anything else (missing, wrong length, non-hex) falls back to white per
/// spec. Returned WITH a leading `#` so it drops straight into `Color(hex:)`.
func validatedHexColor(_ raw: String?, fallback: String = "#FFFFFF") -> String {
    guard let raw else { return fallback }
    let body = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    guard body.count == 6, body.allSatisfy({ $0.isHexDigit }) else { return fallback }
    return "#" + body.uppercased()
}

/// The close-button visual treatment while the pre-tap delay runs and after it resolves
/// (v2 replaces the prior `countdown_ui`). Unknown/missing → `.hidden` (safest: shows no
/// affordance, so a malformed value can never present a false tap target).
public enum CloseTreatment: Sendable, Equatable {
    /// No close affordance during the delay; the X materializes once the delay elapses.
    case hidden
    /// An animated circular progress ring counts down around the close target.
    case countdownCircle
    /// A horizontal progress bar (Unity-style) fills over the delay, pinned to its edge.
    case progressBar
    /// A text label — "Reward in X" (rewarded) / "Close in X" (interstitial) — resolving to a
    /// tap target when complete. Copy is inferred from `creative.ad_unit_type`.
    case rewardOrCloseLabel

    static func from(_ raw: String?) -> CloseTreatment {
        switch normalizeBehaviorToken(raw) {
        case "countdown_circle": return .countdownCircle
        case "progress_bar": return .progressBar
        case "reward_or_close_label": return .rewardOrCloseLabel
        default: return .hidden
        }
    }
}

/// Where the close button sits. v2 narrows this to three corners — `bottom_right` is excluded
/// (it collides with SKOverlay and common OS nav gestures). Unknown/missing/excluded → `.topRight`.
/// Reused verbatim for the server-resolved store-prompt position.
public enum ClosePosition: Sendable, Equatable {
    case topRight, topLeft, bottomLeft

    static func from(_ raw: String?) -> ClosePosition {
        switch normalizeBehaviorToken(raw) {
        case "top_left": return .topLeft
        case "bottom_left": return .bottomLeft
        // top_right, plus excluded bottom_right / legacy bottom_corner, plus unknown → safe default.
        default: return .topRight
        }
    }
}

/// How a CTA tap opens the advertiser's store. Unknown/missing → `.skstoreproduct` (the in-app
/// store sheet) — the v2 payload omits `store_open` entirely, and the documented intent is that
/// the SKStoreProductVC path stays on; leaving the app is opt-in via an explicit `external`
/// (legacy `external_browser` aliased). `inline_install` (Android-only) is accepted and routed to
/// each platform's native store at the router. Legacy `sk_store_product`/`sk_overlay` aliased.
public enum StoreOpen: Sendable, Equatable {
    case external, skstoreproduct, inlineInstall

    static func from(_ raw: String?) -> StoreOpen {
        switch normalizeBehaviorToken(raw) {
        case "external", "external_browser": return .external
        case "inline_install": return .inlineInstall
        // skstoreproduct / sk_store_product / sk_overlay, plus missing/unknown → in-app sheet.
        default: return .skstoreproduct
        }
    }
}

/// The ad format, used to pick `reward_or_close_label` copy. Unknown/missing → `.interstitial`.
public enum AdUnitType: Sendable, Equatable {
    case rewarded, interstitial

    static func from(_ raw: String?) -> AdUnitType {
        switch normalizeBehaviorToken(raw) {
        case "rewarded": return .rewarded
        default: return .interstitial
        }
    }
}

/// The creative descriptor (`creative` node). `adUnitType` drives format-aware close copy; the
/// playable `bundleUrl`/`type` carry render metadata. Decoding is tolerant.
public struct Creative: Sendable, Equatable, Decodable {
    public let type: String
    public let bundleUrl: String?
    public let adUnitType: AdUnitType

    public init(type: String = "", bundleUrl: String? = nil, adUnitType: AdUnitType = .interstitial) {
        self.type = type
        self.bundleUrl = bundleUrl
        self.adUnitType = adUnitType
    }

    enum CodingKeys: String, CodingKey {
        case type
        case bundleUrl = "bundle_url"
        case adUnitType = "ad_unit_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = (try? c.decode(String.self, forKey: .type)) ?? ""
        self.bundleUrl = try? c.decode(String.self, forKey: .bundleUrl)
        self.adUnitType = .from(try? c.decode(String.self, forKey: .adUnitType))
    }
}

/// Experiment-assignment metadata (`experiment` node), carried for telemetry only (it does not
/// drive rendering — the resolved `ad_behavior` does). All fields optional.
public struct Experiment: Sendable, Equatable, Decodable {
    public let experimentId: String?
    public let variantId: String?
    public let layer: String?

    public init(experimentId: String? = nil, variantId: String? = nil, layer: String? = nil) {
        self.experimentId = experimentId
        self.variantId = variantId
        self.layer = layer
    }

    enum CodingKeys: String, CodingKey {
        case experimentId = "experiment_id"
        case variantId = "variant_id"
        case layer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.experimentId = try? c.decode(String.self, forKey: .experimentId)
        self.variantId = try? c.decode(String.self, forKey: .variantId)
        self.layer = try? c.decode(String.self, forKey: .layer)
    }
}

/// Close-button behavior for one impression (`close` node). Decoding is tolerant: every field
/// falls back to its default and unknown enum strings never fail the parse.
public struct CloseBehavior: Sendable, Equatable, Decodable {
    public let delaySeconds: Int
    public let treatment: CloseTreatment
    public let position: ClosePosition
    /// Validated 6-digit hex (with leading `#`); tints the fill of `countdownCircle` and
    /// `progressBar`. White when omitted/invalid. No-op for `hidden` / `rewardOrCloseLabel`.
    public let progressBarColor: String

    public init(
        delaySeconds: Int = 0,
        treatment: CloseTreatment = .hidden,
        position: ClosePosition = .topRight,
        progressBarColor: String = "#FFFFFF"
    ) {
        self.delaySeconds = min(maxCloseDelaySeconds, max(0, delaySeconds))
        self.treatment = treatment
        // Every treatment honors the configured corner. (`progress_bar` renders its bar at the top
        // edge regardless; only its resolved close ✕ follows `position`.)
        self.position = position
        self.progressBarColor = progressBarColor
    }

    enum CodingKeys: String, CodingKey {
        case delaySeconds = "delay_seconds"
        case treatment, position
        case progressBarColor = "progress_bar_color"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Clamp to [0, maxCloseDelaySeconds] so a bad/oversized value can't trap the user.
        let delay = min(maxCloseDelaySeconds, max(0, (try? c.decode(Int.self, forKey: .delaySeconds)) ?? 0))
        let treatment = CloseTreatment.from(try? c.decode(String.self, forKey: .treatment))
        let position = ClosePosition.from(try? c.decode(String.self, forKey: .position))
        let color = validatedHexColor(try? c.decode(String.self, forKey: .progressBarColor))
        // Route through the memberwise init so the position-vs-treatment snap applies on decode too.
        self.init(delaySeconds: delay, treatment: treatment, position: position, progressBarColor: color)
    }
}

/// Which store the mid-ad prompt badge advertises. Unknown/missing → `.ios`.
public enum StorePromptPlatform: Sendable, Equatable {
    case ios, android

    static func from(_ raw: String?) -> StorePromptPlatform {
        switch normalizeBehaviorToken(raw) {
        case "android": return .android
        default: return .ios
        }
    }
}

/// Mid-ad store prompt (`store_prompt` node): a tappable store badge shown at the 50% playable
/// mark, independent of the close button and SKOverlay. `position` is still decoded from the wire
/// but no longer drives layout: the SDK renders the badge in the horizontal mirror of the close
/// button's corner (the opposite side), so the two affordances never share an edge.
public struct StorePrompt: Sendable, Equatable, Decodable {
    public let enabled: Bool
    public let trigger: String
    public let position: ClosePosition
    public let platform: StorePromptPlatform

    public init(
        enabled: Bool = false,
        trigger: String = "midpoint",
        position: ClosePosition = .topLeft,
        platform: StorePromptPlatform = .ios
    ) {
        self.enabled = enabled
        self.trigger = trigger
        self.position = position
        self.platform = platform
    }

    enum CodingKeys: String, CodingKey {
        case enabled, trigger, position, platform
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        self.trigger = (try? c.decode(String.self, forKey: .trigger)) ?? "midpoint"
        self.position = .from(try? c.decode(String.self, forKey: .position))
        self.platform = .from(try? c.decode(String.self, forKey: .platform))
    }
}

/// When the install overlay is presented. Unknown/missing → `.onClick`.
public enum OverlayTiming: Sendable, Equatable {
    case duringPlay, onClick, delayed

    static func from(_ raw: String?) -> OverlayTiming {
        switch normalizeBehaviorToken(raw) {
        case "during_play": return .duringPlay
        case "delayed": return .delayed
        default: return .onClick
        }
    }
}

/// Where the install overlay is pinned. Unknown/missing → `.bottom`.
public enum OverlayPosition: Sendable, Equatable {
    case bottom, bottomRaised

    static func from(_ raw: String?) -> OverlayPosition {
        switch normalizeBehaviorToken(raw) {
        case "bottom_raised": return .bottomRaised
        default: return .bottom
        }
    }
}

/// SKOverlay (iOS) / Play Install Prompt (Android) config (`skoverlay` node): a native,
/// SDK-presented install banner, independent of the creative click handler. Gated by the OS
/// capability handshake — the backend won't assign it below iOS 14 / Android API 21.
public struct SKOverlayConfig: Sendable, Equatable, Decodable {
    public let enabled: Bool
    public let timing: OverlayTiming
    public let delaySeconds: Int
    public let position: OverlayPosition
    public let dismissible: Bool

    public init(
        enabled: Bool = false,
        timing: OverlayTiming = .onClick,
        delaySeconds: Int = 0,
        position: OverlayPosition = .bottom,
        dismissible: Bool = true
    ) {
        self.enabled = enabled
        self.timing = timing
        self.delaySeconds = min(maxSKOverlayDelaySeconds, max(0, delaySeconds))
        self.position = position
        self.dismissible = dismissible
    }

    enum CodingKeys: String, CodingKey {
        case enabled, timing
        case delaySeconds = "delay_seconds"
        case position, dismissible
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        self.timing = .from(try? c.decode(String.self, forKey: .timing))
        self.delaySeconds = min(
            maxSKOverlayDelaySeconds,
            max(0, (try? c.decode(Int.self, forKey: .delaySeconds)) ?? 0)
        )
        self.position = .from(try? c.decode(String.self, forKey: .position))
        self.dismissible = (try? c.decode(Bool.self, forKey: .dismissible)) ?? true
    }
}

/// Ad-network attribution tokens for the StoreKit-rendered store surfaces (`skan_attribution` node,
/// a sibling of `ad_behavior` at the response root — it describes who to credit, not how the ad is
/// displayed). iOS-only: `SKOverlay` / `SKStoreProductViewController` can't navigate an MMP tracking
/// URL, so attribution rides on these tokens instead — the App Analytics campaign/provider tokens
/// and, when the ad network supplies a signed SKAdNetwork payload, the full `skan` set. Every field is optional;
/// an absent or partial object means "no token wired" and the store surface falls back to today's
/// behavior. The SDK passes these through verbatim — it never mints or signs them (the backend does).
public struct AdAttribution: Sendable, Equatable, Decodable {
    /// App Analytics campaign token (`SKStoreProductParameterCampaignToken` / `SKOverlay…campaignToken`).
    public let campaignToken: String?
    /// App Analytics provider token (`SKStoreProductParameterProviderToken` / `SKOverlay…providerToken`).
    public let providerToken: String?
    /// Signed SKAdNetwork payload. Present only when the ad network can vouch for the install postback.
    public let skan: SKANParameters?

    public init(campaignToken: String? = nil, providerToken: String? = nil, skan: SKANParameters? = nil) {
        self.campaignToken = campaignToken
        self.providerToken = providerToken
        self.skan = skan
    }

    /// True when at least one usable token is present (a non-empty campaign/provider token, or a signed
    /// `skan` payload). An all-empty object — e.g. the backend sent `skan_attribution: {}` — is treated
    /// as "no attribution wired", so callers fall back to their default un-attributed behavior.
    public var hasUsableTokens: Bool {
        (campaignToken?.isEmpty == false) || (providerToken?.isEmpty == false) || skan != nil
    }

    enum CodingKeys: String, CodingKey {
        case campaignToken = "campaign_token"
        case providerToken = "provider_token"
        case skan
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.campaignToken = try? c.decode(String.self, forKey: .campaignToken)
        self.providerToken = try? c.decode(String.self, forKey: .providerToken)
        self.skan = try? c.decode(SKANParameters.self, forKey: .skan)
    }
}

/// The signed SKAdNetwork parameters the ad network computes server-side, mapped 1:1 to StoreKit's
/// `SKStoreProductParameterAdNetwork*` keys (applied in `CreativeCTARouter`). All-or-nothing: StoreKit
/// needs the complete signed set to generate a valid install postback, so the required fields are
/// non-optional — a payload missing any of them fails to decode and the whole `skan` block is dropped
/// (the store still opens, just without SKAN). `campaignIdentifier` (SKAN ≤3) and `sourceIdentifier`
/// (SKAN 4) are the version-specific alternatives; supply whichever matches `version`.
///
/// NOTE: the snake_case `CodingKeys` below are pinned by `docs/AD_ATTRIBUTION_BACKEND_PRD.md` —
/// confirm them against the backend (`~/project-any-sdk-api`) `skan_attribution.skan` contract before shipping.
public struct SKANParameters: Sendable, Equatable, Decodable {
    public let version: String
    public let adNetworkIdentifier: String
    public let sourceAppStoreIdentifier: Int
    public let nonce: String
    public let timestamp: Int
    public let attributionSignature: String
    public let campaignIdentifier: Int?
    public let sourceIdentifier: Int?
    /// View-through signature (fidelity-type 0) for the documented
    /// `SKAdImpression` API (SKOverlay's `adImpression`). Optional: servers
    /// pre-dating the field omit it, and the overlay falls back to the
    /// `setAdditionalValue` conveyance in that case.
    public let viewAttributionSignature: String?

    enum CodingKeys: String, CodingKey {
        case version
        case adNetworkIdentifier = "ad_network_id"
        case sourceAppStoreIdentifier = "source_app_store_id"
        case nonce
        case timestamp
        case attributionSignature = "attribution_signature"
        case campaignIdentifier = "campaign_id"
        case sourceIdentifier = "source_id"
        case viewAttributionSignature = "view_attribution_signature"
    }
}

/// The creative-lifecycle moment at which an enabled `auto_store_redirect` fires. The `rawValue` is
/// the wire token the server sends AND the token the creative emits via the `CREATIVE_MOMENT` bridge
/// event; the two are matched verbatim. Unknown/missing → `.playableEnd` (the server's own default).
public enum AutoStoreRedirectTrigger: String, Sendable, Equatable {
    case playableEnd = "playable_end"
    case endScreen1Open = "end_screen_1_open"
    case endScreen2Open = "end_screen_2_open"

    static func from(_ raw: String?) -> AutoStoreRedirectTrigger {
        switch normalizeBehaviorToken(raw) {
        case "end_screen_1_open": return .endScreen1Open
        case "end_screen_2_open": return .endScreen2Open
        default: return .playableEnd
        }
    }
}

extension AutoStoreRedirectTrigger {
    /// Maps the index of a post-close fallback ad (`GET /load/fallbacks`, presented one per close in
    /// reveal order) to the end-screen trigger it represents: index 0 is END SCREEN 1, index 1 is END
    /// SCREEN 2. Returns nil for any further index. The SDK fires the redirect when the matching
    /// fallback screen is presented — there is no signal from the webview. (PLAYABLE_END is SDK-native
    /// — fired when the close button appears — and has no fallback index.)
    static func endScreenTrigger(forFallbackIndex index: Int) -> AutoStoreRedirectTrigger? {
        switch index {
        case 0: return .endScreen1Open
        case 1: return .endScreen2Open
        default: return nil
        }
    }
}

/// Auto store redirect (`auto_store_redirect` node): when `enabled`, the SDK opens the advertiser
/// store once per impression at the `trigger` moment — no user tap. PLAYABLE_END fires when the close
/// button appears; END_SCREEN_1/2_OPEN fire when the matching post-close fallback ad screen is
/// presented (see `AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex:)`). The store opened is
/// always the primary ad's (fallback ads carry no store link). Disabled by default.
public struct AutoStoreRedirect: Sendable, Equatable, Decodable {
    public let enabled: Bool
    public let trigger: AutoStoreRedirectTrigger

    public init(enabled: Bool = false, trigger: AutoStoreRedirectTrigger = .playableEnd) {
        self.enabled = enabled
        self.trigger = trigger
    }

    enum CodingKeys: String, CodingKey {
        case enabled, trigger
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        self.trigger = .from(try? c.decode(String.self, forKey: .trigger))
    }
}

/// Server-driven render config returned per-impression in `ad_behavior`. Optional on the load
/// response: an absent object means "render today's defaults". A present-but-partial object
/// fills each missing field with its default; `store_prompt` / `skoverlay` / `auto_store_redirect`
/// are nil when omitted.
///
/// NOTE: attribution tokens are NOT part of `ad_behavior` (which is purely about how the ad is
/// displayed). They live in the sibling `skan_attribution` node at the response root — see
/// ``AdLoadResponse/skanAttribution`` / ``RewardedInitResponse/skanAttribution`` and `AdAttribution`.
public struct AdBehavior: Sendable, Equatable, Decodable {
    public let close: CloseBehavior
    public let storeOpen: StoreOpen
    public let storePrompt: StorePrompt?
    public let skoverlay: SKOverlayConfig?
    public let autoStoreRedirect: AutoStoreRedirect?

    public init(
        close: CloseBehavior = CloseBehavior(),
        storeOpen: StoreOpen = .skstoreproduct,
        storePrompt: StorePrompt? = nil,
        skoverlay: SKOverlayConfig? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil
    ) {
        self.close = close
        self.storeOpen = storeOpen
        self.storePrompt = storePrompt
        self.skoverlay = skoverlay
        self.autoStoreRedirect = autoStoreRedirect
    }

    enum CodingKeys: String, CodingKey {
        case close
        case storeOpen = "store_open"
        case storePrompt = "store_prompt"
        case skoverlay
        case autoStoreRedirect = "auto_store_redirect"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.close = (try? c.decode(CloseBehavior.self, forKey: .close)) ?? CloseBehavior()
        self.storeOpen = .from(try? c.decode(String.self, forKey: .storeOpen))
        self.storePrompt = try? c.decode(StorePrompt.self, forKey: .storePrompt)
        self.skoverlay = try? c.decode(SKOverlayConfig.self, forKey: .skoverlay)
        self.autoStoreRedirect = try? c.decode(AutoStoreRedirect.self, forKey: .autoStoreRedirect)
    }
}

/// User-selectable reasons for the in-ad report flow (the "i" → report sheet). `rawValue` is the wire
/// `flag` sent to `POST /impressions/{adId}/report`; `label` is the user-facing copy.
public enum AdReportReason: String, CaseIterable, Sendable {
    case adNotShowing = "ad_not_showing"
    case adInappropriate = "ad_inappropriate"
    case adLooksWrong = "ad_looks_wrong"
    case dislike
    case other

    /// The wire value posted as `flag`.
    public var flag: String { rawValue }

    /// User-facing menu copy.
    public var label: String {
        switch self {
        case .adNotShowing: return "Ad isn't showing properly"
        case .adInappropriate: return "Inappropriate or offensive"
        case .adLooksWrong: return "Ad looks wrong or misleading"
        case .dislike: return "I don't want to see this"
        case .other: return "Other"
        }
    }
}

// MARK: - Native Ad (POST /load/native)

/// A JSON value of any shape — string, number, bool, null, array, or nested object.
///
/// Backs ``SimulaAdContext/customContext`` so each entry can carry arbitrary JSON rather than only a
/// string. Swift's `Any` isn't `Encodable`/`Equatable`/`Sendable`, so this type-erased enum stands in
/// for it. Literal conformances keep call sites terse — values are inferred from the literal:
/// ```swift
/// customContext: [
///     "recent": "Frieren",                 // .string
///     "episodes": 28,                      // .int
///     "rating": 4.7,                       // .double
///     "watching": true,                    // .bool
///     "genres": ["fantasy", "adventure"],  // .array
///     "meta": ["subbed": true],            // .object
/// ]
/// ```
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

/// Provider-level targeting context for native ads. Set once on `SimulaProviderView` (or via
/// `SimulaAds.updateContext`) and attached automatically to every `POST /load/native` — a
/// `NativeAdSlot` never passes context itself (PRD).
///
/// Encodes directly as the backend `NativeContext` wire object: its property names are already the
/// camelCase keys the API expects, so the synthesized `Encodable` needs no `CodingKeys`. Updates
/// replace the context in full (not a merge); ads already preloaded under the old context are
/// unaffected. Mirrors the Kotlin SDK's `SimulaAdContext`.
public struct SimulaAdContext: Encodable, Equatable, Sendable {
    /// Current search / query term in the feed.
    public var searchTerm: String?
    /// Content tags (the backend keeps at most 10).
    public var tags: [String]?
    /// Feed category.
    public var category: String?
    /// Title of the surrounding feed item.
    public var title: String?
    /// Description of the surrounding feed item.
    public var description: String?
    /// Opaque user-profile signal.
    public var userProfile: String?
    /// User email, if available.
    public var userEmail: String?
    /// Arbitrary key-values of any JSON shape (the backend keeps at most 10 entries).
    public var customContext: [String: JSONValue]?
    /// Whether the surrounding content is NSFW. Defaults to false.
    public var nsfw: Bool

    public init(
        searchTerm: String? = nil,
        tags: [String]? = nil,
        category: String? = nil,
        title: String? = nil,
        description: String? = nil,
        userProfile: String? = nil,
        userEmail: String? = nil,
        customContext: [String: JSONValue]? = nil,
        nsfw: Bool = false
    ) {
        self.searchTerm = searchTerm
        self.tags = tags
        self.category = category
        self.title = title
        self.description = description
        self.userProfile = userProfile
        self.userEmail = userEmail
        self.customContext = customContext
        self.nsfw = nsfw
    }
}

/// Body for `POST /load/native` (backend `CaiNativeRequest`). `position` + `sessionId` are required;
/// everything else is optional. The native surface has no `char_image` (unlike the interstitial).
/// `width` is accepted but ignored by the API — the card always renders at 100%.
public struct NativeAdRequest: Encodable, Sendable {
    public let position: Int
    public let sessionId: String
    public let adUnitId: String?
    public let context: SimulaAdContext?
    public let theme: String?
    /// Sent as a string (the backend accepts number | string); reserved — sizing is client-side.
    public let width: String?
    public let charId: String?
    public let charName: String?
    public let charDesc: String?
    public let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case position
        case sessionId = "session_id"
        case adUnitId = "ad_unit_id"
        case context
        case theme
        case width
        case charId = "char_id"
        case charName = "char_name"
        case charDesc = "char_desc"
        case metadata
    }

    public init(
        position: Int,
        sessionId: String,
        adUnitId: String? = nil,
        context: SimulaAdContext? = nil,
        theme: String? = nil,
        width: String? = nil,
        charId: String? = nil,
        charName: String? = nil,
        charDesc: String? = nil
    ) {
        self.position = position
        self.sessionId = sessionId
        self.adUnitId = adUnitId
        self.context = context
        self.theme = theme
        self.width = width
        self.charId = charId
        self.charName = charName
        self.charDesc = charDesc
        self.metadata = nil
    }

    public init(
        position: Int,
        sessionId: String,
        adUnitId: String? = nil,
        context: SimulaAdContext? = nil,
        theme: String? = nil,
        width: String? = nil,
        charId: String? = nil,
        charName: String? = nil,
        charDesc: String? = nil,
        metadata: [String: String]?
    ) {
        self.position = position
        self.sessionId = sessionId
        self.adUnitId = adUnitId
        self.context = context
        self.theme = theme
        self.width = width
        self.charId = charId
        self.charName = charName
        self.charDesc = charDesc
        self.metadata = metadata.flatMap { normalizeExtraParameters($0) }
    }
}

/// Response for `POST /load/native` (backend `CaiNativeResponse`). Tolerant decode (missing keys →
/// safe defaults). A flat envelope mirroring the imperative ``AdLoadResponse``: the creative
/// (`iframe_url` + `rendered_html`) and the click-through params (`destination`, `tracking_url`) sit
/// at the top level — the creative was previously nested under a camelCase `adResponse`.
public struct NativeAdResponse: Decodable, Sendable {
    public let impressionId: String?
    public let adInserted: Bool
    public let adFormat: String
    /// Cleared bid (estimated CPM) for this serve, backend-provided. Drives ``adValue``. Defaults to
    /// 0 → a $0 estimate when the field is absent (e.g. a no-fill).
    public let bidAmt: Double
    /// Where a CTA tap routes — `"appstore"` or `"web"`. Defaults to `"appstore"` when absent.
    public let destination: String
    /// MMP click-tracking URL the CTA opens (attribution-preserving); nil when the serve carries no
    /// tracker (the SDK then falls back to the URL the creative itself navigates to).
    public let trackingUrl: String?
    /// Raw, unwrapped App Store link (`ios_store_url`) — parity with the interstitial/rewarded
    /// responses. Drives the deterministic CTA route for the native card (see `openNativeCTA`);
    /// nil when the campaign has no raw store link.
    public let iosStoreUrl: String?
    /// Raw mountable-creative fields; use ``iframeURL`` / ``renderedHTML`` for the trimmed accessors.
    public let iframeUrl: String?
    public let renderedHtml: String?
    /// SKAdNetwork / App Analytics attribution tokens (`skan_attribution` node, a response-root sibling
    /// of the creative fields — parity with the interstitial/rewarded responses). `nil` (or token-less)
    /// when omitted → the App Store CTA opens externally exactly as today (un-attributed). See `AdAttribution`.
    public let skanAttribution: AdAttribution?

    /// Estimated revenue derived on-device from ``bidAmt``; surfaced on the native paid
    /// event, co-fired with the impression.
    public var adValue: AdValue { AdValue.fromBidCpm(bidAmt) }

    /// `destination` mapped to a typed value; unknown strings fall back to `.appstore`.
    public var destinationKind: AdDestination {
        AdDestination(rawValue: destination) ?? .appstore
    }

    enum CodingKeys: String, CodingKey {
        case impressionId = "impression_id"
        case adInserted = "ad_inserted"
        case adFormat = "ad_format"
        case bidAmt = "bid_amt"
        case destination
        case trackingUrl = "tracking_url"
        case iosStoreUrl = "ios_store_url"
        case iframeUrl = "iframe_url"
        case renderedHtml = "rendered_html"
        case skanAttribution = "skan_attribution"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        impressionId = try c.decodeIfPresent(String.self, forKey: .impressionId)
        adInserted = (try c.decodeIfPresent(Bool.self, forKey: .adInserted)) ?? false
        adFormat = (try c.decodeIfPresent(String.self, forKey: .adFormat)) ?? ""
        bidAmt = (try c.decodeIfPresent(Double.self, forKey: .bidAmt)) ?? 0
        destination = (try c.decodeIfPresent(String.self, forKey: .destination)) ?? AdDestination.appstore.rawValue
        trackingUrl = try c.decodeIfPresent(String.self, forKey: .trackingUrl)
        iosStoreUrl = try c.decodeIfPresent(String.self, forKey: .iosStoreUrl)
        iframeUrl = try c.decodeIfPresent(String.self, forKey: .iframeUrl)
        renderedHtml = try c.decodeIfPresent(String.self, forKey: .renderedHtml)
        skanAttribution = try c.decodeIfPresent(AdAttribution.self, forKey: .skanAttribution)
    }

    /// Direct construction (used for the slot's debug/QA preview path).
    public init(
        impressionId: String?,
        adInserted: Bool,
        adFormat: String,
        iframeUrl: String? = nil,
        renderedHtml: String? = nil,
        destination: String = "appstore",
        trackingUrl: String? = nil,
        iosStoreUrl: String? = nil,
        bidAmt: Double = 0,
        skanAttribution: AdAttribution? = nil
    ) {
        self.impressionId = impressionId
        self.adInserted = adInserted
        self.adFormat = adFormat
        self.bidAmt = bidAmt
        self.destination = destination
        self.trackingUrl = trackingUrl
        self.iosStoreUrl = iosStoreUrl
        self.iframeUrl = iframeUrl
        self.renderedHtml = renderedHtml
        self.skanAttribution = skanAttribution
    }

    /// The creative URL to mount; the fallback when no inline html is present. nil on a no-fill.
    public var iframeURL: String? {
        iframeUrl?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// The `<iframe srcdoc=…>` wrapper to mount inline — preferred over `iframeURL` when present; nil otherwise.
    public var renderedHTML: String? {
        renderedHtml?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// True when there's a mountable creative to render.
    public var hasCreative: Bool { adInserted && (iframeURL != nil || renderedHTML != nil) }
}

/// Estimated per-impression revenue for a served ad, in a standard `AdValue` shape so it's a drop-in for
/// a publisher's existing analytics / MMP pipeline. Surfaced on the **paid** event
/// (`interstitialDidPay` / `rewardedDidPay` / `NativeAdSlot`'s `onPaid`) at the moment the impression
/// fires — never at load.
///
/// The SDK does not compute revenue from scratch: the backend ships the bid (CPM) with the ad and the
/// SDK derives the whole block once, on-device, with no network round-trip (see ``fromBidCpm(_:currencyCode:)``).
/// All figures are estimates known at serve time (from the floor CPM). Mirrors the Kotlin SDK's `AdValue`.
public struct AdValue: Sendable, Equatable {
    /// Estimate quality. Always `.estimated` for now (backend-provided).
    public enum PrecisionType: String, Sendable, Equatable { case estimated = "ESTIMATED" }

    /// Canonical estimate: per-impression revenue in micros of ``currencyCode``. `5000` = $0.005.
    public let valueMicros: Int64
    /// ISO-4217 currency code, e.g. `"USD"`.
    public let currencyCode: String
    public let precisionType: PrecisionType
    /// Estimated CPM = ``valueMicros`` / 1_000. Convenience; derived from ``valueMicros``.
    public let expectedCpm: Double
    /// Estimated per-impression revenue = ``valueMicros`` / 1_000_000. Convenience; derived from ``valueMicros``.
    public let expectedRevenue: Double

    public init(
        valueMicros: Int64,
        currencyCode: String,
        precisionType: PrecisionType,
        expectedCpm: Double,
        expectedRevenue: Double
    ) {
        self.valueMicros = valueMicros
        self.currencyCode = currencyCode
        self.precisionType = precisionType
        self.expectedCpm = expectedCpm
        self.expectedRevenue = expectedRevenue
    }

    /// Builds an `AdValue` from the backend-provided `bid_amt` — the estimated CPM in `currencyCode`.
    /// The three figures are all derived from a single ``valueMicros`` so they can never disagree on
    /// rounding (`valueMicros = round(bidCpm × 1000)`; e.g. a $5.00 CPM → 5000 → $0.005 per impression).
    /// Tolerant: a non-finite or negative bid clamps to 0, so a missing/garbage field yields a $0
    /// estimate rather than trapping — surfacing the paid event must never crash the host app.
    static func fromBidCpm(_ bidCpm: Double, currencyCode: String = "USD") -> AdValue {
        let roundedMicros = (bidCpm * 1_000).rounded()
        let valueMicros = (bidCpm.isFinite && bidCpm >= 0)
            ? (Int64(exactly: roundedMicros) ?? 0)
            : 0
        return AdValue(
            valueMicros: valueMicros,
            currencyCode: currencyCode,
            precisionType: .estimated,
            expectedCpm: Double(valueMicros) / 1_000,
            expectedRevenue: Double(valueMicros) / 1_000_000
        )
    }
}

/// Payload handed to `NativeAdSlot`'s `onImpression` when the OMID-shaped viewability threshold is
/// met (≥50% visible for ≥1 continuous second). Mirrors the PRD's `AdData`.
public struct NativeAdData: Sendable {
    /// Serve UUID from the backend (`impression_id`).
    public let impressionId: String
    /// Always `"character_ad"` on a fill.
    public let adFormat: String
    /// Echo of the slot's `adUnitId` (nil when none was set).
    public let adUnitId: String?
}

private extension String {
    /// nil when blank, else self — for trimming optional creative strings.
    var nonEmpty: String? { isEmpty ? nil : self }
}
