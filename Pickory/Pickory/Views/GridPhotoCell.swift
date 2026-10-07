import SwiftUI

/// One tile of the Instagram-style review grid: the photo filling a 3:4
/// cell, with Photos-style white labels on top — "2★" top left, the soft
/// crop (crop icon + "4:5") top right.
///
/// A soft-cropped photo shows what the profile grid would: the crop
/// (a carousel's first post), trimmed to 3:4 around its center.
struct GridPhotoCell: View {
    static let aspect: CGFloat = 3.0 / 4.0

    let item: PhotoItem
    let width: CGFloat
    let rating: Int
    let crop: SoftCrop?
    var dimmed = false
    var unsynced = false

    @State private var loaded: (key: String, image: UIImage)?
    @Environment(\.displayScale) private var displayScale

    private var height: CGFloat { (width / Self.aspect).rounded() }

    /// The part of the uncropped image shown in the cell (normalized).
    private var shownRect: CGRect? {
        guard let crop else { return nil }
        var rect = crop.rect
        if crop.aspect.splitsInTwo { rect.size.width /= 2 }
        // Width ÷ height of that part of the photo.
        let ratio = crop.aspect.splitsInTwo ? crop.aspect.ratio / 2 : crop.aspect.ratio
        if ratio > Self.aspect {
            let w = rect.width * Self.aspect / ratio
            rect.origin.x += (rect.width - w) / 2
            rect.size.width = w
        } else {
            let h = rect.height * ratio / Self.aspect
            rect.origin.y += (rect.height - h) / 2
            rect.size.height = h
        }
        return rect
    }

    /// Cropped tiles load the uncropped photo, with enough pixels that the
    /// part shown stays sharp; plain tiles let the loader fill the cell.
    private var request: (size: CGSize, fill: Bool, key: String) {
        let base = CGSize(width: width * displayScale, height: height * displayScale)
        guard let rect = shownRect else { return (base, true, item.id) }
        let zoom = min(1 / max(min(rect.width, rect.height), 0.01), 3)
        let side = (max(base.width, base.height) * zoom).rounded()
        return (CGSize(width: side, height: side), false, "\(item.id)|\(rect)")
    }

    var body: some View {
        let request = self.request
        let shown = loaded?.key == request.key
            ? loaded?.image
            : ImageLoader.shared.cachedImage(for: item, pixelSize: request.size, fill: request.fill)
        ZStack {
            Theme.surface
            if let shown {
                if let rect = shownRect {
                    CroppedImage(image: shown, rect: rect)
                } else {
                    Image(uiImage: shown)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .opacity(dimmed ? 0.55 : 1)
        .overlay(alignment: .topLeading) {
            if rating > 0 { GridLabel(text: "\(rating)", symbol: "star.fill", symbolAfter: true) }
        }
        .overlay(alignment: .topTrailing) {
            if let crop { GridLabel(text: crop.aspect.rawValue, symbol: "crop") }
        }
        .overlay(alignment: .bottomTrailing) {
            if unsynced { GridLabel(text: nil, symbol: "arrow.up.circle") }
        }
        .contentShape(Rectangle())
        .task(id: request.key) {
            if let image = await ImageLoader.shared.image(for: item, pixelSize: request.size, fill: request.fill) {
                loaded = (request.key, image)
            }
        }
    }
}

/// White text and SF Symbol with a soft shadow, like the star count on
/// Photos thumbnails.
struct GridLabel: View {
    let text: String?
    let symbol: String
    var symbolAfter = false

    var body: some View {
        HStack(spacing: 1) {
            if !symbolAfter { Image(systemName: symbol).font(.caption.weight(.semibold)) }
            if let text { Text(text).monospacedDigit() }
            if symbolAfter { Image(systemName: symbol).font(.caption.weight(.semibold)) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .environment(\.colorScheme, .light)
    }
}
