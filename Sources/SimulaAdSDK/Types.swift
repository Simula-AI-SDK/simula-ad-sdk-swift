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

    public init(id: String, name: String, iconUrl: String, description: String, iconFallback: String? = nil) {
        self.id = id
        self.name = name
        self.iconUrl = iconUrl
        self.description = description
        self.iconFallback = iconFallback
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
    public var resolvedTitleFontColor: String { titleFontColor ?? "#1F2937" }
    public var resolvedSecondaryFontColor: String { secondaryFontColor ?? "#6B7280" }
    public var resolvedIconCornerRadius: CGFloat { iconCornerRadius ?? 8 }
    public var resolvedBorderColor: String { borderColor ?? "rgba(0, 0, 0, 0.08)" }
    public var resolvedAccentColor: String { accentColor ?? "#3B82F6" }
    public var resolvedBackgroundColor: String { backgroundColor ?? "#FFFFFF" }
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
    public var fontSize: CGFloat?

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
        fontFamily: String? = nil,
        fontSize: CGFloat? = nil
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
        self.fontSize = fontSize
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
    public var resolvedFontSize: CGFloat { fontSize ?? 16 }
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
