import SwiftUI

/// Small square async thumbnail for grids, filmstrips and album rows.
struct Thumbnail: View {
    /// Shared sizes, so rows across screens line up.
    static let album: CGFloat = 72
    static let folder: CGFloat = 54

    let item: PhotoItem
    var side: CGFloat = Thumbnail.album
    var cornerRadius: CGFloat = Radius.thumbnail
    @State private var loaded: (id: String, image: UIImage)?
    @Environment(\.displayScale) private var displayScale

    private var pixelSize: CGSize { CGSize(width: side * displayScale, height: side * displayScale) }

    var body: some View {
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
}
