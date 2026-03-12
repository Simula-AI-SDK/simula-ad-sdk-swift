import SwiftUI

// MARK: - MiniGameInvitation

/// A banner-style invitation card that slides in from the top (or bottom, or fades in).
/// Translates `MiniGameInvitation.tsx` from the React SDK.
///
/// Features:
/// - Fixed-position banner (consumer places via .overlay or ZStack)
/// - Character image + title text + subtitle text + CTA button + close button
/// - Entry/exit animations: slideDown, slideUp, fadeIn, none (matching React's animation types)
/// - Auto-close timer (matching React's setTimeout auto-close)
/// - Backdrop blur (matching React's backdropFilter: 'blur(16px)')
/// - Theming via MiniGameInvitationTheme
///
/// Usage:
/// ```swift
/// ZStack(alignment: .top) {
///     ContentView()
///     MiniGameInvitation(
///         charImage: "https://example.com/char.png",
///         isOpen: showInvitation,
///         onClick: { showGameMenu = true },
///         onClose: { showInvitation = false }
///     )
/// }
/// ```
public struct MiniGameInvitation: View {
    // MARK: - Props (matching React's MiniGameInvitationProps)

    var titleText: String = "Want to play a game?"
    var subText: String = "Take a break and challenge yourself!"
    var ctaText: String = "Play a Game"
    let charImage: String
    var animation: MiniGameInvitationAnimation = .auto
    var theme: MiniGameInvitationTheme = MiniGameInvitationTheme()
    var isOpen: Bool = false
    /// Milliseconds before auto-close. nil = no auto-close. (matching React's autoCloseDuration)
    var autoCloseDuration: TimeInterval?
    /// Component width in points. nil = fills container.
    var width: CGFloat?
    /// Vertical offset from top of screen. Default 5% of screen height.
    var topOffset: CGFloat?
    let onClick: () -> Void
    var onClose: (() -> Void)?

    public init(
        titleText: String = "Want to play a game?",
        subText: String = "Take a break and challenge yourself!",
        ctaText: String = "Play a Game",
        charImage: String,
        animation: MiniGameInvitationAnimation = .auto,
        theme: MiniGameInvitationTheme = MiniGameInvitationTheme(),
        isOpen: Bool = false,
        autoCloseDuration: TimeInterval? = nil,
        width: CGFloat? = nil,
        topOffset: CGFloat? = nil,
        onClick: @escaping () -> Void,
        onClose: (() -> Void)? = nil
    ) {
        self.titleText = titleText
        self.subText = subText
        self.ctaText = ctaText
        self.charImage = charImage
        self.animation = animation
        self.theme = theme
        self.isOpen = isOpen
        self.autoCloseDuration = autoCloseDuration
        self.width = width
        self.topOffset = topOffset
        self.onClick = onClick
        self.onClose = onClose
    }

    // MARK: - State (matching React's useState calls)

    @State private var imageError = false
    @State private var isClosing = false
    @State private var shouldRender = false
    @State private var autoCloseTask: Task<Void, Never>?

    // MARK: - Constants

    private let animationDuration: Double = 0.3 // 300ms matching React

    // MARK: - Computed

    private var resolvedAnimation: MiniGameInvitationAnimation {
        animation == .auto ? .slideDown : animation
    }

    // MARK: - Body

