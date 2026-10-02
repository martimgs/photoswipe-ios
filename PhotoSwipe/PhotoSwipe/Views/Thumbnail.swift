import SwiftUI

/// Small square async thumbnail for grids, filmstrips and album rows.
struct Thumbnail: View {
    let item: PhotoItem
    var side: CGFloat = 88
    var cornerRadius: CGFloat = 14
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.surface)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: item.id) {
            image = await ImageLoader.shared.image(
                for: item, pixelSize: CGSize(width: side * displayScale, height: side * displayScale))
        }
    }
}
