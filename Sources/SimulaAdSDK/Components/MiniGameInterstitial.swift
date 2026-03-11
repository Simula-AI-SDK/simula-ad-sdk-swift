import SwiftUI

// MARK: - Platform Image Helpers (for bundled assets)

#if os(iOS)
private typealias InterstitialPlatformImage = UIImage
private extension Image {
    init(interstitialPlatformImage: UIImage) {
        self.init(uiImage: interstitialPlatformImage)
    }
}
#elseif os(macOS)
private typealias InterstitialPlatformImage = NSImage
private extension Image {
    init(interstitialPlatformImage: NSImage) {
        self.init(nsImage: interstitialPlatformImage)
    }
}
#endif

// MARK: - MiniGameInterstitial

/// A full-screen interstitial overlay that invites the user to play a game.
/// Translates `MiniGameInterstitial.tsx` from the React SDK.
///
/// Features:
/// - Full-screen overlay with background image + dark gradient overlay
/// - Uses bundled background image when no URL provided (matching Kotlin)
/// - Character circle image (AsyncImage with fallback emoji)
/// - Invitation text + CTA button + close button
/// - Fade-in animation (matching React's miniGameInterstitialFadeIn)
/// - Tapping anywhere on the overlay triggers CTA (matching React's div onClick)
/// - Close button stops propagation (matching React's e.stopPropagation())
/// - Internal close state that resets when parent re-opens
///
/// Usage:
/// ```swift
/// MiniGameInterstitial(
///     charImage: "https://example.com/char.png",
///     isOpen: showInterstitial,
///     onClick: { showGameMenu = true },
///     onClose: { showInterstitial = false }
/// )
/// ```
public struct MiniGameInterstitial: View {
    // MARK: - Props (matching React's MiniGameInterstitialProps)

    let charImage: String
    var invitationText: String = "Want to play a game?"
    var ctaText: String = "Play a Game"
    /// Optional background image URL. nil = uses bundled default image.
    var backgroundImage: String?
    var theme: MiniGameInterstitialTheme = MiniGameInterstitialTheme()
    var isOpen: Bool = false
    let onClick: () -> Void
    var onClose: (() -> Void)?

    public init(
        charImage: String,
        invitationText: String = "Want to play a game?",
        ctaText: String = "Play a Game",
        backgroundImage: String? = nil,
        theme: MiniGameInterstitialTheme = MiniGameInterstitialTheme(),
        isOpen: Bool = false,
        onClick: @escaping () -> Void,
        onClose: (() -> Void)? = nil
    ) {
        self.charImage = charImage
        self.invitationText = invitationText
        self.ctaText = ctaText
        self.backgroundImage = backgroundImage
        self.theme = theme
        self.isOpen = isOpen
        self.onClick = onClick
        self.onClose = onClose
    }

    // MARK: - State (matching React's useState calls)

    @State private var imageError = false
    @State private var closedInternally = false
    @State private var appeared = false

    // MARK: - Computed (matching React's const isVisible = isOpen && !closedInternally)

    private var isVisible: Bool {
        isOpen && !closedInternally
    }

    // MARK: - Body

