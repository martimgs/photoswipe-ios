import SwiftUI

/// What a drag is about to do, shown as a white symbol over the dimmed card.
enum SwipeIntent: Equatable {
    case up, skip, pick, reject

    var symbol: String {
        switch self {
        case .up: return "star.fill"
        case .skip: return "arrow.left"
        case .pick: return "heart.fill"
        case .reject: return "xmark"
        }
    }

    var caption: String {
        switch self {
        case .up: return "+1"
        case .skip: return "Next"
        case .pick: return "Pick"
        case .reject: return "Reject"
        }
    }
}

/// A large rounded photo card. While dragging, shows the pending change as a
/// white overlay whose opacity follows the drag.
///
/// The card takes the photo's own shape and fits inside the space it's
/// given, so portrait and landscape photos are always shown whole. A photo
/// with a soft crop shows just the cropped part, marked with a badge.
struct PhotoCardView: View {
    let item: PhotoItem
    var crop: SoftCrop? = nil
    var intent: SwipeIntent? = nil
    var intentStrength: Double = 0

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    /// Width / height of the photo. PhotoKit knows it up front; Dropbox
    /// photos use a placeholder until the image arrives.
    private func aspect(of shown: UIImage?) -> CGFloat {
        if let crop { return crop.aspect.ratio }
        if let asset = item.asset, asset.pixelHeight > 0 {
            return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        }
        if let shown, shown.size.height > 0 { return shown.size.width / shown.size.height }
        return 3.0 / 4.0
    }

    var body: some View {
        GeometryReader { geo in
            // Anything already in memory shows on the very first frame.
            let shown = image ?? ImageLoader.shared.cardPlaceholder(
                for: item, fullPixelSize: pixelSize(fitting: geo.size))
            let ratio = aspect(of: shown)
            let fitted = Self.fit(aspect: ratio, in: geo.size)
            ZStack {
                Theme.surface
                if let shown, let crop {
                    CroppedImage(image: shown, crop: crop)
                } else if let shown {
                    Image(uiImage: shown)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(Theme.inkSecondary)
                }
                if let intent {
                    overlay(intent)
                }
            }
            .overlay(alignment: .topLeading) {
                if let crop, intent == nil { CropBadge(aspect: crop.aspect) }
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.photo, style: .continuous))
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.2), value: ratio)
            .task(id: LoadKey(id: item.id, crop: crop)) { await loadImage(fitting: geo.size) }
        }
        .accessibilityElement()
        .accessibilityLabel(item.date.map {
            "Photo from \($0.formatted(date: .abbreviated, time: .omitted))"
        } ?? "Photo")
    }

    /// Reload when a crop is saved: it may need a sharper image.
    private struct LoadKey: Equatable {
        let id: String
        let crop: SoftCrop?
    }

    private func overlay(_ intent: SwipeIntent) -> some View {
        let o = min(max(intentStrength, 0), 1)
        return ZStack {
            Color.black.opacity(0.18 * o)
            VStack(spacing: Spacing.xs) {
                Image(systemName: intent.symbol)
                    .font(.system(size: 56, weight: .light))
                Text(intent.caption)
                    .font(.headline.weight(.regular))
            }
            .foregroundStyle(.white)
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
    /// the photo is oriented, uncropped. A soft crop shows only part of
    /// the image, so it gets proportionally more (up to 3x).
    private func pixelSize(fitting cardSize: CGSize) -> CGSize {
        let zoom = crop.map { min(1 / max(min($0.rect.width, $0.rect.height), 0.01), 3) } ?? 1
        let side = (max(cardSize.width, cardSize.height) * displayScale * zoom).rounded()
        return CGSize(width: side, height: side)
    }

    /// Preview first, then the sharp image once the card has been current
    /// for a moment, so photos scrubbed past never start a full-size decode.
    private func loadImage(fitting cardSize: CGSize) async {
        let loader = ImageLoader.shared
        let full = pixelSize(fitting: cardSize)
        if let sharp = loader.cachedImage(for: item, pixelSize: full, fill: false) {
            image = sharp
            return
        }
        if let preview = await loader.image(for: item, pixelSize: ImageLoader.previewSize, fill: false) {
            guard !Task.isCancelled else { return }
            image = preview
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled,
              let sharp = await loader.image(for: item, pixelSize: full, fill: false),
              !Task.isCancelled else { return }
        image = sharp
    }
}
