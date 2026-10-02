import SwiftUI
import Photos

/// Small square async thumbnail for grids and duplicate strips.
struct Thumbnail: View {
    let asset: PHAsset
    var side: CGFloat = 88
    var cornerRadius: CGFloat = 14
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale
    private let service = PhotoLibraryService()

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
        .task(id: asset.localIdentifier) {
            image = await service.requestImage(
                for: asset, targetSize: CGSize(width: side * displayScale, height: side * displayScale))
        }
    }
}
