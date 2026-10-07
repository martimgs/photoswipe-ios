import SwiftUI

/// Five stars read as one control: filled = ink, empty = light gray.
/// Interactive when `onSelect` is set (tap a star = that exact rating,
/// tap the current star again = clear to 0);
/// VoiceOver adjusts it up and down as a single element.
struct RatingControl: View {
    /// `.header` sits in the navigation bar (landscape review), so it is
    /// capped to fit the compact bar at large Dynamic Type sizes.
    enum Size { case regular, header }

    let rating: Int
    var size: Size = .regular
    var onSelect: ((Int) -> Void)? = nil

    @ScaledMetric(relativeTo: .title3) private var regularStar: CGFloat = 23
    @ScaledMetric(relativeTo: .body) private var headerStar: CGFloat = 21

    private var star: CGFloat {
        switch size {
        case .regular: regularStar
        case .header: min(headerStar, 24)
        }
    }

    private var spacing: CGFloat {
        switch size {
        case .regular: star * 0.48
        case .header: star * 0.32
        }
    }

    private func starImage(_ i: Int) -> some View {
        Image(systemName: "star.fill")
            .font(.system(size: star, weight: .regular))
            .imageScale(.medium)   // toolbars default to .large
            .foregroundStyle(i <= rating ? Theme.ink : Theme.inkTertiary.opacity(0.55))
    }

    var body: some View {
        if let onSelect {
            // Each star owns its own hit area (half the gap on either side),
            // so a tap always lands on the star under the finger regardless
            // of the glyph's real width.
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { i in
                    starImage(i)
                        .padding(.horizontal, spacing / 2)
                        // One tall hit area (44 pt; 32 pt in the compact bar).
                        .frame(minHeight: size == .header ? 32 : 44)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.tap()
                            // Tapping the current rating clears it.
                            onSelect(i == rating ? 0 : i)
                        }
                }
            }
            .padding(.horizontal, -spacing / 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rating")
            .accessibilityValue(RatingFilter.spoken(rating))
            .accessibilityHint("Tap the current star again to clear the rating.")
            .accessibilityAdjustableAction { direction in
                let value = direction == .increment ? min(rating + 1, 5) : max(rating - 1, 0)
                if value != rating { onSelect(value) }
            }
        } else {
            HStack(spacing: spacing) {
                ForEach(1...5, id: \.self) { i in starImage(i) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RatingFilter.spoken(rating))
        }
    }
}

/// The minimum-rating filter options shared by swipe and grid.
enum RatingFilter {
    /// Minimum ratings 0–5. 0 means every photo that isn't rejected.
    static let options = Array(0...5)

    static func label(_ min: Int) -> String {
        switch min {
        case 0: return "0+ stars (all)"
        case 5: return "5 stars"
        default: return "\(min)+ stars"
        }
    }

    static func spoken(_ rating: Int) -> String {
        rating == 0 ? "Unrated" : "\(rating) star\(rating == 1 ? "" : "s")"
    }
}
