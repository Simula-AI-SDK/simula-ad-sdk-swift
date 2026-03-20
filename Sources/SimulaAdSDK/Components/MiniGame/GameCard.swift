import SwiftUI

// MARK: - GameCard (CoverCard style)

/// Cover-style game card — 9:16 aspect ratio with full-bleed image,
/// dark gradient overlay, and game name at the bottom.
/// Translates `CoverCard.kt` from the Kotlin SDK.
public struct GameCard: View {
    let game: GameData
    let theme: MiniGameTheme
    let onGameSelect: (String) -> Void

    private static let fallbackIcons = ["🎲", "🎮", "🎰", "🧩", "🎯"]

    @State private var randomFallback: String
    @State private var isPressed = false

    public init(
        game: GameData,
        theme: MiniGameTheme,
        onGameSelect: @escaping (String) -> Void
    ) {
        self.game = game
        self.theme = theme
        self.onGameSelect = onGameSelect
        self._randomFallback = State(initialValue: Self.fallbackIcons.randomElement() ?? "🎮")
    }

    // Press scale animation (matching Kotlin: tween 200ms, target 0.95)
    private var pressScale: CGFloat {
        isPressed ? 1.05 : 1.0
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background
            Color.white.opacity(0.06)

            // Cover image (GIF-capable, cached)
            CachedCoverImage(
                gifCover: game.gifCover,
                iconUrl: game.iconUrl,
                fallbackEmoji: game.iconFallback ?? randomFallback
            )

            // Dark gradient overlay (matching Kotlin's verticalGradient colorStops exactly)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.52),
                    .init(color: Color.black.opacity(0.45), location: 0.75),
                    .init(color: Color.black.opacity(0.95), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Game title
            Text(game.name)
                .font(.system(size: 17, weight: .heavy))
                .foregroundColor(.white)
                .lineLimit(2)
                .truncationMode(.tail)
                .lineSpacing(1.5)
                .shadow(color: Color(red: 0, green: 0, blue: 0).opacity(0.65), radius: 12, x: 0, y: 10)
                .padding(10)
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .scaleEffect(pressScale)
        .animation(.easeInOut(duration: 0.2), value: isPressed)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.35), radius: 7, x: 0, y: 7)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color(red: 120/255, green: 200/255, blue: 255/255).opacity(0.1), lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onGameSelect(game.id) }
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .accessibilityLabel("Play \(game.name)")
    }
}
