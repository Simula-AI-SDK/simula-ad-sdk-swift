import SwiftUI

// MARK: - Constants (matching Kotlin's GameGrid.kt)

private let MAX_VISIBLE_DOTS = 5
private let DOT_SIZE_CURRENT: CGFloat = 10
private let DOT_SIZE_ADJACENT: CGFloat = 8
private let DOT_SIZE_EDGE: CGFloat = 6
private let SWIPE_THRESHOLD: CGFloat = 50
private let DESKTOP_PAGE_SIZE = 4
private let CAROUSEL_GAP_DP: CGFloat = 12

// MARK: - GameGrid

/// Responsive game grid: mobile carousel (compact) or 4-column grid (regular).
/// Translates `GameGrid.kt` from the Kotlin SDK.
public struct GameGrid: View {
    let games: [GameData]
    let maxGamesToShow: Int
    let charID: String
    let theme: MiniGameTheme
    let onGameSelect: (String, String) -> Void
    let menuId: String?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

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

    public var body: some View {
        if games.isEmpty { EmptyView() }
        else if isCompact {
            MobileCarouselView(
                games: games,
                theme: theme,
                onGameSelect: onGameSelect
            )
        } else {
            DesktopGridView(
                games: games,
                theme: theme,
                onGameSelect: onGameSelect
            )
        }
    }
}

// MARK: - Velocity Tracker

/// Tracks drag velocity using a sliding window of recent samples.
/// Uses CACurrentMediaTime for monotonic precision (not Date).
private struct SimpleVelocityTracker {
    private var samples: [(time: TimeInterval, position: CGFloat)] = []
    private let maxAge: TimeInterval = 0.1

    mutating func addSample(position: CGFloat) {
        let now = CACurrentMediaTime()
        samples.append((now, position))
        samples.removeAll { now - $0.time > maxAge }
    }

    mutating func reset() { samples.removeAll() }

    func estimateVelocity() -> CGFloat {
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else { return 0 }
        let dt = last.time - first.time
        guard dt > 0.001 else { return 0 }
        return (last.position - first.position) / CGFloat(dt)
    }
}

// MARK: - Carousel Animator

/// Drives scroll position with an interruptible spring animation.
/// Equivalent to Kotlin's Animatable<Float> — animation can be stopped
/// at any time when a new drag starts, eliminating dead zones.
private final class CarouselAnimator: ObservableObject {
    @Published var scrollPosition: CGFloat = 0

    private var displayLink: AnyObject?
    private var animationTarget: CGFloat = 0
    private var animationVelocity: CGFloat = 0
    private var springActive = false
    private var lastTimestamp: CFTimeInterval = 0

    // Spring parameters matching Kotlin (dampingRatio 0.8, stiffness 200)
    private let stiffness: CGFloat = 200
    private let damping: CGFloat = 22.6 // 2 * 0.8 * sqrt(200)

    func stopAnimation() {
        springActive = false
        #if os(iOS)
        if let link = displayLink as? CADisplayLink {
            link.invalidate()
        }
        #endif
        displayLink = nil
    }

    func snapTo(_ value: CGFloat) {
        stopAnimation()
        scrollPosition = value
    }

    func animateTo(_ target: CGFloat, initialVelocity: CGFloat = 0) {
        stopAnimation()
        animationTarget = target
        animationVelocity = initialVelocity
        springActive = true
        lastTimestamp = 0

        #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #else
        // macOS fallback — MobileCarouselView is never shown on macOS
        // but code must compile. Use Timer as fallback.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            self?.tickMac()
            if self?.springActive != true { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayLink = timer
        #endif
    }

    #if os(iOS)
    @objc private func tick(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        if lastTimestamp == 0 { lastTimestamp = timestamp; return }
        let dt = CGFloat(timestamp - lastTimestamp)
        lastTimestamp = timestamp
        advanceSpring(dt: min(dt, 1.0 / 30.0))
    }
    #endif

    #if os(macOS)
    private func tickMac() {
        let now = CACurrentMediaTime()
        if lastTimestamp == 0 { lastTimestamp = now; return }
        let dt = CGFloat(now - lastTimestamp)
        lastTimestamp = now
        advanceSpring(dt: min(dt, 1.0 / 30.0))
    }
    #endif

    private func advanceSpring(dt: CGFloat) {
        guard springActive else { return }

        let displacement = scrollPosition - animationTarget
        let springForce = -stiffness * displacement - damping * animationVelocity
        animationVelocity += springForce * dt
        scrollPosition += animationVelocity * dt

        // Settle check
        if abs(displacement) < 0.001 && abs(animationVelocity) < 0.01 {
            scrollPosition = animationTarget
            stopAnimation()
        }
    }

    deinit { stopAnimation() }
}

// MARK: - Mobile Carousel
// Continuous scroll carousel with snap-to-nearest.
// Uses CarouselAnimator for interruptible spring animation (matching Kotlin's Animatable<Float>).
// View identity uses rawIndex (matching Kotlin's key(rawIndex)) to preserve card state across scrolls.

private struct MobileCarouselView: View {
    let games: [GameData]
    let theme: MiniGameTheme
    let onGameSelect: (String, String) -> Void

