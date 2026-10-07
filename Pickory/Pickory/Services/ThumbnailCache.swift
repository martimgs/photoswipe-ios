import Foundation
import SwiftyDropbox

/// Dropbox-rendered JPEGs of online photos, kept in Caches (fine to lose;
/// fetched again when online). Small renders are also used for downloaded
/// photos: decoding one is much cheaper than decoding the full copy.
enum ThumbnailCache {
    /// Sizes Dropbox renders, smallest first, with the largest request each
    /// still fills sharply (bestfit keeps the aspect ratio, so the short side
    /// is smaller than the size's name).
    static let sizes: [(size: Files.ThumbnailSize, name: String, usable: CGFloat)] = [
        (.w256h256, "256", 192),
        (.w640h480, "640", 480),
        (.w1024h768, "1024", 768),
        (.w2048h1536, "2048", .infinity),
    ]

    /// Album and folder covers (96 pt rows at 3x), fetched in batches.
    static let coverBucket = 1

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropboxPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func bucket(for maxPixels: CGFloat) -> Int {
        sizes.firstIndex { maxPixels <= $0.usable } ?? sizes.count - 1
    }

    static func url(_ fileID: String, bucket: Int) -> URL {
        directory.appendingPathComponent("\(OfflineStore.fileName(for: fileID))-\(sizes[bucket].name).jpg")
    }

    /// The original file, for formats Dropbox can't render.
    static func originalURL(_ fileID: String) -> URL {
        directory.appendingPathComponent(OfflineStore.fileName(for: fileID) + "-original")
    }

    /// Renders sharp enough for `maxPixels`, smallest first. Larger ones
    /// only up to 1024: decoding a 2048 render for a small tile costs more
    /// than it saves.
    static func candidates(_ fileID: String, maxPixels: CGFloat) -> [URL] {
        let first = bucket(for: maxPixels)
        return (first...max(first, 2)).map { url(fileID, bucket: $0) }
    }

    static func hasCover(_ fileID: String) -> Bool {
        let first = bucket(for: sizes[coverBucket].usable)
        return (first...2).contains { FileManager.default.fileExists(atPath: url(fileID, bucket: $0).path) }
    }

    /// The photo changed in Dropbox: its renders are out of date.
    static func remove(_ fileID: String) {
        for bucket in sizes.indices { try? FileManager.default.removeItem(at: url(fileID, bucket: bucket)) }
        try? FileManager.default.removeItem(at: originalURL(fileID))
    }

    /// Dropbox can't render this file (format, size): only then is the
    /// original worth downloading. Rate limits and network errors aren't.
    static func isUnrenderable(_ error: Error) -> Bool {
        if case .routeError(let box, _, _, _) = error as? CallError<Files.ThumbnailV2Error> {
            switch box.unboxed {
            case .unsupportedExtension, .unsupportedImage, .conversionError: return true
            default: return false
            }
        }
        return false
    }
}
