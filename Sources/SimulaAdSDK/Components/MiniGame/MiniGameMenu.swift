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

/// A modal game catalog menu that displays available games, allows search/filtering,
/// and launches game iframes. After a game session, can display a post-game ad.
///
/// Translates `MiniGameMenu.tsx` from the React SDK.
///
/// Features:
/// - Full-screen modal with dark backdrop overlay
/// - Character avatar + "Play a Game with {charName}" header
/// - Search bar to filter games by name
/// - GameGrid with paginated 3-column layout
/// - Game selection opens GameIframeView (full-screen cover)
/// - After game close, fetches and shows post-game ad (AdOverlayView)
/// - Loading spinner and error states
/// - Escape handling via native SwiftUI dismiss
/// - Body scroll prevention (handled automatically by full-screen overlays)
///
/// Usage:
/// ```swift
/// MiniGameMenu(
///     isOpen: $showGameMenu,
///     onClose: { showGameMenu = false },
///     charName: "Luna",
///     charID: "char-123",
///     charImage: "https://example.com/luna.png",
///     messages: chatMessages,
///     theme: MiniGameTheme(backgroundColor: "#1a1a2e")
/// )
/// ```
public struct MiniGameMenu: View {
    // MARK: - Props (matching React's MiniGameMenuProps)

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

    // MARK: - State (matching React's useState calls)

    @EnvironmentObject private var provider: SimulaProvider
    @State private var selectedGameId: String?
    @State private var imageError = false
    @State private var games: [GameData] = []
    @State private var searchQuery = ""
    @State private var isSearchFocused = false
    @State private var menuId: String?
    @State private var catalogLoading = true
    @State private var catalogError = false
    @State private var adFetched = false
    @State private var adIframeUrl: String?
    @State private var currentAdId: String?
    @State private var showGameIframe = false
    @State private var showAdOverlay = false
    /// Tracks last game height for bottom sheet ad overlay (matching Kotlin)
    @State private var lastGameHeightDp: CGFloat?
    /// Tracks whether last game was in bottom sheet mode (matching Kotlin)
    @State private var lastGameWasBottomSheet = false

    private let api = SimulaAPI()

    // MARK: - Computed

