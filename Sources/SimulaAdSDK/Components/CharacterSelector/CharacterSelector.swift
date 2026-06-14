import SwiftUI

/// The character grid maxes out at 4 cards (2×2).
let maxCharacters = 4

/// Builds the grid (≤ `maxCharacters` cards) from the host roster and the backend
/// backfill: host cards lead, the backend fills the gap, and any slot the backend
/// didn't fill keeps its default placeholder so the grid is never short. Pure/testable.
///
/// Backend items whose id already appears in the host roster are dropped (and the
/// backend list is kept distinct), so a character never shows up twice — a dropped
/// duplicate is topped up by a placeholder.
///
/// Used for both the instant seed (`fetched` empty → host + placeholders) and the
/// post-fetch swap (`fetched` non-empty → host + results + leftover placeholders).
func mergeRoster(
    host: [CharacterSelectorEntry],
    fetched: [CharacterSelectorEntry],
    fallback: [CharacterSelectorEntry]
) -> [CharacterSelectorEntry] {
    let capped = Array(host.prefix(maxCharacters))
    let fill = maxCharacters - capped.count
    var seen = Set(capped.map { $0.data.id })
    let deduped = fetched.filter { seen.insert($0.data.id).inserted }
    let filled = Array(deduped.prefix(fill))
    let padding = Array(fallback.prefix(fill).dropFirst(filled.count))
    return capped + filled + padding
}

// MARK: - CharacterSelectorEntry

/// A selector row item wrapping the public `CharacterData`. `loading` marks a skeleton slot
/// shown while the backend roster is in flight.
struct CharacterSelectorEntry: Identifiable, Equatable {
    let data: CharacterData
    var loading: Bool

    var id: String { data.id }

    init(data: CharacterData, loading: Bool = false) {
        self.data = data
        self.loading = loading
    }
}

// MARK: - CharacterSelector

/// Full-screen "Select Your Game Partner" character selector.
///
/// Renders a 2-column grid of selectable character cards over a black backdrop and a
/// "Launch Game" button that activates once a character is chosen. On confirm it fires
/// `onCharacterSelected` with the selected character — the selector does not launch a
/// game itself; the host wires the character into the minigame flow. `onCharacterPreview`
/// fires earlier, the moment a card is previewed (selected in the grid).
///
/// Characters come from the `/character-selector` endpoint, with a fallback to default
/// characters so the grid never shows a spinner or empty state. Pass `characters` to
/// supply them directly and skip the fetch.
///
/// Must be hosted within a `SimulaProviderView` — the fetch uses the provider's
/// apiKey + session.
///
/// Pixel-mapped from the reference HTML; presentation mirrors `MiniGameInterstitial`.
///
/// Usage:
/// ```swift
/// CharacterSelector(
///     isOpen: showSelector,
///     onClose: { showSelector = false },
///     onCharacterSelected: { character in showSelector = false; /* launch a game with `character` */ }
/// )
/// ```
public struct CharacterSelector: View {
    // MARK: Props

    var isOpen: Bool
    let onClose: () -> Void
    let onCharacterSelected: (CharacterData) -> Void
    let onCharacterPreview: ((CharacterData) -> Void)?
    var title: String
    var ctaText: String
    var characters: [CharacterData]?
    var theme: CharacterSelectorTheme

    public init(
        isOpen: Bool,
        onClose: @escaping () -> Void,
        onCharacterSelected: @escaping (CharacterData) -> Void,
        onCharacterPreview: ((CharacterData) -> Void)? = nil,
        title: String = "Select Your Game Partner",
        ctaText: String = "🚀 Launch Game",
        characters: [CharacterData]? = nil,
        theme: CharacterSelectorTheme = CharacterSelectorTheme()
    ) {
        self.isOpen = isOpen
        self.onClose = onClose
        self.onCharacterSelected = onCharacterSelected
        self.onCharacterPreview = onCharacterPreview
        self.title = title
        self.ctaText = ctaText
        self.characters = characters
        self.theme = theme
        // Seed instantly so the grid is never empty: host cards render for real, the gap
        // shows loading skeletons (swapped for backend results, or default characters if
        // the fetch comes back empty) — never the placeholder characters mid-load.
        let host = Array((characters ?? []).prefix(maxCharacters)).map { CharacterSelectorEntry(data: $0) }
        let fill = maxCharacters - host.count
        self._entries = State(initialValue: host + CharacterSelector.loadingEntries(fill))
    }

    // MARK: State

    @State private var closedInternally = false
    @State private var selectedId: String?
    @State private var entries: [CharacterSelectorEntry]
    @State private var appeared = false

    @EnvironmentObject private var provider: SimulaProvider
    private let api = SimulaAPI()

    private var isVisible: Bool { isOpen && !closedInternally }
    private var active: Bool { selectedId != nil }

