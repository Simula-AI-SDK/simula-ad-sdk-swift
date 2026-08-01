import SwiftUI

// MARK: - GameIframeView

/// Full-screen overlay that loads and displays a game in a WKWebView.
/// Translates `GameIframe.tsx` from the React SDK.
///
/// Features:
/// - Calls `getMinigame()` API to get iframe URL using the session from SimulaProvider
/// - Loading spinner and error states
/// - Close button (top-right)
/// - Bottom sheet mode when `playableHeight` is set (with draggable handle)
/// - Dragging above 95% of screen snaps to full screen and hides status bar
/// - Fade-in overlay animation
/// - PostMessage communication from game iframe (onServeIdReceived)
public struct GameIframeView: View {
    // MARK: - Props (matching React's GameIframeProps)

    let gameId: String
    let charID: String
    let charName: String
    let charImage: String
    var messages: [Message] = []
    var delegateChar: Bool = true
    let onClose: () -> Void
    /// The minigame serve id — the menu fetches the post-game ad screens with it
    /// (`GET /load/fallbacks/{serveId}`).
    var onServeIdReceived: ((String) -> Void)?
    var charDesc: String?
    var menuId: String?
    /// Controls the height of the game iframe (nil = fullscreen). Minimum 500px.
    var playableHeight: PlayableHeight?
    /// Background color for the bottom sheet border area. Default: '#262626'
    var playableBorderColor: String = "#262626"
    /// Reports final height (in points) and whether still in bottom-sheet mode on close.
    /// Matches Kotlin's `onDimensionsOnClose`.
    var onDimensionsOnClose: ((CGFloat, Bool) -> Void)?

    // MARK: - State

    @EnvironmentObject private var provider: SimulaProvider
    @State private var iframeUrl: String?
    @State private var loading = true
    @State private var error: String?
    @State private var appeared = false
    /// Current animated height for bottom sheet mode (in points)
    @State private var currentHeight: CGFloat = 0
    /// Height captured at drag start, used to compute live height from translation
    @State private var dragStartHeight: CGFloat = 0

    // Computed, not stored (see MiniGameMenu for the full note): an eager `SimulaAPI()` at
    // struct init builds the one-time `defaultSession` static on the main thread during body
    // evaluation right after initialize — before the deferred startup's off-main prewarm.
    // The only use (getMinigame) is an async load that runs after ensureSession(), which
    // awaits that prewarm, so the static is already built by first use.
    private var api: SimulaAPI { .shared }

    // MARK: - Computed

    private var isBottomSheetMode: Bool {
        guard let ph = playableHeight else { return false }
        // Match React Native: >= 95% treated as full screen (no bottom sheet UI)
        switch ph {
        case .pixels(let px):
            return max(px, 500) < screenHeight * 0.95
        case .percent(let pct):
            return pct < 0.95
        }
    }

    private var screenHeight: CGFloat {
        #if os(iOS)
        simulaScreenSize().height
        #else
        768
        #endif
    }

    /// Calculate the initial height from the PlayableHeight enum
    private func calculateInitialHeight() -> CGFloat {
        guard let ph = playableHeight else { return screenHeight }
        switch ph {
        case .pixels(let px):
            return max(px, 500)
        case .percent(let pct):
            return max(screenHeight * CGFloat(pct), 500)
        }
    }