    /// Filter games based on search query (matching React's filteredGames useMemo)
    private var filteredGames: [GameData] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return games }
        let query = trimmed.lowercased()
        return games.filter { $0.name.lowercased().contains(query) }
    }

    /// Character initials for fallback avatar (matching React's getInitials)
    private var charInitials: String {
        charName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
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
                // Backdrop (matching React: backgroundColor: 'rgba(0, 0, 0, 0.5)')
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { handleClose() }
                    .transition(.opacity)
                    .zIndex(1)

                // Modal content (matching React's modal-content div)
                VStack(spacing: 0) {
                    // Header
                    headerView

                    // Divider
                    Rectangle()
                        .fill(Color(hex: theme.resolvedBorderColor))
                        .frame(height: 1)

                    // Content area
                    contentArea
                }
                .frame(maxWidth: 600)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(hex: theme.resolvedBackgroundColor))
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(
                    color: Color.black.opacity(0.1),
                    radius: 25,
                    x: 0,
                    y: 20
                )
                .padding(16)
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
        .onChange(of: isOpen) { newValue in
            if !newValue {
                // Reset search when menu closes (matching React useEffect)
                searchQuery = ""
                isSearchFocused = false
            }
        }
    }

    // MARK: - Header (matching React's header section)

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            // Character Avatar (matching React's circular avatar with fallback)
            ZStack {
                Circle()
                    .fill(Color(hex: theme.resolvedBackgroundColor))
                    .frame(width: 40, height: 40)

                if !imageError, !charImage.isEmpty {
                    AsyncImage(url: URL(string: charImage)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            Text(charInitials)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(hex: theme.resolvedBackgroundColor))
                                .onAppear { imageError = true }
                        default:
                            Color.clear
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                } else {
                    Text(charInitials)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(hex: theme.resolvedBackgroundColor))
                }
            }

            // Header Text (matching React: "Play a Game with {charName}")
            VStack(alignment: .leading) {
                Text("Play a Game with \(charName)")
                    .font(.custom(theme.resolvedTitleFont, size: 18))
                    .fontWeight(.semibold)
                    .foregroundColor(Color(hex: theme.resolvedTitleFontColor))
                    .lineLimit(1)
            }

            Spacer()

            // Close Button (matching React's × button)
            Button(action: { handleClose() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(hex: theme.resolvedSecondaryFontColor))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(20)
        .background(
            theme.headerColor.map { Color(hex: $0) }
        )
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        VStack(spacing: 0) {
            if catalogLoading {
                // Loading state (matching React's loading spinner + "Loading games...")
                Spacer()
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
                Spacer()
            } else if catalogError {
                // Error state (matching Kotlin's games_unavailable image)
                Spacer()
                VStack(spacing: 16) {
                    // Bundled games unavailable image (matching Kotlin's painterResource(R.drawable.games_unavailable))
                    if let imageUrl = Bundle.module.url(forResource: "games_unavailable", withExtension: "png"),
                       let imageData = try? Data(contentsOf: imageUrl),
                       let uiImage = platformImage(from: imageData) {
                        Image(platformImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 150, height: 150)
                            .clipShape(Circle())
                    } else {
                        // Fallback if image fails to load
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
                Spacer()
            } else {
                VStack(spacing: 0) {
                    // Search Bar (matching React's search input)
                    if !games.isEmpty {
                        searchBarView
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 16)
                    }

                    // No results message
                    if filteredGames.isEmpty && !searchQuery.isEmpty {
                        Text("No games found for \"\(searchQuery)\"")
                            .font(.custom(theme.resolvedSecondaryFont, size: 14))
                            .foregroundColor(Color(hex: theme.resolvedSecondaryFontColor))
                            .padding(.vertical, 24)
                    } else {
                        // Game Grid (outside ScrollView so swipe gestures work)
                        GameGrid(
                            games: filteredGames,
                            maxGamesToShow: maxGamesToShow.rawValue,
                            charID: charID,
                            theme: theme,
                            onGameSelect: { gameId, gameName in
                                handleGameSelect(gameId: gameId, gameName: gameName)
                            },
                            menuId: menuId
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
    }

    // MARK: - Search Bar (matching React's search input with icon and clear button)

    @ViewBuilder
    private var searchBarView: some View {
        HStack(spacing: 8) {
            // Search icon (matching React's SVG search icon)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundColor(Color(hex: theme.resolvedSecondaryFontColor))

            // Text field
            TextField("Search games...", text: $searchQuery, prompt: Text("Search games...").foregroundColor(Color(hex: theme.resolvedSecondaryFontColor)))
                .font(.custom(theme.resolvedSecondaryFont, size: 14))
                .foregroundColor(Color(hex: theme.resolvedTitleFontColor))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            // Clear button (matching React's × clear button)
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: theme.resolvedSecondaryFontColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: theme.resolvedBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    Color(hex: isSearchFocused
                          ? theme.resolvedAccentColor
                          : theme.resolvedBorderColor),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Actions (matching React's handler functions)

    private func handleClose() {
        onClose()
    }

    private func handleGameSelect(gameId: String, gameName: String) {
        // Track menu game click if menuId is available (matching React)
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
        // Reset ad tracking when a new game is selected (matching React)
        adFetched = false
        currentAdId = nil
    }

    private func handleAdIdReceived(_ adId: String) {
        currentAdId = adId
    }

    /// Handles closing the game iframe.
    /// If ad hasn't been fetched yet, fetch and display it. Otherwise just close.
    /// Matching React's handleIframeClose exactly.
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
            // Ad already fetched, just close (matching React: don't double count impressions)
            showGameIframe = false
            selectedGameId = nil
        }
    }

    private func handleAdIframeClose() {
        showAdOverlay = false
        adIframeUrl = nil
        // Keep adFetched as true so we don't show another ad (matching React)
    }

    // MARK: - Bundled Image Helpers

    /// Loads a bundled image as a platform-specific image type.
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