    public var body: some View {
        if isVisible {
            ZStack {
                // Background: image with dark overlay (matching React's backgroundImage + linear-gradient)
                backgroundLayer

                // Content (matching React's content div)
                VStack(spacing: 24) {
                    // Character image in circle (matching React's circular character image)
                    characterCircle

                    // Invitation text (matching React's invitation text div)
                    Text(invitationText)
                        .font(fontForFamily(theme.fontFamily, size: theme.resolvedTitleFontSize, weight: .bold))
                        .foregroundColor(Color(hex: theme.resolvedTitleTextColor))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .lineSpacing(theme.resolvedTitleFontSize * 0.3) // lineHeight: 1.3

                    // CTA button (matching React's CTA button)
                    Button(action: { handleCtaClick() }) {
                        HStack(spacing: 8) {
                            Text("▶")
                                .font(.system(size: theme.resolvedCtaFontSize - 2))
                            Text(ctaText)
                                .font(fontForFamily(theme.fontFamily, size: theme.resolvedCtaFontSize, weight: .semibold))
                        }
                        .foregroundColor(Color(hex: theme.resolvedCtaTextColor))
                        .padding(.vertical, 14)
                        .padding(.horizontal, 32)
                        .background(
                            RoundedRectangle(cornerRadius: theme.resolvedCtaCornerRadius)
                                .fill(Color(hex: theme.resolvedCtaColor))
                        )
                    }
                    .buttonStyle(InterstitialCtaButtonStyle())
                }

                // Close button — top right (matching React's absolute positioned close button)
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { handleClose() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Color(hex: "#1F2937"))
                                .frame(width: 44, height: 44)
                                .background(
                                    Circle()
                                        .fill(Color.white.opacity(0.9))
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 16)
                        .padding(.trailing, 16)
                        .accessibilityLabel("Close")
                    }
                    Spacer()
                }
            }
            // Tapping anywhere triggers CTA (matching React's div onClick={handleCtaClick})
            .contentShape(Rectangle())
            .onTapGesture { handleCtaClick() }
            .ignoresSafeArea()
            #if os(iOS)
            .statusBarHidden()
            #endif
            .opacity(appeared ? 1 : 0)
            .animation(.easeIn(duration: 0.3), value: appeared)
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
        }

        // Hidden modifier to react to isOpen changes
        // (matching React's useEffect on isOpen to reset closedInternally and imageError)
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isOpen) { newValue in
                if newValue {
                    closedInternally = false
                    imageError = false
                }
            }
            .onChange(of: charImage) { _ in
                imageError = false
            }
    }

    // MARK: - Background Layer (matching Kotlin's background image handling)

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            if let bgUrl = backgroundImage, let url = URL(string: bgUrl) {
                // Custom background image (user-provided URL)
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Color.black
                    }
                }
                .ignoresSafeArea()
            } else {
                // Bundled default background image (matching Kotlin's painterResource(R.drawable.minigame_interstitial_background))
                bundledBackgroundImage
                    .ignoresSafeArea()
            }

            // Dark gradient overlay (matching React's linear-gradient(rgba(0,0,0,0.6), rgba(0,0,0,0.6)))
            Color.black.opacity(0.6)
                .ignoresSafeArea()
        }
    }

    /// Loads the bundled interstitial background image, falling back to solid color.
    @ViewBuilder
    private var bundledBackgroundImage: some View {
        #if os(iOS) || os(macOS)
        if let imageUrl = Bundle.module.url(forResource: "minigame_interstitial_background", withExtension: "png"),
           let imageData = try? Data(contentsOf: imageUrl),
           let platformImg = InterstitialPlatformImage(data: imageData) {
            Image(interstitialPlatformImage: platformImg)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Color(hex: "#1a1a2e")
        }
        #else
        Color(hex: "#1a1a2e")
        #endif
    }

    // MARK: - Character Circle (matching React's circular character image with fallback)

    @ViewBuilder
    private var characterCircle: some View {
        if !imageError {
            AsyncImage(url: URL(string: charImage)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    fallbackCircle
                        .onAppear { imageError = true }
                default:
                    Color.clear
                }
            }
            .frame(width: theme.resolvedCharacterSize, height: theme.resolvedCharacterSize)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 3)
            )
        } else {
            fallbackCircle
        }
    }

    @ViewBuilder
    private var fallbackCircle: some View {
        Circle()
            .fill(Color.white.opacity(0.15))
            .frame(width: theme.resolvedCharacterSize, height: theme.resolvedCharacterSize)
            .overlay(
                Text("🎮")
                    .font(.system(size: theme.resolvedCharacterSize * 0.4))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 3)
            )
    }

    // MARK: - Font Helper

    private func fontForFamily(_ family: String?, size: CGFloat, weight: Font.Weight) -> Font {
        if let family = family {
            return .custom(family, size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    // MARK: - Actions (matching React's handler functions)

    private func handleClose() {
        closedInternally = true
        onClose?()
    }

    private func handleCtaClick() {
        closedInternally = true
        onClick()
    }
}

// MARK: - InterstitialCtaButtonStyle (matching React's hover/press effects)

private struct InterstitialCtaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
