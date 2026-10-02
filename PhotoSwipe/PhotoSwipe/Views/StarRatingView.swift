import SwiftUI
import Photos

/// Five black stars. Interactive when `onSelect` is set (tap = exact rating).
struct StarRatingView: View {
    let rating: PHAsset.Rating
    var size: CGFloat = 26
    var spacing: CGFloat = 14
    var onSelect: ((PHAsset.Rating) -> Void)? = nil

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { i in
                let filled = i <= rating.rawValue
                let star = Image(systemName: filled ? "star.fill" : "star")
                    .font(.system(size: size, weight: .light))
                    .foregroundStyle(filled ? Theme.ink : Theme.inkSecondary.opacity(0.7))
                if let onSelect {
                    Button {
                        Haptics.tap()
                        onSelect(PHAsset.Rating(rawValue: i) ?? .unset)
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
    static let options = [0, 3, 4, 5]

    static func label(_ min: Int) -> String {
        switch min {
        case 0: return "Any rating"
        case 5: return "5 stars"
        default: return "\(min)+ stars"
        }
    }

    static func spoken(_ rating: PHAsset.Rating) -> String {
        rating == .unset ? "Unrated" : "\(rating.rawValue) star\(rating.rawValue == 1 ? "" : "s")"
    }
}
