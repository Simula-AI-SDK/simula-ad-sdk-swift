import SwiftUI

// MARK: - MiniGameButton

/// A customizable CTA button for launching the mini game menu.
/// Translates `MiniGameButton.tsx` from the React SDK.
///
/// Features:
/// - Customizable text, colors, and padding via MiniGameButtonTheme
/// - Pulsating glow animation (matching React's @keyframes miniGameButtonPulsate)
/// - Badge dot with ping animation (matching React's @keyframes miniGameBadgePing)
/// - Optional fixed width
/// - Press scale effect
///
/// Usage:
/// ```swift
/// MiniGameButton(
///     text: "🎮 Play a Game",
///     showPulsate: true,
///     showBadge: true,
///     onClick: { showGameMenu = true }
/// )
/// ```
public struct MiniGameButton: View {
    // MARK: - Props (matching React's MiniGameButtonProps)

    /// Button text. Defaults to "🎮 Play a Game" (matching React's default)
    var text: String?
    /// Whether to show pulsating glow animation
    var showPulsate: Bool = false
    /// Whether to show the red badge dot
    var showBadge: Bool = false
    /// Theme customization
    var theme: MiniGameButtonTheme = MiniGameButtonTheme()
    /// Optional fixed width. See WidthParser for supported formats.
    var width: CGFloat?
    /// Click handler
    let onClick: () -> Void

    public init(
        text: String? = nil,
        showPulsate: Bool = false,
        showBadge: Bool = false,
        theme: MiniGameButtonTheme = MiniGameButtonTheme(),
        width: CGFloat? = nil,
        onClick: @escaping () -> Void
    ) {
        self.text = text
        self.showPulsate = showPulsate
        self.showBadge = showBadge
        self.theme = theme
        self.width = width
        self.onClick = onClick
    }

    // MARK: - State

    @State private var badgePingScale: CGFloat = 1
    @State private var badgePingOpacity: Double = 1

    // MARK: - Computed

    private var displayText: String {
        text ?? "\u{1F3AE} Play a Game"
    }

    // MARK: - Body

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // Main button
            Button(action: onClick) {
                Text(displayText)
                    .font(fontForFamily(theme.fontFamily, size: theme.resolvedFontSize, weight: .semibold))
                    .foregroundColor(Color(hex: theme.resolvedTextColor))
                    .padding(.horizontal, theme.resolvedPaddingHorizontal)
                    .padding(.vertical, theme.resolvedPaddingVertical)
                    .frame(maxWidth: width != nil ? .infinity : nil)
            }
            .buttonStyle(MiniGameButtonStyle(theme: theme, showPulsate: showPulsate))
            .frame(width: width)

            // Badge dot (matching React's badge with ping animation)
            if showBadge {
                ZStack {
                    // Ping circle (animated expanding circle)
                    Circle()
                        .fill(Color(hex: theme.resolvedBadgeColor))
                        .frame(width: 10, height: 10)
                        .scaleEffect(badgePingScale)
                        .opacity(badgePingOpacity)

                    // Static circle
                    Circle()
                        .fill(Color(hex: theme.resolvedBadgeColor))
                        .frame(width: 10, height: 10)
                }
                .offset(x: 4, y: -4)
                .onAppear {
                    startBadgePing()
                }
            }
        }
        .frame(width: width)
    }

    // MARK: - Badge Ping Animation

    /// Starts the badge ping animation (matching React's @keyframes miniGameBadgePing)
    private func startBadgePing() {
        withAnimation(
            .linear(duration: 1.0)
            .repeatForever(autoreverses: false)
        ) {
            badgePingScale = 2.0
            badgePingOpacity = 0
        }
    }
}

// MARK: - MiniGameButtonStyle

/// Custom button style that provides the pulsate glow animation and press feedback.
/// Matches React's inline styles and @keyframes miniGameButtonPulsate.
private struct MiniGameButtonStyle: ButtonStyle {
    let theme: MiniGameButtonTheme
    let showPulsate: Bool

    @State private var pulsateScale: CGFloat = 1.0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: theme.resolvedCornerRadius)
                    .fill(Color(hex: theme.resolvedBackgroundColor))
            )
            .overlay(
                Group {
                    if theme.resolvedBorderWidth > 0 {
                        RoundedRectangle(cornerRadius: theme.resolvedCornerRadius)
                            .stroke(
                                Color(hex: theme.resolvedBorderColor),
                                lineWidth: theme.resolvedBorderWidth
                            )
                    }
                }
            )
            // Pulsate glow (matching React's box-shadow animation)
            .shadow(
                color: showPulsate
                    ? Color(hex: theme.resolvedPulsateColor).opacity(Double(0.8 * (1 - pulsateScale / 1.15)))
                    : .clear,
                radius: showPulsate ? 12 * pulsateScale : 0
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onAppear {
                if showPulsate {
                    startPulsate()
                }
            }
    }

    private func startPulsate() {
        withAnimation(
            .easeInOut(duration: 2.0)
            .repeatForever(autoreverses: false)
        ) {
            pulsateScale = 1.15
        }
    }
}
