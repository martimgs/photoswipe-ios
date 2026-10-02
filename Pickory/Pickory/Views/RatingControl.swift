import SwiftUI

/// Five stars read as one control: filled = ink, empty = light gray.
/// Interactive when `onSelect` is set (tap a star = that exact rating);
/// VoiceOver adjusts it up and down as a single element.
struct RatingControl: View {
    enum Size { case regular, compact }

    let rating: Int
    var size: Size = .regular
    var onSelect: ((Int) -> Void)? = nil

    @ScaledMetric(relativeTo: .title3) private var regularStar: CGFloat = 23
    @ScaledMetric(relativeTo: .footnote) private var compactStar: CGFloat = 14

    private var star: CGFloat { size == .regular ? regularStar : compactStar }
    private var spacing: CGFloat { size == .regular ? star * 0.48 : star * 0.22 }

    var body: some View {
        let row = HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: "star.fill")
                    .font(.system(size: star, weight: .regular))
                    .foregroundStyle(i <= rating ? Theme.ink : Theme.inkTertiary.opacity(0.55))
            }
        }
        if let onSelect {
            row
                // One 44 pt tall hit area; the tap's x picks the star.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let step = star + spacing
                    let value = min(max(Int((location.x + spacing / 2) / step) + 1, 1), 5)
                    Haptics.tap()
                    onSelect(value)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rating")
                .accessibilityValue(RatingFilter.spoken(rating))
                .accessibilityAdjustableAction { direction in
                    let value = direction == .increment ? min(rating + 1, 5) : max(rating - 1, 0)
                    if value != rating { onSelect(value) }
                }
        } else {
            row
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
