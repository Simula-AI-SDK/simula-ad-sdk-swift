import SwiftUI

// MARK: - CharacterCard

/// A single selectable character card — 1:1 cover image + name bar, with the reference
/// HTML's layered/pulsing glow, selection highlight, and grayscale of unselected cards
/// once a choice is made. Counterpart of `CharacterCard.kt`.
struct CharacterCard: View {
    let entry: CharacterSelectorEntry
    let selected: Bool
    let selectionMade: Bool
    let theme: CharacterSelectorTheme
    let onTap: () -> Void

    /// Idle pulse phase (0…1), animated forever on appear; ignored once a selection exists.
    @State private var pulsePhase: Double = 0

    // Idle glow colors from the HTML box-shadows.
    private let ringBluish = Color(red: 145 / 255, green: 165 / 255, blue: 185 / 255)
    private let glowBluish = Color(red: 130 / 255, green: 150 / 255, blue: 170 / 255)

    private var cornerRadius: CGFloat { theme.resolvedCardCornerRadius }
    private var accentColor: Color { Color(hex: theme.resolvedAccentColor) }
    private var borderColor: Color { Color(hex: theme.resolvedCardBorderColor) }
    private var grayscale: Bool { selectionMade && !selected }

    private var ringColor: Color {
        if selected { return accentColor.opacity(0.55) }
        if selectionMade { return ringBluish.opacity(0.24) }
        return ringBluish.opacity(0.22 + 0.16 * pulsePhase)
    }

    private var glowColor: Color {
        if selected { return accentColor.opacity(0.32) }
        if selectionMade { return glowBluish.opacity(0.16) }
        return glowBluish.opacity(0.14 + 0.12 * pulsePhase)
    }

    /// SwiftUI shadow radius ≈ CSS blur px / 2 (the convention used across this SDK).
    private var glowRadius: CGFloat {
        if selected { return 16 / 2 }
        if selectionMade { return 12 / 2 }
        return (10 + 8 * pulsePhase) / 2
    }

    var body: some View {
        VStack(spacing: 0) {
            imageWrap
            nameBar
        }
        .frame(maxWidth: .infinity)
        .background(Color(hex: theme.resolvedCardBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(selected ? accentColor : borderColor, lineWidth: 2)
        )
        // Whole-card grayscale of the non-selected cards (HTML: filter saturate(0)).
        .saturation(grayscale ? 0 : 1)
        // Colored blurred glow halo (the visible part of the spread/blur box-shadows).
        .shadow(color: glowColor, radius: glowRadius)
        // Thin 1pt ring ~4pt outside the edge (the visible 1px of the CSS 5px ring).
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius + 4)
                .stroke(ringColor, lineWidth: 1)
                .padding(-4)
        )
        .offset(y: selected ? -1 : 0) // translateY(-1px) on selection
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onTapGesture { onTap() }
        .animation(.easeInOut(duration: 0.35), value: selectionMade)
        .animation(.easeInOut(duration: 0.2), value: selected)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                pulsePhase = 1
            }
        }
        .accessibilityLabel(entry.data.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // Image wrap — a 1:1 square. `Color.clear` (no intrinsic size) is the size driver, so the
    // square is always width×width; the image lives in an `.overlay` and `scaledToFill`s into it.
    // (Putting the image directly in the sized layer let its intrinsic ratio leak into the
    // layout and make some cards taller.)
    private var imageWrap: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "#2a2a2f"), Color(hex: "#15151a")],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    CachedAsyncImage(url: URL(string: entry.data.imageUrl)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color.clear
                        }
                    }
                }
            }
            .clipped()
    }

    // Name bar — 1px top border, translucent black backing.
    private var nameBar: some View {
        Text(entry.data.name)
            .font(fontForFamily(theme.resolvedFontFamily, size: 14, weight: .bold))
            .foregroundColor(Color(hex: theme.resolvedSecondaryFontColor))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.4))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(borderColor),
                alignment: .top
            )
    }
}

// MARK: - CharacterSkeletonCard

/// Loading skeleton for a grid slot whose character is still being fetched — same
/// footprint as `CharacterCard` (1:1 image area + name bar) with a horizontal shimmer,
/// so swapping in the real card doesn't shift the layout. Not selectable.
struct CharacterSkeletonCard: View {
    let theme: CharacterSelectorTheme

    /// 0…1 sweep phase, animated forever on appear.
    @State private var phase: CGFloat = 0

    private var cornerRadius: CGFloat { theme.resolvedCardCornerRadius }
    private var borderColor: Color { Color(hex: theme.resolvedCardBorderColor) }

    var body: some View {
        VStack(spacing: 0) {
            // Image area — square, matching CharacterCard's imageWrap sizing.
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .overlay { shimmer }
                .clipped()

            // Name bar — short placeholder pill on the translucent backing.
            shimmer
                .frame(width: 60, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.4))
                .overlay(
                    Rectangle().frame(height: 1).foregroundColor(borderColor),
                    alignment: .top
                )
        }
        .frame(maxWidth: .infinity)
        .background(Color(hex: theme.resolvedCardBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderColor, lineWidth: 2)
        )
        .onAppear {
            phase = 0
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .accessibilityLabel("Loading")
    }

    // A base fill with a highlight band swept left→right by `phase`.
    private var shimmer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Color(hex: "#2a2a2f")
                .overlay(
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, Color(hex: "#3c3c46"), .clear]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w)
                    .offset(x: -w + phase * (2 * w))
                )
                .clipped()
        }
    }
}
