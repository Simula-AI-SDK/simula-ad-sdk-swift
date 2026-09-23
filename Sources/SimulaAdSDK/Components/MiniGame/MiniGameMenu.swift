import SwiftUI

// MARK: - MiniGameMenu

struct MiniGameCompatibilityPlan: Equatable {
    let rendersContent: Bool
    let seedsPreloadedCatalog: Bool
    let prewarmsWebView: Bool
    let fetchesCatalog: Bool
    let tracksClick: Bool
    let loadsGame: Bool
    let fetchesFallbacks: Bool
}

func miniGameCompatibilityPlan(
    providerCompatible: Bool,
    hasPreloadedCatalog: Bool
) -> MiniGameCompatibilityPlan {
    guard providerCompatible else {
        return MiniGameCompatibilityPlan(
            rendersContent: false,
            seedsPreloadedCatalog: false,
            prewarmsWebView: false,
            fetchesCatalog: false,
            tracksClick: false,
            loadsGame: false,
            fetchesFallbacks: false
        )
    }
    return MiniGameCompatibilityPlan(
        rendersContent: true,
        seedsPreloadedCatalog: hasPreloadedCatalog,
        prewarmsWebView: true,
        fetchesCatalog: !hasPreloadedCatalog,
        tracksClick: true,
        loadsGame: true,
        fetchesFallbacks: true
    )
}

struct MiniGameFallbackFetchRequest: Equatable, Sendable {
    let generation: Int
    let serveId: String
    let menuId: String?
}

enum MiniGameFallbackFetchResolution: Equatable, Sendable {
    case apply
    case rejectCurrent
    case stale
}

struct MiniGameFallbackFetchOwnership: Equatable, Sendable {
    private(set) var generation = 0
    private(set) var activeRequest: MiniGameFallbackFetchRequest?

    mutating func begin(serveId: String, menuId: String?) -> MiniGameFallbackFetchRequest {
        generation += 1
        let request = MiniGameFallbackFetchRequest(
            generation: generation,
            serveId: serveId,
            menuId: menuId
        )
        activeRequest = request
        return request
    }

    mutating func cancel() {
        generation += 1
        activeRequest = nil
    }

    mutating func resolve(
        _ request: MiniGameFallbackFetchRequest,
        taskCancelled: Bool,
        currentServeId: String?,
        currentMenuId: String?
    ) -> MiniGameFallbackFetchResolution {
        guard activeRequest == request else { return .stale }
        activeRequest = nil
        guard !taskCancelled,
              currentServeId == request.serveId,
              currentMenuId == request.menuId else { return .rejectCurrent }
        return .apply
    }
}

enum MiniGameFallbackVideoLifecycleEvent: Equatable, Sendable {
    case appear
    case disappear
}

enum MiniGameFallbackVideoLifecycleAction: Equatable, Sendable {
    case none
    case reconcile
    case release
}

struct MiniGameFallbackV2ScopeRecovery: Equatable, Sendable {
    let createScope: Bool
    let reattachCurrentPlayer: Bool
}

func miniGameFallbackV2ScopeRecovery(
    showAdOverlay: Bool,
    containsVideoPlanV2: Bool,
    hasScope: Bool,
    currentAdUsesVideoPlanV2: Bool,
    ownsCurrentPlayer: Bool
) -> MiniGameFallbackV2ScopeRecovery {
    let retainedV2Presentation = showAdOverlay && containsVideoPlanV2
    return MiniGameFallbackV2ScopeRecovery(
        createScope: retainedV2Presentation && !hasScope,
        reattachCurrentPlayer: retainedV2Presentation
            && currentAdUsesVideoPlanV2
            && ownsCurrentPlayer
    )
}

struct MiniGameFallbackVideoPreparationPlan: Equatable, Sendable {
    let prepareIndices: [Int]
    let discardIndices: [Int]
}

