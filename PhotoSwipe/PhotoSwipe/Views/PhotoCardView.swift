import SwiftUI

/// What a drag is about to do, shown as a large white overlay on the card.
enum SwipeIntent: Equatable {
    case up, down, pick, reject

    var symbol: String {
        switch self {
        case .up: return "star.fill"
        case .down: return "star.slash"
        case .pick: return "heart.fill"
        case .reject: return "xmark"
        }
    }

    var caption: String {
        switch self {
        case .up: return "+1"
        case .down: return "−1"
        case .pick: return "Pick"
        case .reject: return "Reject"
        }
    }
}

/// A large rounded photo card. While dragging, shows the pending change as a
/// white overlay whose opacity follows the drag.
struct PhotoCardView: View {
    let item: PhotoItem
    var intent: SwipeIntent? = nil
    var intentStrength: Double = 0

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.surface
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                } else {
                    ProgressView().tint(Theme.inkSecondary)
                }
                if let intent {
                    overlay(intent)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .task(id: item.id) { await loadImage(fitting: geo.size) }
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
        .accessibilityElement()
        .accessibilityLabel(item.date.map {
            "Photo from \($0.formatted(date: .abbreviated, time: .omitted))"
        } ?? "Photo")
    }

    private func overlay(_ intent: SwipeIntent) -> some View {
        let o = min(max(intentStrength, 0), 1)
        return ZStack {
            Color.black.opacity(0.18 * o)
            VStack(spacing: 6) {
                Image(systemName: intent.symbol)
                    .font(.system(size: 72, weight: .regular))
                Text(intent.caption)
                    .font(.system(size: 20, weight: .medium))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 10)
            .scaleEffect(0.8 + 0.2 * o)
        }
        .opacity(o)
        .allowsHitTesting(false)
    }

    /// Request pixels for the card's actual on-screen size.
    private func loadImage(fitting cardSize: CGSize) async {
        let size = CGSize(width: cardSize.width * displayScale, height: cardSize.height * displayScale)
        if let img = await ImageLoader.shared.image(for: item, pixelSize: size) {
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
    }
}
