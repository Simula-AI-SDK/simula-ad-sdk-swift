import SwiftUI

/// The character grid maxes out at 4 cards (2×2).
let maxCharacters = 4

/// Builds the grid (≤ `maxCharacters` cards) from the host roster and the backend
/// backfill: host cards lead, the backend fills the gap, and any slot the backend
/// didn't fill keeps its bundled placeholder so the grid is never short. Pure/testable.
///
/// Backend items whose id already appears in the host roster are dropped (and the
/// backend list is kept distinct), so a character never shows up twice — a dropped
/// duplicate is topped up by a placeholder.
///
/// Used for both the instant seed (`fetched` empty → host + placeholders) and the
/// post-fetch swap (`fetched` non-empty → host + results + leftover placeholders).
func mergeRoster(
    host: [CharacterPickerEntry],
    fetched: [CharacterPickerEntry],
    fallback: [CharacterPickerEntry]
) -> [CharacterPickerEntry] {
    let capped = Array(host.prefix(maxCharacters))
    let fill = maxCharacters - capped.count
    var seen = Set(capped.map { $0.data.id })
    let deduped = fetched.filter { seen.insert($0.data.id).inserted }
    let filled = Array(deduped.prefix(fill))
    let padding = Array(fallback.prefix(fill).dropFirst(filled.count))
    return capped + filled + padding
}

// MARK: - CharacterPickerEntry

/// A picker row item: the public `CharacterData` plus an optional bundled image name
/// used by the fallback placeholders (so they render with no network). `loading` marks
/// a skeleton slot shown while the backend roster is in flight.
struct CharacterPickerEntry: Identifiable, Equatable {
    let data: CharacterData
    var bundledImageName: String?
    var loading: Bool

    var id: String { data.id }

    init(data: CharacterData, bundledImageName: String? = nil, loading: Bool = false) {
        self.data = data
        self.bundledImageName = bundledImageName
        self.loading = loading
    }
}

// MARK: - CharacterPicker

/// Full-screen "Select Your Game Partner" character picker.
///
/// Renders a 2-column grid of selectable character cards over a black backdrop and a
/// "Launch Game" button that activates once a character is chosen. On launch it fires
/// `onLaunch` with the selected character — the picker does not launch a game itself;
/// the host wires the character into the minigame flow.
///
/// Characters come from the `/character-selector` endpoint, with an instant fallback
/// to bundled placeholders so the grid never shows a spinner or empty state. Pass
/// `characters` to supply them directly and skip the fetch.
///
/// Must be hosted within a `SimulaProviderView` — the fetch uses the provider's
/// apiKey + session.
///
/// Pixel-mapped from the reference HTML; presentation mirrors `MiniGameInterstitial`.
///
/// Usage:
/// ```swift
/// CharacterPicker(
///     isOpen: showPicker,
///     onClose: { showPicker = false },
///     onLaunch: { character in showPicker = false; /* launch a game with `character` */ }
/// )
/// ```
public struct CharacterPicker: View {
    // MARK: Props

    var isOpen: Bool
    let onClose: () -> Void
    let onLaunch: (CharacterData) -> Void
    var title: String
    var launchText: String
    var characters: [CharacterData]?
    var theme: CharacterPickerTheme

    public init(
        isOpen: Bool,
        onClose: @escaping () -> Void,
        onLaunch: @escaping (CharacterData) -> Void,
        title: String = "Select Your Game Partner",
        launchText: String = "🚀 Launch Game",
        characters: [CharacterData]? = nil,
        theme: CharacterPickerTheme = CharacterPickerTheme()
    ) {
        self.isOpen = isOpen
        self.onClose = onClose
        self.onLaunch = onLaunch
        self.title = title
        self.launchText = launchText
        self.characters = characters
        self.theme = theme
        // Seed instantly so the grid is never empty: host cards render for real, the gap
        // shows loading skeletons (swapped for backend results, or bundled placeholders if
        // the fetch comes back empty) — never the placeholder characters mid-load.
        let host = Array((characters ?? []).prefix(maxCharacters)).map { CharacterPickerEntry(data: $0) }
        let fill = maxCharacters - host.count
        self._entries = State(initialValue: host + CharacterPicker.loadingEntries(fill))
    }

    // MARK: State

    @State private var closedInternally = false
    @State private var selectedId: String?
    @State private var entries: [CharacterPickerEntry]
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

        // Hidden reactor: reset + (re)load whenever the picker is (re)opened, mirroring
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
                            .foregroundColor(Color(hex: theme.resolvedTitleColor))
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

