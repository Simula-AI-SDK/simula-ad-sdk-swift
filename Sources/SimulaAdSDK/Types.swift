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
/// trap the user with no exit. PRD arms are 0/3/5s; 15s leaves headroom without the footgun.
let maxCloseDelaySeconds = 15

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

    /// `countdown_circle` / `progress_bar` are edge-anchored (top only) and cannot render at
    /// `bottom_left`; `hidden` / `reward_or_close_label` allow all three corners.
    var allowsBottomLeft: Bool {
        switch self {
        case .hidden, .rewardOrCloseLabel: return true
        case .countdownCircle, .progressBar: return false
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

/// How a CTA tap opens the advertiser's store. Unknown/missing → `.external`. `inline_install`
/// (Android-only) is accepted and routed to each platform's native store at the router. Legacy
/// `external_browser`/`sk_store_product`/`sk_overlay` aliased. Retained from v1; the v2 payload
/// omits `store_open`, so it simply defaults (CTA store path unchanged — SKStoreProductVC stays on).
public enum StoreOpen: Sendable, Equatable {
    case external, skstoreproduct, inlineInstall

    static func from(_ raw: String?) -> StoreOpen {
        switch normalizeBehaviorToken(raw) {
        case "skstoreproduct", "sk_store_product", "sk_overlay": return .skstoreproduct
        case "inline_install": return .inlineInstall
        default: return .external
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
        self.delaySeconds = delaySeconds
        self.treatment = treatment
        // Snap an out-of-spec position (bottom_left under an edge-anchored treatment) to a safe
        // default so the SDK renders the field exactly as constrained, per "snap to safe default".
        self.position = (position == .bottomLeft && !treatment.allowsBottomLeft) ? .topRight : position
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
/// mark, independent of the close button and SKOverlay. `position` is resolved server-side
/// (opposite the close button) — the SDK renders it verbatim and never recomputes collisions.
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
        self.delaySeconds = max(0, delaySeconds)
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
        self.delaySeconds = max(0, (try? c.decode(Int.self, forKey: .delaySeconds)) ?? 0)
        self.position = .from(try? c.decode(String.self, forKey: .position))
        self.dismissible = (try? c.decode(Bool.self, forKey: .dismissible)) ?? true
    }
}

/// Server-driven render config returned per-impression in `ad_behavior`. Optional on the load
/// response: an absent object means "render today's defaults". A present-but-partial object
/// fills each missing field with its default; `store_prompt` / `skoverlay` are nil when omitted.
public struct AdBehavior: Sendable, Equatable, Decodable {
    public let close: CloseBehavior
    public let storeOpen: StoreOpen
    public let storePrompt: StorePrompt?
    public let skoverlay: SKOverlayConfig?

    public init(
        close: CloseBehavior = CloseBehavior(),
        storeOpen: StoreOpen = .external,
        storePrompt: StorePrompt? = nil,
        skoverlay: SKOverlayConfig? = nil
    ) {
        self.close = close
        self.storeOpen = storeOpen
        self.storePrompt = storePrompt
        self.skoverlay = skoverlay
    }

    enum CodingKeys: String, CodingKey {
        case close
        case storeOpen = "store_open"
        case storePrompt = "store_prompt"
        case skoverlay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.close = (try? c.decode(CloseBehavior.self, forKey: .close)) ?? CloseBehavior()
        self.storeOpen = .from(try? c.decode(String.self, forKey: .storeOpen))
        self.storePrompt = try? c.decode(StorePrompt.self, forKey: .storePrompt)
        self.skoverlay = try? c.decode(SKOverlayConfig.self, forKey: .skoverlay)
    }
}