    @StateObject private var animator = CarouselAnimator()
    @State private var velocityTracker = SimpleVelocityTracker()
    @State private var lastDragValue: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            // Use full screen height for sizing (matching Kotlin's LocalConfiguration.current.screenHeightDp)
            #if os(iOS)
            let screenHeight = UIScreen.main.bounds.height
            #else
            let screenHeight = NSScreen.main?.frame.height ?? geometry.size.height
            #endif
            let carouselHeight = min(640, max(450, screenHeight * 0.62))
            let cardHeight = carouselHeight * 0.78
            let cardWidth = cardHeight * 9.0 / 16.0
            let cardStep = cardWidth + CAROUSEL_GAP_DP
            let n = games.count

            ZStack {
                if n > 0 {
                    let centerIndex = Int(animator.scrollPosition.rounded())
                    let visibleIndices = (-2...2).map { centerIndex + $0 }

                    ForEach(visibleIndices, id: \.self) { rawIndex in
                        let cardOffset = rawIndex - centerIndex
                        let gameIndex = ((rawIndex % n) + n) % n
                        let game = games[gameIndex]

                        let effectiveOffset = CGFloat(rawIndex) - animator.scrollPosition
                        let xTranslation = effectiveOffset * cardStep
                        let dist = min(abs(effectiveOffset), 2)
                        let scale = 1 - dist * 0.08

                        GameCard(
                            game: game,
                            theme: theme,
                            onGameSelect: { id in onGameSelect(id, game.name) }
                        )
                        .frame(width: cardWidth, height: cardHeight)
                        .scaleEffect(scale)
                        .offset(x: xTranslation)
                        .zIndex(Double(3 - abs(cardOffset)))
                    }
                }
            }
            .frame(width: geometry.size.width, height: carouselHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Center carousel within GeometryReader
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // KEY: stop any ongoing animation — gives immediate control to user
                        animator.stopAnimation()

                        let delta = (value.translation.width - lastDragValue) / cardStep
                        animator.snapTo(animator.scrollPosition - delta)

                        velocityTracker.addSample(position: value.translation.width)
                        lastDragValue = value.translation.width
                    }
                    .onEnded { _ in
                        lastDragValue = 0

                        // Velocity-based fling with snap
                        let velocityPx = velocityTracker.estimateVelocity()
                        let velocityCards = -velocityPx / cardStep
                        let decayFactor: CGFloat = 0.15
                        let projected = animator.scrollPosition + velocityCards * decayFactor
                        let snapTarget = projected.rounded()

                        animator.animateTo(snapTarget, initialVelocity: velocityCards)
                        velocityTracker.reset()
                    }
            )
        }
    }
}

// MARK: - Desktop Grid

private struct DesktopGridView: View {
    let games: [GameData]
    let theme: MiniGameTheme
    let onGameSelect: (String, String) -> Void

    @State private var currentPage = 0
    @State private var isAnimating = false
    @State private var slideOffset: CGFloat = 0
    @State private var totalDragX: CGFloat = 0

    private var totalPages: Int {
        max(1, Int(ceil(Double(games.count) / Double(DESKTOP_PAGE_SIZE))))
    }

