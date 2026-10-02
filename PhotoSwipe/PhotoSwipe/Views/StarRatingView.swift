import SwiftUI

/// Five black stars. Interactive when `onSelect` is set (tap = exact rating).
struct StarRatingView: View {
    let rating: Int
    var size: CGFloat = 26
    var spacing: CGFloat = 14
    var onSelect: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { i in
                let filled = i <= rating
                let star = Image(systemName: filled ? "star.fill" : "star")
                    .font(.system(size: size, weight: .light))
                    .foregroundStyle(filled ? Theme.ink : Theme.inkSecondary.opacity(0.7))
                if let onSelect {
                    Button {
                        Haptics.tap()
                        onSelect(i)
                    } label: {
                        star.frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(i) star\(i == 1 ? "" : "s")")
                } else {
                    star
                }
            }
        }
        .padding(.horizontal, onSelect == nil ? 0 : -((44 - size) / 2))
        .accessibilityElement(children: onSelect == nil ? .ignore : .contain)
        .accessibilityLabel(onSelect == nil ? RatingFilter.spoken(rating) : "Rating")
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
