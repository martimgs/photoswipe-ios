import SwiftUI

/// Small square async thumbnail for grids, filmstrips and album rows.
/// With a soft crop it shows the cropped part at its own shape, fitted
/// inside the square, with a crop badge.
struct Thumbnail: View {
    /// Shared sizes, so rows across screens line up.
    static let album: CGFloat = 96
    static let folder: CGFloat = 60

    let item: PhotoItem
    var side: CGFloat = Thumbnail.album
    var cornerRadius: CGFloat = Radius.thumbnail
    var crop: SoftCrop? = nil
    @State private var loaded: (id: String, image: UIImage)?
    @Environment(\.displayScale) private var displayScale

    private var pixelSize: CGSize { CGSize(width: side * displayScale, height: side * displayScale) }

    var body: some View {
        if let crop { cropped(crop) } else { square }
    }

    @ViewBuilder private var square: some View {
        // A cached image shows on the first frame; `loaded` may still hold
        // the previous item's image when this view is reused.
        let shown = loaded?.id == item.id
            ? loaded?.image
            : ImageLoader.shared.cachedImage(for: item, pixelSize: pixelSize, fill: true)
        ZStack {
            Rectangle().fill(Theme.surface)
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: item.id) {
            if let image = await ImageLoader.shared.image(for: item, pixelSize: pixelSize) {
                loaded = (item.id, image)
            }
        }
    }

    /// Uncropped image, so the crop can be cut from it; enough pixels that
    /// the cropped part stays sharp.
    private func cropped(_ crop: SoftCrop) -> some View {
        let fitted = PhotoCardView.fit(aspect: crop.aspect.ratio, in: CGSize(width: side, height: side))
        let zoom = min(1 / max(min(crop.rect.width, crop.rect.height), 0.01), 3)
        let pixels = CGSize(width: (side * displayScale * zoom).rounded(), height: (side * displayScale * zoom).rounded())
        // Keyed by the crop too: a changed crop may need more pixels.
        let key = "\(item.id)|\(crop.aspect.rawValue)|\(crop.rect.width)"
        let shown = loaded?.id == key
            ? loaded?.image
            : ImageLoader.shared.cachedImage(for: item, pixelSize: pixels, fill: false)
        return ZStack {
            Rectangle().fill(Theme.surface)
            if let shown { CroppedImage(image: shown, crop: crop) }
        }
        .frame(width: fitted.width, height: fitted.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .topLeading) { CropBadge(aspect: crop.aspect) }
        .frame(width: side, height: side)
        .task(id: key) {
            if let image = await ImageLoader.shared.image(for: item, pixelSize: pixels, fill: false) {
                loaded = (key, image)
            }
        }
    }
}