    private func gamesForPage(_ page: Int) -> [GameData] {
        let start = page * DESKTOP_PAGE_SIZE
        let end = min(start + DESKTOP_PAGE_SIZE, games.count)
        guard start < games.count else { return [] }
        return Array(games[start..<end])
    }

    private var showPagination: Bool { totalPages > 1 }

    var body: some View {
        VStack(spacing: 8) {
            // Game grid with slide animation
            GeometryReader { geometry in
                HStack(spacing: 24) {
                    ForEach(gamesForPage(currentPage)) { game in
                        GameCard(
                            game: game,
                            theme: theme,
                            onGameSelect: { gameId in
                                onGameSelect(gameId, game.name)
                            }
                        )
                        .frame(maxWidth: .infinity)
                    }
                    // Fill remaining columns with empty spacers for alignment
                    let remaining = DESKTOP_PAGE_SIZE - gamesForPage(currentPage).count
                    if remaining > 0 {
                        ForEach(0..<remaining, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .offset(x: slideOffset * geometry.size.width)
                .opacity(Double(1 - abs(slideOffset) * 2))
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        totalDragX = value.translation.width
                    }
                    .onEnded { _ in
                        if abs(totalDragX) >= SWIPE_THRESHOLD && !isAnimating {
                            if totalDragX < 0 && currentPage < totalPages - 1 {
                                animateToPage(currentPage + 1)
                            } else if totalDragX > 0 && currentPage > 0 {
                                animateToPage(currentPage - 1)
                            }
                        }
                        totalDragX = 0
                    }
            )

            // Dot pagination
            if showPagination {
                HStack(spacing: 0) {
                    ForEach(calculateVisibleDots(currentPage: currentPage, totalPages: totalPages), id: \.pageIndex) { dot in
                        let size = getDotSize(pageIndex: dot.pageIndex, currentPage: currentPage)
                        let dotOpacity = getDotOpacity(pageIndex: dot.pageIndex, currentPage: currentPage)
                        let isCurrent = dot.pageIndex == currentPage

                        Button(action: {
                            if !isCurrent && !isAnimating {
                                animateToPage(dot.pageIndex)
                            }
                        }) {
                            Circle()
                                .fill(Color(hex: theme.resolvedAccentColor))
                                .opacity(dotOpacity)
                                .frame(width: size, height: size)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 3)
                    }
                }
                .frame(height: 24)
                .padding(.top, 4)
            }
        }
        .onChange(of: games.count) { _ in
            if currentPage >= totalPages && totalPages > 0 {
                currentPage = totalPages - 1
            }
        }
    }

    // Two-phase slide animation matching Kotlin:
    // Phase 1: slide out to ±0.3 (125ms)
    // Phase 2: snap page, slide in from ∓0.15 to 0 (125ms)
    private func animateToPage(_ newPage: Int) {
        guard !isAnimating else { return }
        isAnimating = true
        let direction: CGFloat = newPage > currentPage ? -1 : 1

        // Phase 1: slide out
        withAnimation(.easeOut(duration: 0.125)) {
            slideOffset = direction * 0.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.125) {
            // Snap page and prepare slide-in position
            currentPage = newPage
            slideOffset = -direction * 0.15

            // Phase 2: slide in
            withAnimation(.easeOut(duration: 0.125)) {
                slideOffset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.125) {
                isAnimating = false
            }
        }
    }
}

// MARK: - Dot Helpers

private struct DotInfo {
    let pageIndex: Int
}

private func calculateVisibleDots(currentPage: Int, totalPages: Int) -> [DotInfo] {
    if totalPages <= MAX_VISIBLE_DOTS {
        return (0..<totalPages).map { DotInfo(pageIndex: $0) }
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
        DotInfo(pageIndex: startPage + i)
    }
}

private func getDotSize(pageIndex: Int, currentPage: Int) -> CGFloat {
    let distance = abs(pageIndex - currentPage)
    if distance == 0 { return DOT_SIZE_CURRENT }
    if distance == 1 { return DOT_SIZE_ADJACENT }
    return DOT_SIZE_EDGE
}

private func getDotOpacity(pageIndex: Int, currentPage: Int) -> Double {
    let distance = abs(pageIndex - currentPage)
    if distance == 0 { return 1.0 }
    if distance == 1 { return 0.5 }
    return 0.3
}
