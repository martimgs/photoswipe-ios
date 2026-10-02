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
///
/// The card takes the photo's own shape and fits inside the space it's
/// given, so portrait and landscape photos are always shown whole.
struct PhotoCardView: View {
    let item: PhotoItem
    var intent: SwipeIntent? = nil
    var intentStrength: Double = 0

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    /// Width / height of the photo. PhotoKit knows it up front; Dropbox
    /// photos use a placeholder until the image arrives.
    private var aspect: CGFloat {
        if let image, image.size.height > 0 { return image.size.width / image.size.height }
        if let asset = item.asset, asset.pixelHeight > 0 {
            return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        }
        return 3.0 / 4.0
    }

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fit(aspect: aspect, in: geo.size)
            ZStack {
                Theme.surface
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                } else {
                    ProgressView().tint(Theme.inkSecondary)
                }
                if let intent {
                    overlay(intent)
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.2), value: aspect)
            .task(id: item.id) { await loadImage(fitting: geo.size) }
        }
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

    /// Largest size with the given aspect ratio that fits in `space`.
    static func fit(aspect: CGFloat, in space: CGSize) -> CGSize {
        guard space.width > 0, space.height > 0, aspect > 0 else { return space }
        if space.width / space.height > aspect {
            return CGSize(width: space.height * aspect, height: space.height)
        }
        return CGSize(width: space.width, height: space.width / aspect)
    }

    /// Request enough pixels to fill the available space whichever way
    /// the photo is oriented, uncropped.
    private func loadImage(fitting cardSize: CGSize) async {
        let side = max(cardSize.width, cardSize.height) * displayScale
        let size = CGSize(width: side, height: side)

        // Show any cached image instantly — no blank frame while the exact size loads.
        if let fast = ImageLoader.shared.bestAvailableSync(for: item) {
            image = fast
        }

        guard let img = await ImageLoader.shared.image(for: item, pixelSize: size, fill: false) else { return }

        // If we already had something to show, swap silently (prefetch hit or placeholder).
        // Only animate when going from blank to first image.
        if image != nil {
            image = img
        } else {
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
    }
}
