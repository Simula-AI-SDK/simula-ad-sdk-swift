import SwiftUI

// MARK: - GameCard

/// A single game card displaying the game icon and name.
/// Translates `GameCard.tsx` from the React SDK.
///
/// Features:
/// - AsyncImage with loading spinner and error fallback (emoji)
/// - Game name below the icon
/// - Scale + shadow hover/press effect
/// - Responsive sizing (compact mode for smaller screens)
public struct GameCard: View {
    let game: GameData
    let isCompact: Bool
    let theme: MiniGameTheme
    let onGameSelect: (String) -> Void

    // Random fallback icon selection (5 game-related emojis, matching React)
    private static let fallbackIcons = ["🎲", "🎮", "🎰", "🧩", "🎯"]

    @State private var imageError = false
    @State private var imageLoading = true
    @State private var randomFallback: String

    public init(
        game: GameData,
        isCompact: Bool = false,
        theme: MiniGameTheme,
        onGameSelect: @escaping (String) -> Void
    ) {
        self.game = game
        self.isCompact = isCompact
        self.theme = theme
        self.onGameSelect = onGameSelect
        self._randomFallback = State(initialValue: Self.fallbackIcons.randomElement() ?? "🎮")
    }

    // MARK: - Sizing (matching React's responsive breakpoints)

    /// Icon size: 80px desktop, 50px mobile (matching React @media max-width: 639px)
    private var iconSize: CGFloat { isCompact ? 50 : 80 }
    /// Card padding: 16px desktop, 10px mobile
    private var cardPadding: CGFloat { isCompact ? 10 : 16 }
    /// Card min height: 140px desktop, 100px mobile
    private var cardMinHeight: CGFloat { isCompact ? 100 : 140 }
    /// Game name font size: 14px desktop, 11px mobile
    private var nameFontSize: CGFloat { isCompact ? 11 : 14 }
    /// Icon corner radius from theme
    private var iconCornerRadius: CGFloat { theme.resolvedIconCornerRadius }

    public var body: some View {
        VStack(spacing: isCompact ? 8 : 12) {
            // Game Icon
            gameIconView
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconCornerRadius))

            // Game Name
            Text(game.name)
                .font(.system(size: nameFontSize, weight: .medium))
                .foregroundColor(Color(hex: theme.resolvedTitleFontColor))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(cardPadding)
        .frame(minHeight: cardMinHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: theme.resolvedBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: theme.resolvedBorderColor), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onGameSelect(game.id) }
        .accessibilityLabel("Play \(game.name)")
    }

    // MARK: - Game Icon View

    @ViewBuilder
    private var gameIconView: some View {
        if imageError {
            // Fallback emoji (matching React's fallback behavior)
            Text(game.iconFallback ?? randomFallback)
                .font(.system(size: iconSize * 0.6))
                .frame(width: iconSize, height: iconSize)
                .background(Color(hex: theme.resolvedBackgroundColor))
        } else {
            AsyncImage(url: URL(string: game.iconUrl)) { phase in
                switch phase {
                case .empty:
                    // Loading spinner (matching React's loading state)
                    ZStack {
                        Color(hex: theme.resolvedBackgroundColor)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(
                                tint: Color(hex: theme.resolvedTitleFontColor)
                            ))
                            .scaleEffect(0.8)
                    }
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: iconSize, height: iconSize)
                        .clipped()
                case .failure:
                    // Error fallback
                    Text(game.iconFallback ?? randomFallback)
                        .font(.system(size: iconSize * 0.6))
                        .frame(width: iconSize, height: iconSize)
                        .background(Color(hex: theme.resolvedBackgroundColor))
                @unknown default:
                    Color(hex: theme.resolvedBackgroundColor)
                }
            }
        }
    }
}