    // MARK: Body

    public var body: some View {
        if isVisible {
            content
                .ignoresSafeArea()
                .hideStatusBar(true)
                .opacity(appeared ? 1 : 0)
                .animation(.easeIn(duration: 0.25), value: appeared)
                .onAppear { appeared = true }
                .onDisappear { appeared = false }
        }

        // Hidden reactor: reset + (re)load whenever the selector is (re)opened, mirroring
        // MiniGameInterstitial. The view stays in the hierarchy, so this catches reopen.
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { if isOpen { resetAndLoad() } }
            .onChange(of: isOpen) { open in
                if open { resetAndLoad() }
            }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            Color(hex: theme.resolvedBackgroundColor)
                .ignoresSafeArea()

            // `justify-content: space-around`: equal Spacers (edge = 1 unit, gap = 2 units).
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                titleView
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                gridView
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                launchButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 18)

            // Close button — the HTML page has none, but a modal needs an escape.
            VStack {
                HStack {
                    Spacer()
                    Button(action: handleClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Color(hex: theme.resolvedTitleFontColor))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
        }
    }

    /// Title size in points — mirrors the reference HTML (no longer themeable).
    private let titleFontSize: CGFloat = 26

    private var titleView: some View {
        Text(title)
            .font(fontForFamily(theme.resolvedFontFamily, size: titleFontSize, weight: .heavy))
            .foregroundColor(Color(hex: theme.resolvedTitleFontColor))
            .multilineTextAlignment(.center)
            .lineSpacing(titleFontSize * 0.2) // line-height ~1.2
            // (HTML's 0.01em letter-spacing ≈ 0.26pt is omitted; `.kerning` needs macOS 13.)
    }

    private var gridView: some View {
        // Two flexible columns give exact equal widths regardless of content — unlike an
        // HStack of `.frame(maxWidth: .infinity)` aspect-ratio cards, where the first card
        // grabs extra width (and so grows taller). A trailing odd card stays half-width,
        // left-aligned, matching the HTML's `repeat(2, minmax(0, 1fr))`.
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ],
            spacing: 16
        ) {
            ForEach(entries) { entry in
                card(for: entry)
            }
        }
    }

    @ViewBuilder
    private func card(for entry: CharacterSelectorEntry) -> some View {
        if entry.loading {
            CharacterSkeletonCard(theme: theme)
        } else {
            CharacterCard(
                entry: entry,
                selected: entry.data.id == selectedId,
                selectionMade: selectedId != nil,
                theme: theme,
                onTap: {
                    if selectedId != entry.data.id {
                        selectedId = entry.data.id
                        // Preview fires the moment a card is selected, before the CTA confirm.
                        onCharacterPreview?(entry.data)
                    }
                }
            )
        }
    }

    private var launchButton: some View {
        let accentColor = Color(hex: theme.resolvedAccentColor)
        // Inlined from the reference HTML (no longer themeable): disabled fill + corner radius.
        let disabledColor = Color(hex: "#3a3a3a")
        let cornerRadius: CGFloat = 14
        return Button(action: launch) {
            Text(ctaText)
                .font(fontForFamily(theme.resolvedFontFamily, size: 14, weight: .bold))
                .foregroundColor(active ? Color(hex: theme.resolvedCtaFontColor) : Color.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(active ? accentColor : disabledColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(active ? accentColor : Color(hex: "#4b4b4b"), lineWidth: 1)
                )
                // Green glow when active: box-shadow 0 0 18px rgba(61,154,102,0.32).
                .shadow(color: active ? accentColor.opacity(0.32) : .clear, radius: active ? 9 : 0)
        }
        .buttonStyle(LaunchButtonStyle(active: active))
        .disabled(!active)
        .animation(.easeInOut(duration: 0.25), value: active)
    }

    // MARK: Actions

    private func resetAndLoad() {
        closedInternally = false
        selectedId = nil
        let host = Array((characters ?? []).prefix(maxCharacters)).map { CharacterSelectorEntry(data: $0) }
        let fill = maxCharacters - host.count
        entries = host + CharacterSelector.loadingEntries(fill) // back to the loading state
        guard fill > 0 else { return }
        // Backfill the gap from /character-selector (needs the publisher apiKey + a
        // session). Resolve the loading state either way: real results when we got any,
        // else the default characters. `@MainActor` so the `entries` write lands on the
        // main thread after the off-main fetch.
        Task { @MainActor in
            let sessionId = await provider.ensureSession()
            var fetched: [CharacterSelectorEntry] = []
            if let sessionId, !sessionId.isEmpty {
                fetched = await api.fetchCharacters(apiKey: provider.apiKey, sessionId: sessionId, fill: fill)
                    .map { CharacterSelectorEntry(data: $0) }
            }
            entries = mergeRoster(host: host, fetched: fetched, fallback: CharacterSelector.fallbackEntries)
        }
    }

    private func launch() {
        guard let id = selectedId,
              let chosen = entries.first(where: { $0.data.id == id })?.data else { return }
        closedInternally = true
        onCharacterSelected(chosen)
    }

    private func handleClose() {
        closedInternally = true
        onClose()
    }
}

