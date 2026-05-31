#if os(iOS)
import SwiftUI
import UIKit

// MARK: - InterstitialPresenter

/// Presents the imperative interstitial full-screen in a dedicated `UIWindow`,
/// independent of the host app's view-controller stack.
///
/// The presentation is a two-phase flow inside one window: an invite teaser
/// first, then — once the user taps the CTA — the existing `MiniGameMenu`
/// (game → post-game ad). Hosting in its own window (above `.normal`) lets the
/// imperative API present from anywhere — SwiftUI or UIKit hosts alike. The
/// shared `SimulaProvider` is injected into the SwiftUI environment so
/// `MiniGameMenu`/`GameIframeView` keep reading `@EnvironmentObject var provider`.
@MainActor
final class InterstitialPresenter {
    private var window: UIWindow?
    private var onClose: (() -> Void)?

    /// Presents the teaser. `onClick` fires when the CTA is tapped (CLICKED);
    /// `onClose` fires once the window has been torn down (CLOSED).
    func present(
        provider: SimulaProvider,
        preloadedCatalog: CatalogResponse,
        charID: String,
        charName: String,
        charImage: String,
        charDesc: String?,
        invitationText: String,
        ctaText: String,
        backgroundImage: String?,
        inviteTheme: MiniGameInterstitialTheme,
        menuTheme: MiniGameTheme,
        messages: [Message],
        maxGamesToShow: MaxGamesToShow,
        delegateChar: Bool,
        onClick: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        guard let scene = Self.activeWindowScene() else {
            // No scene to present in — reset the ad immediately.
            onClose()
            return
        }
        self.onClose = onClose

        let root = InterstitialHostView(
            charID: charID,
            charName: charName,
            charImage: charImage,
            charDesc: charDesc,
            invitationText: invitationText,
            ctaText: ctaText,
            backgroundImage: backgroundImage,
            inviteTheme: inviteTheme,
            menuTheme: menuTheme,
            messages: messages,
            maxGamesToShow: maxGamesToShow,
            delegateChar: delegateChar,
            preloadedCatalog: preloadedCatalog,
            onClick: onClick,
            onRequestDismiss: { [weak self] in self?.dismiss() }
        )
        .environmentObject(provider)

        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
    }

    /// Tears down the presentation window and fires the CLOSED callback once.
    private func dismiss() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    /// Finds a foreground window scene to attach the overlay window to.
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return active
        }
        return scenes.compactMap { $0 as? UIWindowScene }.first
    }
}

// MARK: - InterstitialHostView

/// SwiftUI container that drives the teaser → menu transition and the fade-out
/// before the hosting window is removed.
private struct InterstitialHostView: View {
    let charID: String
    let charName: String
    let charImage: String
    let charDesc: String?
    let invitationText: String
    let ctaText: String
    let backgroundImage: String?
    let inviteTheme: MiniGameInterstitialTheme
    let menuTheme: MiniGameTheme
    let messages: [Message]
    let maxGamesToShow: MaxGamesToShow
    let delegateChar: Bool
    let preloadedCatalog: CatalogResponse
    let onClick: () -> Void
    let onRequestDismiss: () -> Void

    @State private var showMenu = false
    @State private var menuIsOpen = true
    @State private var visible = true

    /// Matches the teaser/menu dismiss animation before the window is removed.
    private let dismissAnimationDuration: TimeInterval = 0.25

    var body: some View {
        ZStack {
            if showMenu {
                MiniGameMenu(
                    isOpen: $menuIsOpen,
                    onClose: { handleClose() },
                    charName: charName,
                    charID: charID,
                    charImage: charImage,
                    messages: messages,
                    charDesc: charDesc,
                    maxGamesToShow: maxGamesToShow,
                    theme: menuTheme,
                    delegateChar: delegateChar,
                    preloadedCatalog: preloadedCatalog
                )
                .transition(.opacity)
            } else {
                InterstitialInviteView(
                    charImage: charImage,
                    invitationText: invitationText,
                    ctaText: ctaText,
                    backgroundImage: backgroundImage,
                    theme: inviteTheme,
                    onClick: { handleCtaClick() },
                    onClose: { handleClose() }
                )
                .transition(.opacity)
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: dismissAnimationDuration), value: visible)
        .ignoresSafeArea()
    }

    private func handleCtaClick() {
        onClick() // CLICKED
        withAnimation(.easeInOut(duration: dismissAnimationDuration)) {
            showMenu = true
        }
    }

    private func handleClose() {
        // Fade the whole surface out, then remove the hosting window.
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            onRequestDismiss()
        }
    }
}

// MARK: - InterstitialInviteView

/// The full-screen invite teaser shown before the game menu: background image +
/// dark overlay, circular character image, headline, CTA button, and a close
/// button. Tapping anywhere triggers the CTA; the close button dismisses.
private struct InterstitialInviteView: View {
    let charImage: String
    let invitationText: String
    let ctaText: String
    let backgroundImage: String?
    let theme: MiniGameInterstitialTheme
    let onClick: () -> Void
    let onClose: () -> Void

    @State private var imageError = false

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 24) {
                characterCircle

                Text(invitationText)
                    .font(fontForFamily(theme.fontFamily, size: theme.resolvedTitleFontSize, weight: .bold))
                    .foregroundColor(Color(hex: theme.resolvedTitleTextColor))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .lineSpacing(theme.resolvedTitleFontSize * 0.3)

                Button(action: { onClick() }) {
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

            // Close button — top right
            VStack {
                HStack {
                    Spacer()
                    Button(action: { onClose() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Color(hex: "#1F2937"))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
        }
        // Tapping anywhere triggers the CTA.
        .contentShape(Rectangle())
        .onTapGesture { onClick() }
        .ignoresSafeArea()
        .hideStatusBar(true)
        .onChange(of: charImage) { _ in imageError = false }
    }

    // MARK: Background

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            if let bgUrl = backgroundImage, let url = URL(string: bgUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.black
                    }
                }
                .ignoresSafeArea()
                .clipped()
            } else {
                bundledBackgroundImage
                    .ignoresSafeArea()
            }

            Color.black.opacity(0.6)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var bundledBackgroundImage: some View {
        if let platformImg = BundledImageCache.image(named: "minigame_interstitial_background") {
            Image(platformImage: platformImg)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        } else {
            Color(hex: "#1a1a2e")
        }
    }

    // MARK: Character circle

    @ViewBuilder
    private var characterCircle: some View {
        if !imageError {
            CachedAsyncImage(url: URL(string: charImage)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    fallbackCircle.onAppear { imageError = true }
                default:
                    Color.clear
                }
            }
            .frame(width: theme.resolvedCharacterSize, height: theme.resolvedCharacterSize)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 3))
        } else {
            fallbackCircle
        }
    }

    @ViewBuilder
    private var fallbackCircle: some View {
        Circle()
            .fill(Color.white.opacity(0.15))
            .frame(width: theme.resolvedCharacterSize, height: theme.resolvedCharacterSize)
            .overlay(Text("🎮").font(.system(size: theme.resolvedCharacterSize * 0.4)))
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 3))
    }
}

// MARK: - InterstitialCtaButtonStyle

private struct InterstitialCtaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
#endif
