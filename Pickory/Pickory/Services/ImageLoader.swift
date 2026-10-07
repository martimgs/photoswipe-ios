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

    /// A load in progress, shared by everyone waiting for the same image so
    /// a card and a prefetch never decode it twice. Cancelled once nobody
    /// waits for it any more (e.g. a grid cell scrolled away).
    private struct Load {
        let token: UUID
        let task: Task<UIImage?, Never>
        var waiters: Int
    }
    private var loads: [String: Load] = [:]
    private var queue: [Request] = []
    private var prefetching = 0
    private let maxPrefetches = 4
    /// Dropbox decodes and downloads running at once. Fast scrolling would
    /// otherwise start one per cell it passes. Separate, so photos on disk
    /// never wait behind slow network requests.
    private let decodeSlots = Slots(limit: 4)
    private let networkSlots = Slots(limit: 4)

    /// Fetches a Dropbox thumbnail for online-only photos.
    var dropboxThumbnail: ((_ fileID: String, _ maxPixels: CGFloat) async -> UIImage?)?

    private init() {
        // Enough for the photos around the current card and a screen or two
        // of grid; anything else is decoded again from disk when needed.
        memory.countLimit = 400
        memory.totalCostLimit = 120 * 1024 * 1024
        let center = NotificationCenter.default
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ImageLoader.shared.forgetAll() }
            }
        }
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

    /// Returns nil if the calling task is cancelled before the image is ready.
    func image(for item: PhotoItem, pixelSize: CGSize, fill: Bool = true) async -> UIImage? {
        let key = Self.key(item, pixelSize, fill)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if Task.isCancelled { return nil }

        let load: Load
        if let running = loads[key] {
            load = running
            loads[key]?.waiters += 1
        } else {
            let token = UUID()
            let task = Task {
                let image = await self.load(item, pixelSize: pixelSize, fill: fill)
                if let image { self.memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image)) }
                if self.loads[key]?.token == token { self.loads[key] = nil }
                return image
            }
            load = Load(token: token, task: task, waiters: 1)
            loads[key] = load
        }
        return await withTaskCancellationHandler {
            let image = await load.task.value
            if !Task.isCancelled { leave(key, load.token) }
            return image
        } onCancel: {
            Task { @MainActor in self.leave(key, load.token) }
        }
    }

    /// One waiter is done with a load; the last one to leave early cancels it.
    private func leave(_ key: String, _ token: UUID) {
        guard let load = loads[key], load.token == token else { return }
        if load.waiters > 1 {
            loads[key]?.waiters -= 1
        } else {
            load.task.cancel()
            loads[key] = nil
        }
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
            // Small sizes: a cached Dropbox render decodes much faster than
            // the downloaded copy (2048 px or the original).
            let renders = ThumbnailCache.candidates(item.id, maxPixels: maxPixels)
            let local = [OfflineStore.localURL(for: item.id)]
            let original = [ThumbnailCache.originalURL(item.id)]
            let onDisk = maxPixels <= ThumbnailCache.sizes[2].usable
                ? renders + local + original
                : local + renders + original
            await decodeSlots.acquire()
            // Nobody wants it any more (scrolled away while waiting).
            let image = Task.isCancelled ? nil : await Self.downsample(firstOf: onDisk, maxPixels: maxPixels)
            decodeSlots.release()
            if image != nil || Task.isCancelled { return image }
            // Online-only photo: needs the network.
            await networkSlots.acquire()
            defer { networkSlots.release() }
            if Task.isCancelled { return nil }
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
        await downsample(firstOf: [url], maxPixels: maxPixels)
    }

    /// Decodes the first of `urls` that exists, off the main thread.
    nonisolated static func downsample(firstOf urls: [URL], maxPixels: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let url = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            // Don't keep the full-size decode around, and decode here rather
            // than lazily on the main thread when the image is first drawn.
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1),
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

/// A small async semaphore. The newest waiter goes first: when scrolling,
/// the latest request is the one on screen.
@MainActor
private final class Slots {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the slot straight to the next waiter, if any.
    func release() {
        if let next = waiting.popLast() {
            next.resume()
        } else {
            running -= 1
        }
    }
}