// MARK: - Fallback placeholders

extension CharacterSelector {
    /// Skeleton slots for the gap while the backend roster is fetched. Synthetic ids
    /// keep them distinct in the grid; they are never selectable.
    static func loadingEntries(_ count: Int) -> [CharacterSelectorEntry] {
        guard count > 0 else { return [] }
        return (0..<count).map {
            CharacterSelectorEntry(data: CharacterData(id: "loading-\($0)", name: "", imageUrl: "", description: ""), loading: true)
        }
    }

    /// Default characters shown when the `/character-selector` backend returns no roster.
    /// Their portraits load from hosted URLs (`imageUrl`) — no images ship in the SDK — and
    /// the selected default hands that URL back downstream via `onCharacterSelected`.
    static let fallbackEntries: [CharacterSelectorEntry] = [
        CharacterSelectorEntry(data: CharacterData(
            id: "mr_simula",
            name: "Mr. Simula",
            imageUrl: "https://storage.googleapis.com/simula-public/assets/imgs/Default%20Character%20Selector/MrSimula.webp",
            description: "\"Stand back, I've got this.\" Mr. Simula is the superhero dad who treats every crisis like a Tuesday and every dad-joke like a mission. Broad-shouldered, blue-suited, and impossibly calm, he's the guy who catches the falling bus AND remembers to pack your lunch. He leads with his chest out and his heart wide open, convinced that the strongest thing a hero can do is show up.\n\nTalk to him and you'll get equal parts pep talk, life advice, and slightly embarrassing 'back in my day' stories. He'll cheer you on like you're his own kid, challenge you to be braver than you think you are, and absolutely will not stop until you believe in yourself. Ready to train with the best dad in the multiverse?")),
        CharacterSelectorEntry(data: CharacterData(
            id: "simulady",
            name: "Simulady",
            imageUrl: "https://storage.googleapis.com/simula-public/assets/imgs/Default%20Character%20Selector/Simulady.webp",
            description: "\"Let's think this through — then we save everyone.\" Simulady is the superhero mom whose mind moves faster than her cape. Cool, clever, and three steps ahead of any villain, she solves the problem before most heroes have finished panicking. But don't mistake brilliance for coldness: behind that razor focus is someone who notices when you're hurting and refuses to let you face it alone.\n\nChat with her and she'll read you instantly, call out the excuse you didn't even know you were making, and then hand you a plan to actually fix it. Equal parts strategist and comfort, she's the voice in your corner that's gentle but never lets you settle. Come tell her what's on your mind — she's already listening.")),
        CharacterSelectorEntry(data: CharacterData(
            id: "simulad",
            name: "Simulad",
            imageUrl: "https://storage.googleapis.com/simula-public/assets/imgs/Default%20Character%20Selector/Simulad.webp",
            description: "\"Whoa, did I just do that?!\" Simulad is the superhero kid who's basically powers-first, plan-never. He's got energy for days, a head full of wild ideas, and abilities that keep surprising even him mid-fight. Is he ready for the big leagues? Absolutely not. Is he going to try anyway? Every single time — because backing down was never an option.\n\nTalk to him and you've got an instant hype-buddy: he'll geek out over your ideas, drag you into some half-baked adventure, and somehow make you braver just by being so fearlessly himself. He stumbles, he laughs it off, he gets back up. Wanna go cause some heroic chaos together?")),
        CharacterSelectorEntry(data: CharacterData(
            id: "simulabrador",
            name: "Simulabrador",
            imageUrl: "https://storage.googleapis.com/simula-public/assets/imgs/Default%20Character%20Selector/Simulabrador.webp",
            description: "*ears perk up* *tail going a hundred miles an hour* Simulabrador is the super-dog of the family and the most loyal hero you'll ever meet — four paws, a heart the size of a city, and a nose that smells trouble before it even happens. He can't talk like the others, but trust me, he says everything with a head tilt, a happy bark, and a body-slam hug at full superspeed.\n\nHang out with him and you'll get pure, unconditional good-boy energy: he senses when you're down, plops his head in your lap, and refuses to leave your side. Throw the ball, share the snack, go on the patrol — he's in, no questions asked. Ready to meet your new best friend and bodyguard?")),
    ]
}

// MARK: - LaunchButtonStyle

/// Press scale 0.99 when the button is active (matches the HTML `:active` transform).
private struct LaunchButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && active ? 0.99 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
