import SwiftUI

// MARK: - Platform Image Helpers

#if os(iOS)
private typealias PlatformImage = UIImage
private extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif os(macOS)
private typealias PlatformImage = NSImage
private extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif

// MARK: - MiniGameMenu

/// A modal game catalog menu that displays available games and launches game iframes.
/// After a game session, can display a post-game ad.
///
/// Translates `MiniGameMenu.kt` from the Kotlin SDK.
public struct MiniGameMenu: View {
    // MARK: - Props

    @Binding var isOpen: Bool
    let onClose: () -> Void
    let charName: String
    let charID: String
    let charImage: String
    var messages: [Message] = []
    var charDesc: String?
    var maxGamesToShow: MaxGamesToShow = .six
    var theme: MiniGameTheme = MiniGameTheme()
    var delegateChar: Bool = true

    public init(
        isOpen: Binding<Bool>,
        onClose: @escaping () -> Void,
        charName: String,
        charID: String,
        charImage: String,
        messages: [Message] = [],
        charDesc: String? = nil,
        maxGamesToShow: MaxGamesToShow = .six,
        theme: MiniGameTheme = MiniGameTheme(),
        delegateChar: Bool = true
    ) {
        self._isOpen = isOpen
        self.onClose = onClose
        self.charName = charName
        self.charID = charID
        self.charImage = charImage
        self.messages = messages
        self.charDesc = charDesc
        self.maxGamesToShow = maxGamesToShow
        self.theme = theme
        self.delegateChar = delegateChar
    }

    // MARK: - State

    @EnvironmentObject private var provider: SimulaProvider
    @State private var selectedGameId: String?
    @State private var imageError = false
    @State private var games: [GameData] = []
    @State private var menuId: String?
    @State private var catalogLoading = true
    @State private var catalogError = false
    @State private var adFetched = false
    @State private var adIframeUrl: String?
    @State private var currentAdId: String?
    @State private var showGameIframe = false
    @State private var showAdOverlay = false
    @State private var lastGameHeightDp: CGFloat?
    @State private var lastGameWasBottomSheet = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    private let api = SimulaAPI()

    // MARK: - Computed

