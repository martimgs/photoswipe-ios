import UIKit
import ImageIO

/// Loads images for any `PhotoItem`: PhotoKit for Apple Photos; for Dropbox,
/// the downloaded copy when there is one, otherwise a Dropbox thumbnail.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    /// Low-res, uncropped version shown on the card while scrubbing and
    /// until the sharp card-size image is ready.
    static let previewSize = CGSize(width: 400, height: 400)

    struct Request {
        let item: PhotoItem
        let pixelSize: CGSize
        let fill: Bool
    }

    private let memory = NSCache<NSString, UIImage>()
    private let photos = PhotoLibraryService()
    /// Loads in progress, so a card and a prefetch never decode the same image twice.
    private var loads: [String: Task<UIImage?, Never>] = [:]
    private var queue: [Request] = []
    private var prefetching = 0
    private let maxPrefetches = 4

    /// Fetches a Dropbox thumbnail for online-only photos.
    var dropboxThumbnail: ((_ fileID: String, _ maxPixels: CGFloat) async -> UIImage?)?

    private init() {
        memory.countLimit = 800
        memory.totalCostLimit = 300 * 1024 * 1024
    }

    /// Already in memory at exactly this size — no waiting.
    func cachedImage(for item: PhotoItem, pixelSize: CGSize, fill: Bool) -> UIImage? {
        memory.object(forKey: Self.key(item, pixelSize, fill) as NSString)
    }

    /// The sharpest uncropped image of `item` already in memory.
    func cardPlaceholder(for item: PhotoItem, fullPixelSize: CGSize) -> UIImage? {
        cachedImage(for: item, pixelSize: fullPixelSize, fill: false)
            ?? cachedImage(for: item, pixelSize: Self.previewSize, fill: false)
    }

    func image(for item: PhotoItem, pixelSize: CGSize, fill: Bool = true) async -> UIImage? {
        let key = Self.key(item, pixelSize, fill)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let running = loads[key] { return await running.value }

        let task = Task { await self.load(item, pixelSize: pixelSize, fill: fill) }
        loads[key] = task
        let image = await task.value
        loads[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image)) }
        return image
    }

    /// Replace the prefetch queue (nearest photo first). Requests from an
    /// earlier call that haven't started are dropped, so fast scrubbing
    /// never builds a backlog.
    func prefetch(_ requests: [Request]) {
        queue = requests
        pump()
    }

    /// Drop cached images, e.g. after downloads are removed.
    func forgetAll() {
        memory.removeAllObjects()
        queue.removeAll()
    }

    private func pump() {
        while prefetching < maxPrefetches, !queue.isEmpty {
            let r = queue.removeFirst()
            let key = Self.key(r.item, r.pixelSize, r.fill)
            guard memory.object(forKey: key as NSString) == nil, loads[key] == nil else { continue }
            prefetching += 1
            Task {
                _ = await image(for: r.item, pixelSize: r.pixelSize, fill: r.fill)
                prefetching -= 1
                pump()
            }
        }
    }

    private func load(_ item: PhotoItem, pixelSize: CGSize, fill: Bool) async -> UIImage? {
        let maxPixels = max(pixelSize.width, pixelSize.height)
        switch item.source {
        case .applePhotos:
            guard let asset = item.asset else { return nil }
            return await photos.requestImage(for: asset, targetSize: pixelSize,
                                             contentMode: fill ? .aspectFill : .aspectFit)
        case .dropbox:
            if OfflineStore.hasLocalCopy(item.id) {
                return await Self.downsample(OfflineStore.localURL(for: item.id), maxPixels: maxPixels)
            }
            // Online-only photo: needs the network (cached thumbnails still load).
            return await dropboxThumbnail?(item.id, maxPixels)
        }
    }

    private static func key(_ item: PhotoItem, _ pixelSize: CGSize, _ fill: Bool) -> String {
        "\(item.source.rawValue)|\(item.id)|\(Int(max(pixelSize.width, pixelSize.height)))|\(fill)"
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
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