    public var body: some View {
        if shouldRender {
            HStack(spacing: 0) {
                // Layout direction based on charImageAnchor (matching React's flexDirection logic)
                if theme.resolvedCharImageAnchor == .left {
                    characterImageSection
                    textAndCtaSection
                } else {
                    textAndCtaSection
                    characterImageSection
                }
            }
            .frame(height: 120)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: theme.resolvedCornerRadius)
                    .fill(Color(hex: theme.resolvedBackgroundColor))
                    .background(
                        // Backdrop blur (matching React's backdropFilter: 'blur(16px)')
                        RoundedRectangle(cornerRadius: theme.resolvedCornerRadius)
                            .fill(.ultraThinMaterial)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.resolvedCornerRadius)
                    .stroke(
                        Color(hex: theme.resolvedBorderColor),
                        lineWidth: theme.resolvedBorderWidth
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.resolvedCornerRadius))
            .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
            .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
            // Close button overlay (matching Kotlin's close button with fallback textColor at 0.4 alpha)
            .overlay(alignment: .topTrailing) {
                Button(action: { handleDismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: theme.resolvedTextColor).opacity(0.4)) // Uses base textColor like Kotlin
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16)
            // Animation transitions
            .transition(resolvedTransition)
            .offset(y: isClosing ? exitOffset : 0)
            .opacity(isClosing ? 0 : 1)
            .animation(.easeOut(duration: animationDuration), value: isClosing)
            .onAppear {
                setupAutoClose()
            }
            .onDisappear {
                autoCloseTask?.cancel()
            }
        }

        // Hidden modifier to react to isOpen changes
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isOpen) { newValue in
                handleOpenChange(newValue)
            }
            .onAppear {
                if isOpen {
                    handleOpenChange(true)
                }
            }
    }

    // MARK: - Character Image Section (matching React's character image div)

    @ViewBuilder
    private var characterImageSection: some View {
        let padding: EdgeInsets = theme.resolvedCharImageAnchor == .right
            ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16)
            : EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0)

        VStack {
            if !imageError {
                AsyncImage(url: URL(string: charImage)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        fallbackImage
                            .onAppear { imageError = true }
                    default:
                        Color.clear
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: theme.resolvedCharImageCornerRadius))
            } else {
                fallbackImage
            }
        }
        .padding(padding)
    }

    @ViewBuilder
    private var fallbackImage: some View {
        RoundedRectangle(cornerRadius: theme.resolvedCharImageCornerRadius)
            .fill(Color(hex: "#F3F4F6"))
            .frame(width: 88, height: 88)
            .overlay(
                Text("🎮")
                    .font(.system(size: 32))
            )
    }

    // MARK: - Text and CTA Section (matching React's left side div)

    @ViewBuilder
    private var textAndCtaSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title text (uses resolvedTitleTextColor matching Kotlin's titleTextColor)
            Text(titleText)
                .font(fontForFamily(theme.fontFamily, size: 16, weight: .bold))
                .foregroundColor(Color(hex: theme.resolvedTitleTextColor))
                .lineLimit(2)

            // Sub text (uses resolvedSubTextColor matching Kotlin's subTextColor)
            Text(subText)
                .font(fontForFamily(theme.fontFamily, size: 13, weight: .regular))
                .foregroundColor(Color(hex: theme.resolvedSubTextColor).opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.bottom, 6)

            // CTA button (matching React's CTA button style)
            Button(action: { handleCtaClick() }) {
                HStack(spacing: 6) {
                    Text("▶")
                        .font(.system(size: 12))
                    Text(ctaText)
                        .font(fontForFamily(theme.fontFamily, size: 13, weight: .semibold))
                }
                .foregroundColor(Color(hex: theme.resolvedCtaTextColor))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: theme.resolvedCtaColor))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transition Helpers

    private var resolvedTransition: AnyTransition {
        switch resolvedAnimation {
        case .slideDown, .auto:
            return .move(edge: .top).combined(with: .opacity)
        case .slideUp:
            return .move(edge: .bottom).combined(with: .opacity)
        case .fadeIn:
            return .opacity
        case .none:
            return .identity
        }
    }

    private var exitOffset: CGFloat {
        switch resolvedAnimation {
        case .slideDown, .auto: return -20
        case .slideUp: return 20
        case .fadeIn, .none: return 0
        }
    }

    // MARK: - Actions (matching React's handler functions)

    private func handleOpenChange(_ newValue: Bool) {
        if newValue {
            isClosing = false
            imageError = false
            withAnimation(.easeOut(duration: animationDuration)) {
                shouldRender = true
            }
        } else {
            autoCloseTask?.cancel()
            withAnimation(.easeOut(duration: animationDuration)) {
                shouldRender = false
            }
            isClosing = false
        }
    }

    private func handleCtaClick() {
        autoCloseTask?.cancel()
        onClose?()
        onClick()
        if resolvedAnimation == .none {
            withAnimation { shouldRender = false }
        } else {
            isClosing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                withAnimation { shouldRender = false }
                isClosing = false
            }
        }
    }

    private func handleDismiss() {
        autoCloseTask?.cancel()
        onClose?()
        if resolvedAnimation == .none {
            withAnimation { shouldRender = false }
        } else {
            isClosing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                withAnimation { shouldRender = false }
                isClosing = false
            }
        }
    }

    private func setupAutoClose() {
        guard let duration = autoCloseDuration, duration > 0 else { return }
        autoCloseTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000)) // ms to ns
            guard !Task.isCancelled else { return }
            await MainActor.run {
                handleDismiss()
            }
        }
    }
}
