import UIKit
import ImageIO

/// Loads images for any `PhotoItem`: PhotoKit for Apple Photos; for Dropbox,
/// the downloaded copy when there is one, otherwise a Dropbox thumbnail.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let photos = PhotoLibraryService()

    /// Fetches a Dropbox thumbnail for online-only photos. Set in a later step.
    var dropboxThumbnail: ((_ fileID: String, _ maxPixels: CGFloat) async -> UIImage?)?

    private init() {
        memory.countLimit = 300
    }

    func image(for item: PhotoItem, pixelSize: CGSize, fill: Bool = true) async -> UIImage? {
        let maxPixels = max(pixelSize.width, pixelSize.height)
        let key = "\(item.source.rawValue)|\(item.id)|\(Int(maxPixels))" as NSString
        if let cached = memory.object(forKey: key) { return cached }

        let image: UIImage?
        switch item.source {
        case .applePhotos:
            guard let asset = item.asset else { return nil }
            image = await photos.requestImage(for: asset, targetSize: pixelSize,
                                              contentMode: fill ? .aspectFill : .aspectFit)
        case .dropbox:
            if OfflineStore.hasLocalCopy(item.id) {
                image = await Self.downsample(OfflineStore.localURL(for: item.id), maxPixels: maxPixels)
            } else {
                image = await dropboxThumbnail?(item.id, maxPixels)
            }
        }
        if let image { memory.setObject(image, forKey: key) }
        return image
    }

    /// Drop cached images, e.g. after downloads are removed.
    func forgetAll() {
        memory.removeAllObjects()
    }

    /// Decodes a file at roughly the size needed, off the main thread.
    nonisolated static func downsample(_ url: URL, maxPixels: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1),
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}