    /// Whether the sheet covers >= 95% of the screen (triggers status bar hide + snap).
    private var isNearFullScreen: Bool {
        currentHeight >= screenHeight * 0.95
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Backdrop (matching React's backgroundColor: 'rgba(0, 0, 0, 0.8)')
            Color.black.opacity(0.8)
                .ignoresSafeArea()

            // Sheet container (matching React Native's Animated.View with height: animatedHeight)
            // Uses GeometryReader for bottom-aligned positioning.
            // Frame height stays at currentHeight (stable during drag) — only .offset(y: dragOffset)
            // moves the sheet visually, avoiding the feedback loop where layout changes shift
            // the gesture reference point.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    // Drag handle header
                    if isBottomSheetMode {
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 40, height: 4)
                                .padding(.vertical, 12)
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color(hex: playableBorderColor))
                        .clipShape(TopRoundedRectangle(radius: 16))
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .onChanged { value in
                                    if dragStartHeight == 0 {
                                        dragStartHeight = currentHeight
                                    }
                                    let newHeight = dragStartHeight - value.translation.height
                                    currentHeight = min(max(newHeight, 500), screenHeight)
                                }
                                .onEnded { _ in
                                    dragStartHeight = 0
                                    if currentHeight >= screenHeight * 0.95 {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            currentHeight = screenHeight
                                        }
                                    }
                                }
                        )
                    }

                    // Main content area (flex: 1 — fills remaining space in sheet)
                    ZStack {
                        if loading {
                            VStack(spacing: 12) {
                                Spacer()
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.2)
                                Text("Loading game...")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.white)
                                Spacer()
                            }
                        } else if let error = error {
                            VStack {
                                Spacer()
                                Text(error)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(20)
                                Spacer()
                            }
                        } else if let urlString = iframeUrl, let url = URL(string: urlString) {
                            WebViewRepresentable(
                                url: url,
                                onNavigationFailed: { _ in
                                    self.error = "Failed to load game. Please try again."
                                },
                                onMessageReceived: { _ in }
                            )
                        }

                        // Close button — top right of content area
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: {
                                    handleClose()
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 16, height: 16)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.5))
                                        )
                                        // Visible glyph stays compact (16); the hit area is a full
                                        // 44pt touch target so the small button is easy to tap.
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(CloseButtonStyle())
                                .padding(.top, 8)
                                .padding(.trailing, 8)
                                .accessibilityLabel("Close game")
                            }
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    // Full-screen games inset the game + close button below the top safe area
                    // (status bar / notch / Dynamic Island). Bottom-sheet mode is anchored within its
                    // own sheet bounds, so it isn't padded here.
                    .padding(.top, isBottomSheetMode ? 0 : simulaTopSafeAreaInset())
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                .frame(height: isBottomSheetMode ? currentHeight : geo.size.height)
                // Offset pins sheet to bottom of screen
                .offset(y: isBottomSheetMode ? geo.size.height - currentHeight : 0)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .hideStatusBar(isBottomSheetMode ? isNearFullScreen : true)
        .opacity(appeared ? 1 : 0)
        .animation(.easeIn(duration: 0.2), value: appeared)
        .onAppear {
            // Backstop prewarm: warms a web view in parallel with the getMinigame
            // network round-trip in case the pool was drained.
            #if os(iOS)
            WebViewPool.shared.prewarm()
            #endif
        }
        // Single-call task closure into a named method — see the task-shape note in TelemetryManager.
        .task { await appear() }
    }

    /// `.task` body (named method — see the task-shape note in TelemetryManager): size the sheet,
    /// fade in, then fetch the minigame.
    @MainActor
    private func appear() async {
        currentHeight = calculateInitialHeight()
        appeared = true
        await loadMinigame()
    }

    // MARK: - Close Handler

    private func handleClose() {
        // Report dimensions on close (matching Kotlin's onDimensionsOnClose)
        if isBottomSheetMode {
            let isStillBottomSheet = currentHeight < screenHeight * 0.95
            onDimensionsOnClose?(currentHeight, isStillBottomSheet)
        }
        onClose()
    }

    // MARK: - Load Minigame

    /// Fetches the minigame iframe URL from the API.
    /// Translates the useEffect that calls `getMinigame()` in GameIframe.tsx.
    /// `@MainActor` so the `@State` writes after the `await` resume on the main
    /// thread (otherwise the URLSession continuation can land off-main).
    @MainActor
    private func loadMinigame() async {
        // Wait for the session to be ready (or retried) rather than failing the
        // instant it isn't — a fast tap during launch, or a transient launch
        // failure, no longer hard-fails the minigame.
        guard let sessionId = await provider.ensureSession(), !sessionId.isEmpty else {
            error = "Session invalid, cannot initialize minigame"
            loading = false
            return
        }

        #if os(iOS)
        let screenSize = simulaScreenSize()
        let screenWidth = screenSize.width
        let screenHeight = screenSize.height
        #else
        let screenWidth: CGFloat = 1024
        let screenHeight: CGFloat = 768
        #endif

        do {
            let request = InitMinigameRequest(
                gameType: gameId,
                sessionId: sessionId,
                currencyMode: false,
                w: screenWidth,
                h: screenHeight,
                charId: charID,
                charName: charName,
                charImage: charImage,
                charDesc: charDesc,
                messages: messages,
                delegateChar: delegateChar,
                menuId: menuId
            )

            let response = try await api.getMinigame(request)
            self.iframeUrl = response.iframeUrl

            // Callback with the serve id (the post-game fallbacks handle).
            if !response.serveId.isEmpty {
                onServeIdReceived?(response.serveId)
            }
            self.loading = false
        } catch {
            self.error = "Failed to load game. Please try again."
            self.loading = false
        }
    }

}

