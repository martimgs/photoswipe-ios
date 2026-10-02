import UIKit
import ImageIO

/// Loads images for any `PhotoItem`: PhotoKit for Apple Photos; for Dropbox,
/// the downloaded copy when there is one, otherwise a Dropbox thumbnail.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let photos = PhotoLibraryService()

    /// Largest image seen for each item ID — fast placeholder while the
    /// card-size image loads or is pre-warmed.
    private var bestAvailableByID: [String: UIImage] = [:]

    /// Active prefetch tasks, keyed by item ID.
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    /// Fetches a Dropbox thumbnail for online-only photos. Set in a later step.
    var dropboxThumbnail: ((_ fileID: String, _ maxPixels: CGFloat) async -> UIImage?)?

    private init() {
        memory.countLimit = 300
    }

    func image(for item: PhotoItem, pixelSize: CGSize, fill: Bool = true) async -> UIImage? {
        let maxPixels = max(pixelSize.width, pixelSize.height)
        let key = cacheKey(item: item, maxPixels: maxPixels, fill: fill)
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
                // Online-only photo: needs the network (cached thumbnails still load).
                image = await dropboxThumbnail?(item.id, maxPixels)
            }
        }
        if let image {
            memory.setObject(image, forKey: key)
            updateBestAvailable(item.id, image: image)
        }
        return image
    }

    /// Returns the largest image already in memory for this item — no async, no network.
    func bestAvailableSync(for item: PhotoItem) -> UIImage? {
        bestAvailableByID[item.id]
    }

    /// Pre-warm the cache for `items` at card pixel size. Cancels tasks for
    /// items that left the window; skips items already cached.
    func prefetch(_ items: [PhotoItem], pixelSize: CGSize) {
        let newIDs = Set(items.map(\.id))

        // Cancel tasks for items that left the prefetch window.
        for id in Array(prefetchTasks.keys) where !newIDs.contains(id) {
            prefetchTasks[id]?.cancel()
            prefetchTasks.removeValue(forKey: id)
        }

        // Ask PhotoKit to pre-warm its own cache for Apple Photos.
        let appleAssets = items.compactMap(\.asset)
        if !appleAssets.isEmpty {
            photos.startCaching(appleAssets, targetSize: pixelSize)
        }

        let maxPixels = max(pixelSize.width, pixelSize.height)
        for item in items {
            guard prefetchTasks[item.id] == nil else { continue }
            let key = cacheKey(item: item, maxPixels: maxPixels, fill: false)
            if memory.object(forKey: key) != nil { continue }
            let id = item.id
            prefetchTasks[id] = Task { [weak self] in
                guard let self else { return }
                _ = await self.image(for: item, pixelSize: pixelSize, fill: false)
                self.prefetchTasks.removeValue(forKey: id)
            }
        }
    }

    /// Drop cached images, e.g. after downloads are removed.
    func forgetAll() {
        memory.removeAllObjects()
        bestAvailableByID.removeAll()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
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

    private func cacheKey(item: PhotoItem, maxPixels: CGFloat, fill: Bool) -> NSString {
        "\(item.source.rawValue)|\(item.id)|\(Int(maxPixels))|\(fill)" as NSString
    }

    private func updateBestAvailable(_ id: String, image: UIImage) {
        let newPixels = image.size.width * image.size.height
        let existingPixels = bestAvailableByID[id].map { $0.size.width * $0.size.height } ?? 0
        if newPixels > existingPixels {
            bestAvailableByID[id] = image
        }
    }
}