    private var titleView: some View {
        Text(title)
            .font(fontForFamily(theme.resolvedFontFamily, size: theme.resolvedTitleFontSize, weight: .heavy))
            .foregroundColor(Color(hex: theme.resolvedTitleColor))
            .multilineTextAlignment(.center)
            .lineSpacing(theme.resolvedTitleFontSize * 0.2) // line-height ~1.2
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
    private func card(for entry: CharacterPickerEntry) -> some View {
        if entry.loading {
            CharacterSkeletonCard(theme: theme)
        } else {
            CharacterCard(
                entry: entry,
                selected: entry.data.id == selectedId,
                selectionMade: selectedId != nil,
                theme: theme,
                onTap: { if selectedId != entry.data.id { selectedId = entry.data.id } }
            )
        }
    }

    private var launchButton: some View {
        let selectedColor = Color(hex: theme.resolvedSelectedColor)
        return Button(action: launch) {
            Text(launchText)
                .font(fontForFamily(theme.resolvedFontFamily, size: 14, weight: .bold))
                .foregroundColor(active ? Color(hex: theme.resolvedLaunchTextColor) : Color.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: theme.resolvedLaunchCornerRadius)
                        .fill(active ? selectedColor : Color(hex: theme.resolvedLaunchDisabledColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.resolvedLaunchCornerRadius)
                        .stroke(active ? selectedColor : Color(hex: "#4b4b4b"), lineWidth: 1)
                )
                // Green glow when active: box-shadow 0 0 18px rgba(61,154,102,0.32).
                .shadow(color: active ? selectedColor.opacity(0.32) : .clear, radius: active ? 9 : 0)
        }
        .buttonStyle(LaunchButtonStyle(active: active))
        .disabled(!active)
        .animation(.easeInOut(duration: 0.25), value: active)
    }

    // MARK: Actions

    private func resetAndLoad() {
        closedInternally = false
        selectedId = nil
        let host = Array((characters ?? []).prefix(maxCharacters)).map { CharacterPickerEntry(data: $0) }
        let fill = maxCharacters - host.count
        entries = host + CharacterPicker.loadingEntries(fill) // back to the loading state
        guard fill > 0 else { return }
        // Backfill the gap from /character-selector (needs the publisher apiKey + a
        // session). Resolve the loading state either way: real results when we got any,
        // else bundled placeholders. `@MainActor` so the `entries` write lands on the
        // main thread after the off-main fetch.
        Task { @MainActor in
            let sessionId = await provider.ensureSession()
            var fetched: [CharacterPickerEntry] = []
            if let sessionId, !sessionId.isEmpty {
                fetched = await api.fetchCharacters(apiKey: provider.apiKey, sessionId: sessionId, fill: fill)
                    .map { CharacterPickerEntry(data: $0) }
            }
            entries = mergeRoster(host: host, fetched: fetched, fallback: CharacterPicker.fallbackEntries)
        }
    }

    private func launch() {
        guard let id = selectedId,
              let chosen = entries.first(where: { $0.data.id == id })?.data else { return }
        closedInternally = true
        onLaunch(chosen)
    }

    private func handleClose() {
        closedInternally = true
        onClose()
    }
}

// MARK: - Fallback placeholders

extension CharacterPicker {
    /// Skeleton slots for the gap while the backend roster is fetched. Synthetic ids
    /// keep them distinct in the grid; they are never selectable.
    static func loadingEntries(_ count: Int) -> [CharacterPickerEntry] {
        guard count > 0 else { return [] }
        return (0..<count).map {
            CharacterPickerEntry(data: CharacterData(id: "loading-\($0)", name: "", image: ""), loading: true)
        }
    }

    /// Bundled placeholder characters shown when the backend returns no roster.
    /// Images ship in `Resources/` (registered in `Package.swift`).
    static let fallbackEntries: [CharacterPickerEntry] = [
        CharacterPickerEntry(data: CharacterData(id: "superman", name: "Superman", image: ""), bundledImageName: "char_superman"),
        CharacterPickerEntry(data: CharacterData(id: "hammy", name: "Hammy", image: ""), bundledImageName: "char_hammy"),
        CharacterPickerEntry(data: CharacterData(id: "maya", name: "Maya", image: ""), bundledImageName: "char_maya"),
        CharacterPickerEntry(data: CharacterData(id: "charles", name: "Charles", image: ""), bundledImageName: "char_charles"),
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