    private var charInitials: String {
        charName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

    private var appliedSecondaryFontColor: Color {
        Color(hex: theme.resolvedSecondaryFontColor)
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Game Iframe (full-screen cover)
            if showGameIframe, let gameId = selectedGameId {
                GameIframeView(
                    gameId: gameId,
                    charID: charID,
                    charName: charName,
                    charImage: charImage,
                    messages: messages,
                    delegateChar: delegateChar,
                    onClose: { handleIframeClose() },
                    onAdIdReceived: { adId in handleAdIdReceived(adId) },
                    charDesc: charDesc,
                    menuId: menuId,
                    playableHeight: theme.playableHeight,
                    playableBorderColor: theme.resolvedPlayableBorderColor,
                    onDimensionsOnClose: { heightDp, isBottomSheet in
                        lastGameHeightDp = heightDp
                        lastGameWasBottomSheet = isBottomSheet
                    }
                )
                .transition(.opacity)
                .zIndex(2)
            }

            // Ad Overlay (full-screen cover)
            if showAdOverlay, let adUrl = adIframeUrl {
                AdOverlayView(
                    iframeUrl: adUrl,
                    onClose: { handleAdIframeClose() },
                    playableHeightDp: lastGameWasBottomSheet ? lastGameHeightDp : nil,
                    playableBorderColor: theme.resolvedPlayableBorderColor
                )
                .transition(.opacity)
                .zIndex(3)
            }

            // Modal (the game catalog menu)
            if isOpen {
                // Backdrop
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { handleClose() }
                    .transition(.opacity)
                    .zIndex(1)

                // Modal content
                GeometryReader { geometry in
                    let isMobile = isCompact
                    let modalWidth = isMobile ? geometry.size.width * 0.92 : geometry.size.width * 0.95
                    let modalHeight = isMobile ? geometry.size.height * 0.85 : geometry.size.height * 0.90

                    ZStack {
                        // Modal card
                        VStack(spacing: isMobile ? 12 : 0) {
                            // Header
                            headerView

                            // Content area
                            contentArea
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .padding(
                            EdgeInsets(
                                top: isMobile ? 12 : 16,
                                leading: isMobile ? 10 : 20,
                                bottom: isMobile ? 16 : 20,
                                trailing: isMobile ? 10 : 20
                            )
                        )
                        .frame(width: modalWidth, height: modalHeight)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(Color(hex: theme.resolvedBackgroundColor))

                                // Radial gradient overlays (matching Kotlin exactly)
                                RadialGradient(
                                    colors: [
                                        Color(red: 96/255, green: 165/255, blue: 250/255).opacity(0.11),
                                        .clear
                                    ],
                                    center: UnitPoint(
                                        x: 0.12,
                                        y: 0.16
                                    ),
                                    startRadius: 0,
                                    endRadius: 520
                                )
                                RadialGradient(
                                    colors: [
                                        Color(red: 59/255, green: 130/255, blue: 246/255).opacity(0.08),
                                        .clear
                                    ],
                                    center: UnitPoint(
                                        x: 0.86,
                                        y: 0.24
                                    ),
                                    startRadius: 0,
                                    endRadius: 440
                                )
                                RadialGradient(
                                    colors: [
                                        Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.07),
                                        .clear
                                    ],
                                    center: UnitPoint(
                                        x: 0.52,
                                        y: 0.88
                                    ),
                                    startRadius: 0,
                                    endRadius: 500
                                )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .shadow(
                            color: Color.black.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 20
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.scale(scale: 0.95).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: isOpen)
        .animation(.easeInOut(duration: 0.2), value: showGameIframe)
        .animation(.easeInOut(duration: 0.2), value: showAdOverlay)
        .task(id: isOpen) {
            if isOpen {
                await loadCatalog()
            }
        }
    }

    // MARK: - Header (matching Kotlin's Row layout exactly)
    // Kotlin layout: Row { Avatar(zIndex 2) | GameIcon(zIndex 1, offset -48) | Title(weight 1, offset -44) }
    // Close button absolutely positioned TopEnd

    @ViewBuilder
    private var headerView: some View {
        let isMobile = isCompact
        let avatarSize: CGFloat = isMobile ? 72 : 80
        let avatarRadius: CGFloat = isMobile ? 16 : 24

        ZStack(alignment: .topTrailing) {
            // Main row: avatar + game icon + title
            HStack(alignment: .center, spacing: 0) {
                // Character Avatar (zIndex 2 — draws ON TOP of game icon)
                ZStack {
                    RoundedRectangle(cornerRadius: avatarRadius)
                        .fill(Color.white.opacity(0.08))

                    if !imageError, !charImage.isEmpty {
                        AsyncImage(url: URL(string: charImage)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            case .failure:
                                Text(charInitials)
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(Color(hex: theme.resolvedTitleFontColor))
                                    .onAppear { imageError = true }
                            default:
                                Color.clear
                            }
                        }
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(RoundedRectangle(cornerRadius: avatarRadius))
                    } else {
                        Text(charInitials)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(Color(hex: theme.resolvedTitleFontColor))
                    }
                }
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(RoundedRectangle(cornerRadius: avatarRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: avatarRadius)
                        .stroke(Color(red: 120/255, green: 200/255, blue: 255/255).opacity(0.1), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.45), radius: 17, x: 0, y: 16)
                .zIndex(2)

                // Game icon (zIndex 1 — draws BEHIND avatar, offset -48 to overlap)
                ZStack {
                    // Radial glow (matching Kotlin colorStops exactly)
                    Circle()
                        .fill(
                            RadialGradient(
                                stops: [
                                    .init(color: Color(red: 192/255, green: 132/255, blue: 252/255).opacity(0.22), location: 0),
                                    .init(color: Color(red: 236/255, green: 72/255, blue: 153/255).opacity(0.12), location: 0.5),
                                    .init(color: .clear, location: 0.78),
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 40
                            )
                        )
                        .frame(width: 80, height: 80)

                    if let imageUrl = Bundle.module.url(forResource: "game_icon", withExtension: "png"),
                       let imageData = try? Data(contentsOf: imageUrl),
                       let uiImage = platformImage(from: imageData) {
                        Image(platformImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 56, height: 56)
                    }
                }
                .frame(width: 80, height: 80)
                .offset(x: -48)
                .zIndex(1)

                // Title text (offset -44 to compensate for glow container)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Play a Game with")
                        .font(.system(size: isMobile ? 18 : 19, weight: .black))
                        .foregroundColor(Color(hex: theme.resolvedTitleFontColor))
                        .tracking(-0.3)
                        .lineSpacing(2)
                    Text(charName)
                        .font(.system(size: isMobile ? 18 : 19, weight: .heavy))
                        .foregroundColor(Color(hex: theme.resolvedTitleFontColor).opacity(0.78))
                        .tracking(-0.3)
                        .lineSpacing(2)
                        .lineLimit(1)
                }
                .offset(x: -44)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Close button — absolute top-right (matching Kotlin exactly)
            Button(action: { handleClose() }) {
                ZStack {
                    Circle()
                        .fill(appliedSecondaryFontColor.opacity(0.08))
                    Circle()
                        .stroke(appliedSecondaryFontColor.opacity(0.12), lineWidth: 1)
                    Text("✕")
                        .font(.system(size: 14))
                        .foregroundColor(appliedSecondaryFontColor.opacity(0.92))
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(.leading, 8)
        .padding(.top, isMobile ? 18 : 10)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if catalogLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(
                        tint: Color(hex: theme.resolvedTitleFontColor)
                    ))
                    .scaleEffect(1.2)

                Text("Loading games...")
                    .font(.custom(theme.resolvedSecondaryFont, size: 14))
                    .foregroundColor(Color(hex: theme.resolvedSecondaryFontColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if catalogError {
            VStack(spacing: 16) {
                if let imageUrl = Bundle.module.url(forResource: "games_unavailable", withExtension: "png"),
                   let imageData = try? Data(contentsOf: imageUrl),
                   let uiImage = platformImage(from: imageData) {
                    Image(platformImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 150, height: 150)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color(hex: theme.resolvedBackgroundColor).opacity(0.5))
                        .frame(width: 150, height: 150)
                        .overlay(
                            Text("🎮")
                                .font(.system(size: 60))
                        )
                }

                Text("No games are available to play right now. Please check back later!")
                    .font(.custom(theme.resolvedSecondaryFont, size: 14))
                    .foregroundColor(Color(hex: theme.resolvedSecondaryFontColor))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GameGrid(
                games: games,
                maxGamesToShow: maxGamesToShow.rawValue,
                charID: charID,
                theme: theme,
                onGameSelect: { gameId, gameName in
                    handleGameSelect(gameId: gameId, gameName: gameName)
                },
                menuId: menuId
            )
        }
    }

    // MARK: - Actions

    private func handleClose() {
        onClose()
    }

    private func handleGameSelect(gameId: String, gameName: String) {
        if let menuId = menuId {
            Task {
                await api.trackMenuGameClick(
                    menuId: menuId,
                    gameName: gameName,
                    apiKey: provider.apiKey
                )
            }
        }

        handleClose()
        selectedGameId = gameId
        showGameIframe = true
        adFetched = false
        currentAdId = nil
    }

    private func handleAdIdReceived(_ adId: String) {
        currentAdId = adId
    }

    private func handleIframeClose() {
        if !adFetched {
            if let adId = currentAdId {
                Task {
                    do {
                        let iframeUrl = try await api.fetchAdForMinigame(aid: adId)
                        if let url = iframeUrl {
                            await MainActor.run {
                                self.adIframeUrl = url
                                self.adFetched = true
                                self.showAdOverlay = true
                            }
                        }
                    } catch { }
                }
            }
            showGameIframe = false
            selectedGameId = nil
        } else {
            showGameIframe = false
            selectedGameId = nil
        }
    }

    private func handleAdIframeClose() {
        showAdOverlay = false
        adIframeUrl = nil
    }

    // MARK: - Bundled Image Helpers

    private func platformImage(from data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)
        #elseif os(macOS)
        return NSImage(data: data)
        #else
        return nil
        #endif
    }

    private func loadCatalog() async {
        catalogLoading = true
        catalogError = false
        do {
            let response = try await api.fetchCatalog()

            // Preload all cover images before showing grid (matching Kotlin's awaitAll)
            let coverUrls = response.games.compactMap { game -> String? in
                let url = game.gifCover ?? game.iconUrl
                return url.isEmpty ? nil : url
            }
            await CoverImageCache.shared.preload(urls: coverUrls)

            await MainActor.run {
                self.games = response.games
                self.menuId = response.menuId.isEmpty ? nil : response.menuId
                self.catalogLoading = false
            }
        } catch {
            await MainActor.run {
                self.catalogError = true
                self.games = []
                self.menuId = nil
                self.catalogLoading = false
            }
        }
    }
}