func miniGameFallbackVideoPreparationPlan(
    ads: [FallbackAd],
    around index: Int,
    preparedIndices: Set<Int>
) -> MiniGameFallbackVideoPreparationPlan {
    let desired: Set<Int>
    if ads.contains(where: \.usesVideoPlanV2Contract) {
        desired = ads.indices
            .first(where: { $0 >= index && ads[$0].usesVideoPlanV2 })
            .map { Set([$0]) } ?? []
    } else {
        desired = Set([index, index + 1].filter { candidate in
            guard ads.indices.contains(candidate),
                  case .video = ads[candidate].creativeContent else { return false }
            return true
        })
    }
    return MiniGameFallbackVideoPreparationPlan(
        prepareIndices: desired.subtracting(preparedIndices).sorted(),
        discardIndices: preparedIndices.subtracting(desired).sorted()
    )
}

#if os(iOS)
@MainActor
func reattachMiniGameFallbackV2Player(
    _ player: FullscreenVideoPlayer,
    to scope: VideoPlanPresentationScope
) {
    scope.updateMuted(player.isMuted)
    player.attachVideoPlanScope(scope)
}
#endif

func miniGameFallbackVideoLifecycleAction(
    event: MiniGameFallbackVideoLifecycleEvent,
    showAdOverlay: Bool,
    hasSelectedAd: Bool,
    selectedAdIsVideo: Bool,
    ownsCurrentPlayer: Bool
) -> MiniGameFallbackVideoLifecycleAction {
    if event == .disappear { return .release }
    guard showAdOverlay, hasSelectedAd else { return .none }
    if selectedAdIsVideo, ownsCurrentPlayer { return .none }
    return .reconcile
}

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
    /// Optional preloaded catalog. When set, the menu seeds its grid from it and
    /// skips the network fetch on open (used by the imperative interstitial's
    /// `load()` so the menu opens instantly without re-fetching).
    var preloadedCatalog: CatalogResponse?

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
        delegateChar: Bool = true,
        preloadedCatalog: CatalogResponse? = nil
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
        self.preloadedCatalog = preloadedCatalog
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
    @State private var fallbackFetchOwnership = MiniGameFallbackFetchOwnership()
    @State private var fallbackFetchTask: Task<Void, Never>?
    // Post-game ad screens (`GET /load/fallbacks/{serveId}`), revealed one per close tap.
    @State private var fallbackAds: [FallbackAd] = []
    @State private var fallbackAdIndex = 0
    @State private var fallbackVideoPlayer: FullscreenVideoPlayer?
    @State private var fallbackTerminalAdvanceState = FallbackTerminalAdvanceState()
    @State private var fallbackClickHandoffPending = false
    @State private var fallbackPresentationBlocked = false
    @State private var fallbackVideoPlanScope: VideoPlanPresentationScope?
    #if os(iOS)
    @State private var sceneReaderTracker = AdOverlayWindowSceneTracker()
    @State private var hostingWindowScene: UIWindowScene?
    @State private var fallbackVideoTokens: [Int: FullscreenVideoPreparationToken] = [:]
    @State private var fallbackVideoPreparationTasks: [Int: Task<Void, Never>] = [:]
    @State private var fallbackVideoPreparationGenerations: [Int: UUID] = [:]
    @State private var fallbackVideoPreparationDeadlineTask: Task<Void, Never>?
    @State private var fallbackVideoOwnershipIndex: Int?
    @State private var fallbackVideoOwnership: FallbackVideoOwnership<
        FullscreenVideoPlayer,
        FullscreenVideoPreparationToken
    >?
    #endif
    @State private var currentServeId: String?
    @State private var showGameIframe = false
    @State private var showAdOverlay = false
    @State private var lastGameHeightDp: CGFloat?
    @State private var lastGameWasBottomSheet = false
    @State private var adLoading = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    private let api = SimulaAPI()
    private var compatibilityPlan: MiniGameCompatibilityPlan {
        miniGameCompatibilityPlan(
            providerCompatible: provider.canMakeRequests,
            hasPreloadedCatalog: preloadedCatalog != nil
        )
    }

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
        if compatibilityPlan.rendersContent {
            compatibleBody
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var compatibleBody: some View {
        ZStack {
            #if os(iOS)
            AdOverlayWindowSceneReader(tracker: sceneReaderTracker) { hostingWindowScene = $0 }
                .frame(width: 0, height: 0)
            #endif

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
                    onServeIdReceived: { serveId in handleServeIdReceived(serveId) },
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

            // Ad loading screen (shown while fetching post-game ad)
            if adLoading {
                ZStack {
                    Color.black.opacity(lastGameWasBottomSheet ? 0.8 : 1.0).ignoresSafeArea()

                    GeometryReader { geo in
                        let sheetHeight = lastGameWasBottomSheet ? (lastGameHeightDp ?? geo.size.height) : geo.size.height
                        let isSheet = lastGameWasBottomSheet && sheetHeight < geo.size.height * 0.95

                        VStack(spacing: 0) {
                            if isSheet {
                                VStack(spacing: 0) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.3))
                                        .frame(width: 40, height: 4)
                                        .padding(.vertical, 12)
                                }
                                .frame(maxWidth: .infinity)
                                .background(Color(hex: theme.resolvedPlayableBorderColor))
                                .clipShape(TopRoundedRectangle(radius: 16))
                            }

                            ZStack {
                                VStack(spacing: 12) {
                                    Spacer()
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(1.2)
                                    Text("Loading...")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white)
                                    Spacer()
                                }
                                Button(action: { closeFallbackLoading() }) {
                                    Text("Close")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .frame(height: 36)
                                        .background(Color.white.opacity(0.16))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: sheetHeight)
                        .offset(y: isSheet ? geo.size.height - sheetHeight : 0)
                    }
                    .ignoresSafeArea()
                }
                .transition(.identity)
                .zIndex(2.5)
            }

            // Ad Overlay (full-screen cover) — shows the current fallback screen; `.id` gives
            // each revealed screen fresh overlay state (countdown, web view).
            if showAdOverlay,
               let fallbackAd = fallbackAds.indices.contains(fallbackAdIndex) ? fallbackAds[fallbackAdIndex] : nil,
               canRenderFallbackAd(fallbackAd) {
                let renderedIndex = fallbackAdIndex
                let videoRoute = fallbackAd.mediaType == .video
                    ? fallbackVideoCTARoute(ad: fallbackAd, allowsParentFallback: false)
                    : nil
                fallbackOverlay(
                    ad: fallbackAd,
                    renderedIndex: renderedIndex,
                    videoRoute: videoRoute
                )
                .id(fallbackAdIndex)
                .transition(.identity)
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
                    .onAppear {
                        // Warm a web view as soon as the menu opens so the game
                        // (and post-game ad) load from a warm process instead of
                        // paying cold-start right after the user taps.
                        if compatibilityPlan.prewarmsWebView {
                            #if os(iOS)
                            WebViewPool.shared.prewarm(trigger: "minigame_menu")
                            #endif
                        }
                    }

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
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        .task(id: isOpen) { await loadCatalogIfOpen() }
        .onAppear { handleRootAppear() }
        .onDisappear { handleRootDisappear() }
    }

    private func fallbackOverlay(
        ad: FallbackAd,
        renderedIndex: Int,
        videoRoute: FallbackVideoCTARoute?
    ) -> AdOverlayView {
        var overlay = AdOverlayView(
            ad: ad,
            onClose: { handleAdIframeClose(from: renderedIndex) },
            onCreativeFailure: { handleFallbackTerminalAdvance(from: renderedIndex) },
            onVideoCompleted: ad.usesVideoPlanV2
                ? { handleFallbackTerminalAdvance(from: renderedIndex) }
                : nil,
            onVideoStarted: ad.usesVideoPlanV2
                ? { prepareNextMiniGameFallbackVideo(after: renderedIndex) }
                : nil,
            videoPlayer: fallbackVideoPlayer,
            videoPlanScope: fallbackVideoPlanScope,
            expectsVideoPlanNextStep: renderedIndex + 1 < fallbackAds.count,
            playableHeightDp: lastGameWasBottomSheet ? lastGameHeightDp : nil,
            playableBorderColor: theme.resolvedPlayableBorderColor,
            adId: ad.adId,
            nativeClickBeaconV1Enabled: ad.nativeClickBeaconV1Enabled,
            closeBehavior: ad.closeBehavior,
            telemetryServeId: currentServeId,
            onClickHandoffPendingChanged: {
                updateFallbackClickHandoff($0, renderedIndex: renderedIndex)
            },
            onPresentationBlockedChanged: {
                updateFallbackPresentationBlocker($0, renderedIndex: renderedIndex)
            },
            ctaTrackingUrl: videoRoute?.trackingUrl,
            ctaDestination: videoRoute?.destination ?? .appstore,
            ctaStoreOpen: videoRoute?.storeOpen ?? .skstoreproduct,
            ctaStoreUrl: videoRoute?.storeUrl
        )
        #if os(iOS)
        overlay.initialOriginatingScene = hostingWindowScene
        #endif
        return overlay
    }

    /// Task body for the menu-open catalog load (named method — see the task-shape note in
    /// TelemetryManager).
    private func loadCatalogIfOpen() async {
        guard compatibilityPlan.rendersContent else { return }
        if isOpen { await loadCatalog() }
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
                        CachedAsyncImage(url: URL(string: charImage)) { phase in
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

                    BundledImage(asset: .gameIcon) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 56, height: 56)
                        } else {
                            Color.clear
                                .frame(width: 56, height: 56)
                        }
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
                BundledImage(asset: .gamesUnavailable) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 150, height: 150)
                            .clipShape(Circle())
                    case .empty:
                        Color.clear
                            .frame(width: 150, height: 150)
                    case .failure:
                        Circle()
                            .fill(Color(hex: theme.resolvedBackgroundColor).opacity(0.5))
                            .frame(width: 150, height: 150)
                            .overlay(
                                Text("🎮")
                                    .font(.system(size: 60))
                            )
                    }
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
        guard compatibilityPlan.loadsGame else { return }
        cancelFallbackFetch(clearLoading: true)
        if compatibilityPlan.tracksClick, let menuId = menuId {
            // Single-call task closure — see the task-shape note in TelemetryManager.
            Task { await api.trackMenuGameClick(menuId: menuId, gameName: gameName, apiKey: provider.apiKey) }
        }

        selectedGameId = gameId
        showGameIframe = true
        adFetched = false
        fallbackAds = []
        fallbackVideoPlanScope?.cancel()
        fallbackVideoPlanScope = nil
        fallbackAdIndex = 0
        resetFallbackAdvanceState()
        #if os(iOS)
        releaseAllFallbackVideos()
        #endif
        currentServeId = nil
    }

    private func handleServeIdReceived(_ serveId: String) {
        guard compatibilityPlan.loadsGame else { return }
        currentServeId = serveId
    }

    private func handleIframeClose() {
        guard compatibilityPlan.loadsGame else { return }
        guard !adLoading else { return }
        if compatibilityPlan.fetchesFallbacks, !adFetched, let serveId = currentServeId {
            // GameIframeView reports its final dimensions before this callback. Replace its active
            // WKWebView with the identity loading cover in the same update, without an opacity exit.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                adLoading = true
                showGameIframe = false
                selectedGameId = nil
            }
            // Single-call task closure — see the task-shape note in TelemetryManager.
            startFallbackFetch(serveId: serveId)
        } else {
            showGameIframe = false
            selectedGameId = nil
        }
    }

    /// Task body for the post-iframe-close fallback fetch (named method — see the task-shape
    /// note in TelemetryManager). @MainActor so the @State writes stay on the main thread,
    /// exactly like the previous `MainActor.run` block.
    @MainActor
    private func loadFallbacksAfterIframeClose(
        request: MiniGameFallbackFetchRequest
    ) async {
        guard compatibilityPlan.fetchesFallbacks else {
            let resolution = fallbackFetchOwnership.resolve(
                request,
                taskCancelled: Task.isCancelled,
                currentServeId: currentServeId,
                currentMenuId: menuId
            )
            guard resolution != .stale else { return }
            fallbackFetchTask = nil
            adLoading = false
            return
        }
        let ads: [FallbackAd]
        do { ads = try await api.fetchFallbacks(impressionId: request.serveId) } catch { ads = [] }
        let resolution = fallbackFetchOwnership.resolve(
            request,
            taskCancelled: Task.isCancelled,
            currentServeId: currentServeId,
            currentMenuId: menuId
        )
        guard resolution != .stale else {
            return
        }
        guard resolution == .apply, compatibilityPlan.fetchesFallbacks, !ads.isEmpty else {
            fallbackFetchTask = nil
            adLoading = false
            return
        }
        fallbackAds = ads
        fallbackVideoPlanScope?.cancel()
        fallbackVideoPlanScope = ads.contains(where: \.usesVideoPlanV2Contract)
            ? VideoPlanPresentationScope()
            : nil
        fallbackAdIndex = 0
        resetFallbackAdvanceState()
        adFetched = true

        fallbackFetchTask = nil
        showAdOverlay = true
        if ads[0].mediaType == .video {
            adLoading = true
            prepareCurrentFallbackVideo()
        } else {
            adLoading = false
            prepareNextMiniGameFallbackVideo(after: 0)
        }
    }

    private func startFallbackFetch(serveId: String) {
        fallbackFetchTask?.cancel()
        let request = fallbackFetchOwnership.begin(serveId: serveId, menuId: menuId)
        fallbackFetchTask = Task { await loadFallbacksAfterIframeClose(request: request) }
    }

    private func cancelFallbackFetch(clearLoading: Bool) {
        fallbackFetchTask?.cancel()
        fallbackFetchTask = nil
        fallbackFetchOwnership.cancel()
        if clearLoading { adLoading = false }
    }

    private func closeFallbackLoading() {
        cancelFallbackFetch(clearLoading: true)
        #if os(iOS)
        releaseAllFallbackVideos()
        #endif
        showAdOverlay = false
        fallbackAds = []
        fallbackAdIndex = 0
        adFetched = true
    }

    private func handleRootDisappear() {
        cancelFallbackFetch(clearLoading: true)
        let selectedAd = fallbackAds.indices.contains(fallbackAdIndex)
            ? fallbackAds[fallbackAdIndex]
            : nil
        let action = miniGameFallbackVideoLifecycleAction(
            event: .disappear,
            showAdOverlay: showAdOverlay,
            hasSelectedAd: selectedAd != nil,
            selectedAdIsVideo: selectedAd?.mediaType == .video,
            ownsCurrentPlayer: ownsCurrentFallbackVideoPlayer
        )
        if action == .release { releaseAllFallbackVideos() }
        fallbackVideoPlanScope?.cancel()
        fallbackVideoPlanScope = nil
    }

    private func handleAdIframeClose(from renderedIndex: Int) {
        guard showAdOverlay, renderedIndex == fallbackAdIndex else { return }
        // Reveal the next fetched ad screen on each close tap; close after the last one.
        #if os(iOS)
        releaseFallbackVideo(at: fallbackAdIndex)
        #endif
        resetFallbackAdvanceState()
        if fallbackAdIndex + 1 < fallbackAds.count {
            fallbackAdIndex += 1
            #if os(iOS)
            if fallbackAds[fallbackAdIndex].mediaType == .video,
               fallbackVideoTokens[fallbackAdIndex] == nil {
                adLoading = true
            }
            #endif
            prepareCurrentFallbackVideo()
        } else {
            showAdOverlay = false
            fallbackAds = []
            fallbackAdIndex = 0
            fallbackVideoPlanScope?.cancel()
            fallbackVideoPlanScope = nil
        }
    }

    private func handleFallbackTerminalAdvance(from renderedIndex: Int) {
        guard showAdOverlay, renderedIndex == fallbackAdIndex else { return }
        guard fallbackTerminalAdvanceState.request(
            index: renderedIndex,
            blocked: fallbackClickHandoffPending || fallbackPresentationBlocked
        ) else { return }
        handleAdIframeClose(from: renderedIndex)
    }

    private func updateFallbackClickHandoff(_ pending: Bool, renderedIndex: Int) {
        guard showAdOverlay, renderedIndex == fallbackAdIndex else { return }
        fallbackClickHandoffPending = pending
        completeDeferredFallbackAdvanceIfPossible(renderedIndex: renderedIndex)
    }

    private func updateFallbackPresentationBlocker(_ blocked: Bool, renderedIndex: Int) {
        guard showAdOverlay, renderedIndex == fallbackAdIndex else { return }
        fallbackPresentationBlocked = blocked
        completeDeferredFallbackAdvanceIfPossible(renderedIndex: renderedIndex)
    }

    private func completeDeferredFallbackAdvanceIfPossible(renderedIndex: Int) {
        guard !fallbackClickHandoffPending, !fallbackPresentationBlocked,
              let pendingIndex = fallbackTerminalAdvanceState.blockersDidClear(
                  currentIndex: renderedIndex
              ) else { return }
        handleAdIframeClose(from: pendingIndex)
    }

    private func resetFallbackAdvanceState() {
        fallbackTerminalAdvanceState.clear()
        fallbackClickHandoffPending = false
        fallbackPresentationBlocked = false
    }

    private func canRenderFallbackAd(_ ad: FallbackAd) -> Bool {
        if fallbackAds.contains(where: \.usesVideoPlanV2Contract), fallbackVideoPlanScope == nil {
            return false
        }
        #if os(iOS)
        guard ad.mediaType == .video else { return true }
        let ownsPlayer = miniGameFallbackVideoLifecycleAction(
            event: .appear,
            showAdOverlay: showAdOverlay,
            hasSelectedAd: true,
            selectedAdIsVideo: true,
            ownsCurrentPlayer: ownsCurrentFallbackVideoPlayer
        ) == .none
        return fallbackVideoReadiness(isVideo: true, hasPreparedPlayer: ownsPlayer) == .mount
        #else
        return true
        #endif
    }

    private var ownsCurrentFallbackVideoPlayer: Bool {
        #if os(iOS)
        retainedFallbackVideoResource(
            requestedIndex: fallbackAdIndex,
            ownershipIndex: fallbackVideoOwnershipIndex,
            resource: fallbackVideoOwnership?.resource
        ) != nil && fallbackVideoPlayer != nil
        #else
        false
        #endif
    }

    private func handleRootAppear() {
        let selectedAd = fallbackAds.indices.contains(fallbackAdIndex)
            ? fallbackAds[fallbackAdIndex]
            : nil
        let scopeRecovery = miniGameFallbackV2ScopeRecovery(
            showAdOverlay: showAdOverlay,
            containsVideoPlanV2: fallbackAds.contains(where: \.usesVideoPlanV2Contract),
            hasScope: fallbackVideoPlanScope != nil,
            currentAdUsesVideoPlanV2: selectedAd?.usesVideoPlanV2 == true,
            ownsCurrentPlayer: ownsCurrentFallbackVideoPlayer
        )
        if scopeRecovery.createScope {
            fallbackVideoPlanScope = VideoPlanPresentationScope()
        }
        #if os(iOS)
        if scopeRecovery.reattachCurrentPlayer,
           let scope = fallbackVideoPlanScope,
           let player = retainedFallbackVideoResource(
               requestedIndex: fallbackAdIndex,
               ownershipIndex: fallbackVideoOwnershipIndex,
               resource: fallbackVideoOwnership?.resource
           ) {
            fallbackVideoPlayer = player
            reattachMiniGameFallbackV2Player(player, to: scope)
        }
        #endif
        let action = miniGameFallbackVideoLifecycleAction(
            event: .appear,
            showAdOverlay: showAdOverlay,
            hasSelectedAd: selectedAd != nil,
            selectedAdIsVideo: selectedAd?.mediaType == .video,
            ownsCurrentPlayer: ownsCurrentFallbackVideoPlayer
        )
        if action == .reconcile { prepareCurrentFallbackVideo() }
    }

    private func prepareCurrentFallbackVideo() {
        #if os(iOS)
        if fallbackVideoOwnershipIndex == fallbackAdIndex,
           let player = fallbackVideoOwnership?.resource {
            fallbackVideoPlayer = player
            fallbackVideoPreparationDeadlineTask?.cancel()
            fallbackVideoPreparationDeadlineTask = nil
            adLoading = false
            return
        }
        prepareFallbackVideos(around: fallbackAdIndex)
        guard fallbackAds.indices.contains(fallbackAdIndex),
              case .video(_, let posterURL) = fallbackAds[fallbackAdIndex].creativeContent else {
            releaseFallbackVideoOwnership()
            fallbackVideoPlayer = nil
            adLoading = false
            return
        }
        guard let token = fallbackVideoTokens.removeValue(forKey: fallbackAdIndex) else {
            releaseFallbackVideoOwnership()
            fallbackVideoPlayer = nil
            adLoading = true
            scheduleFallbackVideoPreparation(at: fallbackAdIndex)
            armFallbackVideoPreparationDeadline(at: fallbackAdIndex)
            return
        }
        guard let localURL = FullscreenVideoPreparationPool.shared.localURL(for: token) else {
            FullscreenVideoPreparationPool.shared.release(token)
            releaseFallbackVideoOwnership()
            fallbackVideoPlayer = nil
            adLoading = true
            scheduleFallbackVideoPreparation(at: fallbackAdIndex)
            armFallbackVideoPreparationDeadline(at: fallbackAdIndex)
            return
        }
        releaseFallbackVideoOwnership()
        let ownership = makeFallbackVideoOwnership(
            url: localURL,
            posterURL: posterURL,
            token: token,
            startsMuted: !fallbackAds[fallbackAdIndex].usesVideoPlanV2,
            stallTimeout: fallbackAds[fallbackAdIndex].usesVideoPlanV2
                ? FullscreenVideoPlayer.videoPlanV2StallTimeout
                : FullscreenVideoPlayer.preparationTimeout
        )
        fallbackVideoOwnershipIndex = fallbackAdIndex
        fallbackVideoOwnership = ownership
        fallbackVideoPlayer = ownership.resource
        if fallbackAds[fallbackAdIndex].usesVideoPlanV2 {
            fallbackVideoPlayer?.setMuted(fallbackVideoPlanScope?.isMuted ?? false)
            fallbackVideoPlayer?.attachVideoPlanScope(fallbackVideoPlanScope)
        }
        fallbackVideoPreparationDeadlineTask?.cancel()
        fallbackVideoPreparationDeadlineTask = nil
        adLoading = false
        #endif
    }

    private func releaseFallbackVideo(at index: Int) {
        #if os(iOS)
        fallbackVideoPreparationGenerations.removeValue(forKey: index)
        fallbackVideoPreparationTasks.removeValue(forKey: index)?.cancel()
        if index == fallbackAdIndex {
            fallbackVideoPreparationDeadlineTask?.cancel()
            fallbackVideoPreparationDeadlineTask = nil
        }
        if fallbackVideoOwnershipIndex == index { releaseFallbackVideoOwnership() }
        FullscreenVideoPreparationPool.shared.release(fallbackVideoTokens.removeValue(forKey: index))
        fallbackVideoPlayer = nil
        #endif
    }

    private func releaseFallbackVideoOwnership() {
        #if os(iOS)
        fallbackVideoOwnership?.release()
        fallbackVideoOwnership = nil
        fallbackVideoOwnershipIndex = nil
        #endif
    }

    private func releaseAllFallbackVideos() {
        #if os(iOS)
        fallbackVideoPreparationTasks.values.forEach { $0.cancel() }
        fallbackVideoPreparationTasks.removeAll()
        fallbackVideoPreparationGenerations.removeAll()
        fallbackVideoPreparationDeadlineTask?.cancel()
        fallbackVideoPreparationDeadlineTask = nil
        releaseFallbackVideoOwnership()
        fallbackVideoTokens.values.forEach { FullscreenVideoPreparationPool.shared.release($0) }
        fallbackVideoTokens.removeAll()
        fallbackVideoPlayer = nil
        #endif
    }

    private func prepareFallbackVideos(around index: Int) {
        #if os(iOS)
        for candidate in fallbackVideoTokens.keys.filter({ $0 < index }) {
            FullscreenVideoPreparationPool.shared.release(fallbackVideoTokens.removeValue(forKey: candidate))
        }
        #endif
    }

    private func prepareNextMiniGameFallbackVideo(after currentIndex: Int) {
        #if os(iOS)
        scheduleFallbackVideoPreparation(at: currentIndex + 1)
        #endif
    }

    private func scheduleFallbackVideoPreparation(at candidate: Int) {
        #if os(iOS)
        guard fallbackAds.indices.contains(candidate), fallbackAds[candidate].mediaType == .video,
              fallbackVideoTokens[candidate] == nil,
              fallbackVideoOwnershipIndex != candidate,
              fallbackVideoPreparationTasks[candidate] == nil else { return }
        let ad = fallbackAds[candidate]
        let generation = UUID()
        fallbackVideoPreparationGenerations[candidate] = generation
        fallbackVideoPreparationTasks[candidate] = Task {
            await runFallbackVideoPreparation(at: candidate, ad: ad, generation: generation)
        }
        #endif
    }

    #if os(iOS)
    @MainActor
    private func runFallbackVideoPreparation(
        at candidate: Int,
        ad: FallbackAd,
        generation: UUID
    ) async {
        let token = await prepareFallbackVideo(ad)
        guard fallbackVideoPreparationGenerations[candidate] == generation else {
            FullscreenVideoPreparationPool.shared.release(token)
            return
        }
        fallbackVideoPreparationGenerations.removeValue(forKey: candidate)
        fallbackVideoPreparationTasks.removeValue(forKey: candidate)
        guard !Task.isCancelled,
              fallbackAds.indices.contains(candidate),
              fallbackAds[candidate].adId == ad.adId else {
            FullscreenVideoPreparationPool.shared.release(token)
            return
        }
        guard let token else {
            if fallbackAdIndex == candidate, showAdOverlay {
                adLoading = false
                handleFallbackTerminalAdvance(from: candidate)
            }
            return
        }
        fallbackVideoTokens[candidate] = token
        if fallbackAdIndex == candidate { prepareCurrentFallbackVideo() }
    }
    #endif

    private func armFallbackVideoPreparationDeadline(at candidate: Int) {
        #if os(iOS)
        guard let generation = fallbackVideoPreparationGenerations[candidate] else { return }
        fallbackVideoPreparationDeadlineTask?.cancel()
        fallbackVideoPreparationDeadlineTask = Task {
            await runFallbackVideoPreparationDeadline(at: candidate, generation: generation)
        }
        #endif
    }

    #if os(iOS)
    @MainActor
    private func runFallbackVideoPreparationDeadline(at candidate: Int, generation: UUID) async {
        do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
        guard !Task.isCancelled, showAdOverlay, fallbackAdIndex == candidate,
              fallbackVideoPreparationGenerations[candidate] == generation else { return }
        fallbackVideoPreparationGenerations.removeValue(forKey: candidate)
        fallbackVideoPreparationTasks.removeValue(forKey: candidate)?.cancel()
        fallbackVideoPreparationDeadlineTask = nil
        adLoading = false
        handleFallbackTerminalAdvance(from: candidate)
    }
    #endif

    private func loadCatalog() async {
        guard compatibilityPlan.rendersContent else { return }
        catalogLoading = true
        catalogError = false

        // When a preloaded catalog is supplied (imperative interstitial load()),
        // seed the grid from it and skip the network fetch.
        if compatibilityPlan.seedsPreloadedCatalog, let preloaded = preloadedCatalog {
            await MainActor.run {
                self.games = preloaded.games
                self.menuId = preloaded.menuId.isEmpty ? nil : preloaded.menuId
                self.catalogLoading = false
            }
            let coverUrls = preloaded.games.compactMap { game -> String? in
                let url = game.gifCover ?? game.iconUrl
                return url.isEmpty ? nil : url
            }
            await CoverImageCache.shared.preload(urls: coverUrls)
            return
        }

        guard compatibilityPlan.fetchesCatalog else { return }
        do {
            let sessionId = await provider.ensureSession()
            let response = try await api.fetchCatalog(sessionId: sessionId)

            // Show the grid immediately. Each card lazy-loads its own cover via
            // CachedCoverImage, so we no longer block the menu on downloading and
            // decoding every cover (GIFs included) up front.
            await MainActor.run {
                self.games = response.games
                self.menuId = response.menuId.isEmpty ? nil : response.menuId
                self.catalogLoading = false
            }

            // Warm the cover cache to smooth subsequent scrolling. The grid is
            // already visible, so this only runs after the fact. We await it
            // (rather than detaching) so it inherits this task's cancellation:
            // if the menu closes mid-load, the in-flight downloads are cancelled
            // instead of running to completion in the background.
            let coverUrls = response.games.compactMap { game -> String? in
                let url = game.gifCover ?? game.iconUrl
                return url.isEmpty ? nil : url
            }
            await CoverImageCache.shared.preload(urls: coverUrls)
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
