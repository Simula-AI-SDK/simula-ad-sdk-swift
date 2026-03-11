import SwiftUI

// MARK: - Constants (matching React's GameGrid.tsx)

private let MAX_VISIBLE_DOTS = 5
private let DOT_SIZE_CURRENT: CGFloat = 8
private let DOT_SIZE_ADJACENT: CGFloat = 6
private let DOT_SIZE_EDGE: CGFloat = 4
private let SWIPE_THRESHOLD: CGFloat = 50
private let ANIMATION_DURATION: Double = 0.25

// MARK: - GameGrid

/// A paginated 3-column grid of game cards with dot pagination and swipe support.
/// Translates `GameGrid.tsx` from the React SDK.
///
/// Features:
/// - 3-column LazyVGrid with pages of `maxGamesToShow` games each
/// - Swipe gesture to navigate between pages (matching React's touch swipe)
/// - Dot pagination with size/opacity based on distance from current page
/// - Slide animations between pages
public struct GameGrid: View {
    let games: [GameData]
    let maxGamesToShow: Int // 3, 6, or 9
    let charID: String
    let theme: MiniGameTheme
    let onGameSelect: (String, String) -> Void // (gameId, gameName)
    let menuId: String?

    @State private var currentPage = 0
    @State private var isAnimating = false
    @State private var dragOffset: CGFloat = 0
    @State private var pageWidth: CGFloat = 0

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    private let columns = 3

    public init(
        games: [GameData],
        maxGamesToShow: Int = 6,
        charID: String,
        theme: MiniGameTheme,
        onGameSelect: @escaping (String, String) -> Void,
        menuId: String? = nil
    ) {
        self.games = games
        self.maxGamesToShow = maxGamesToShow
        self.charID = charID
        self.theme = theme
        self.onGameSelect = onGameSelect
        self.menuId = menuId
    }

    // MARK: - Computed Properties

    private var totalPages: Int {
        max(1, Int(ceil(Double(games.count) / Double(maxGamesToShow))))
    }

    private func gamesForPage(_ page: Int) -> [GameData] {
        let start = page * maxGamesToShow
        let end = min(start + maxGamesToShow, games.count)
        guard start < games.count else { return [] }
        return Array(games[start..<end])
    }

    private var showPagination: Bool { totalPages > 1 }
    private var accentColor: String { theme.resolvedAccentColor }

    // MARK: - Visible Dots (matching React's calculateVisibleDots)

    private var visibleDots: [DotInfo] {
        calculateVisibleDots(currentPage: currentPage, totalPages: totalPages)
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 8) {
            // Measure parent-offered width without constraining the layout
            Color.clear.frame(height: 0)
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { pageWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { newWidth in
                            pageWidth = newWidth
                        }
                })

            // Game Grid — HStack of all pages for smooth sliding
            HStack(spacing: 0) {
                ForEach(0..<totalPages, id: \.self) { pageIndex in
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: isCompact ? 8 : 12), count: columns),
                        spacing: isCompact ? 8 : 12
                    ) {
                        ForEach(gamesForPage(pageIndex)) { game in
                            GameCard(
                                game: game,
                                isCompact: isCompact,
                                theme: theme,
                                onGameSelect: { gameId in
                                    onGameSelect(gameId, game.name)
                                }
                            )
                        }
                    }
                    .frame(width: pageWidth)
                }
            }
            .offset(x: -CGFloat(currentPage) * pageWidth + dragOffset)
            .frame(width: pageWidth, alignment: .leading)
            .clipped()
            .gesture(
                totalPages > 1 ?
                DragGesture()
                    .onChanged { value in
                        if !isAnimating { dragOffset = value.translation.width }
                    }
                    .onEnded { value in
                        handleSwipeEnd(translation: value.translation)
                    }
                : nil
            )
            .animation(.easeOut(duration: ANIMATION_DURATION), value: currentPage)
            .animation(.easeOut(duration: ANIMATION_DURATION), value: dragOffset)

            // Dot Pagination (matching React's dot pagination exactly)
            if showPagination {
                HStack(spacing: 4) {
                    ForEach(visibleDots, id: \.pageIndex) { dot in
                        let size = getDotSize(pageIndex: dot.pageIndex, currentPage: currentPage)
                        let dotOpacity = getDotOpacity(pageIndex: dot.pageIndex, currentPage: currentPage)
                        let isCurrent = dot.pageIndex == currentPage

                        Button(action: { handleDotClick(pageIndex: dot.pageIndex) }) {
                            Circle()
                                .fill(Color(hex: accentColor))
                                .opacity(dotOpacity)
                                .frame(width: size, height: size)
                                .padding(4) // Matching React's padding: '4px'
                        }
                        .buttonStyle(.plain)
                        .disabled(isCurrent)
                        .accessibilityLabel("Page \(dot.pageIndex + 1) of \(totalPages)")
                    }
                }
                .frame(minHeight: 16)
                .padding(.top, 4)
            }
        }
        .onChange(of: games.count) { _ in
            // Reset to valid page if current page is out of bounds (matching React useEffect)
            if currentPage >= totalPages && totalPages > 0 {
                currentPage = totalPages - 1
            }
        }
    }

    // MARK: - Swipe Handling

    private func handleSwipeEnd(translation: CGSize) {
        guard !isAnimating else {
            dragOffset = 0
            return
        }

        let deltaX = translation.width
        let deltaY = translation.height

        // Only trigger swipe if horizontal movement is dominant and exceeds threshold
        // (matching React's SWIPE_THRESHOLD = 50 and deltaY check)
        guard abs(deltaX) >= SWIPE_THRESHOLD, abs(deltaY) <= abs(deltaX) else {
            withAnimation(.easeOut(duration: ANIMATION_DURATION)) {
                dragOffset = 0
            }
            return
        }

        if deltaX < 0, currentPage < totalPages - 1 {
            // Swiped left → next page
            animateToPage(currentPage + 1)
        } else if deltaX > 0, currentPage > 0 {
            // Swiped right → previous page
            animateToPage(currentPage - 1)
        } else {
            withAnimation(.easeOut(duration: ANIMATION_DURATION)) {
                dragOffset = 0
            }
        }
    }

    private func animateToPage(_ newPage: Int) {
        guard !isAnimating else { return }
        isAnimating = true
        withAnimation(.easeOut(duration: ANIMATION_DURATION)) {
            currentPage = newPage
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ANIMATION_DURATION) {
            isAnimating = false
        }
    }

    private func handleDotClick(pageIndex: Int) {
        guard pageIndex != currentPage, !isAnimating else { return }
        animateToPage(pageIndex)
    }
}

// MARK: - Helper Types

private struct DotInfo {
    let pageIndex: Int
    let isVisible: Bool
}

// MARK: - Dot Calculation Functions (matching React exactly)

/// Calculates which dots to show based on current page and total pages.
/// Translates `calculateVisibleDots` from GameGrid.tsx.
private func calculateVisibleDots(currentPage: Int, totalPages: Int) -> [DotInfo] {
    if totalPages <= MAX_VISIBLE_DOTS {
        return (0..<totalPages).map { DotInfo(pageIndex: $0, isVisible: true) }
    }

    let halfWindow = MAX_VISIBLE_DOTS / 2
    var startPage = currentPage - halfWindow
    var endPage = currentPage + halfWindow

    if startPage < 0 {
        startPage = 0
        endPage = MAX_VISIBLE_DOTS - 1
    }

    if endPage >= totalPages {
        endPage = totalPages - 1
        startPage = totalPages - MAX_VISIBLE_DOTS
    }

    return (0..<MAX_VISIBLE_DOTS).map { i in
        DotInfo(pageIndex: startPage + i, isVisible: true)
    }
}

/// Returns the dot size based on distance from current page.
/// Translates `getDotSize` from GameGrid.tsx.
private func getDotSize(pageIndex: Int, currentPage: Int) -> CGFloat {
    let distance = abs(pageIndex - currentPage)
    if distance == 0 { return DOT_SIZE_CURRENT }
    if distance == 1 { return DOT_SIZE_ADJACENT }
    return DOT_SIZE_EDGE
}

/// Returns the dot opacity based on distance from current page.
/// Translates `getDotOpacity` from GameGrid.tsx.
private func getDotOpacity(pageIndex: Int, currentPage: Int) -> Double {
    let distance = abs(pageIndex - currentPage)
    if distance == 0 { return 1.0 }
    if distance == 1 { return 0.5 }
    return 0.3
}
