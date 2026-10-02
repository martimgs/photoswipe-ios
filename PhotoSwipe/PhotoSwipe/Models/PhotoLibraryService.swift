import Photos
import UIKit

/// Thin wrapper over PhotoKit: authorization, fetching assets and albums,
/// image loading, and writing star ratings. Never deletes anything.
/// All mutations go through `PHPhotoLibrary.performChanges`.
final class PhotoLibraryService {
    private let imageManager = PHCachingImageManager()

    // MARK: Authorization

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    // MARK: Fetch

    // Deliberately no whole-library fetch: the app only ever works inside
    // albums the user has connected.

    private var imagesOnly: PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    /// Image assets in an album, in the album's own order.
    func photos(in album: PHAssetCollection) -> [PHAsset] {
        let result = PHAsset.fetchAssets(in: album, options: imagesOnly)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    func photoCount(in album: PHAssetCollection) -> Int {
        PHAsset.fetchAssets(in: album, options: imagesOnly).count
    }

    /// The album's key photo, falling back to its first image.
    func coverPhoto(of album: PHAssetCollection) -> PHAsset? {
        PHAsset.fetchKeyAssets(in: album, options: imagesOnly)?.firstObject
            ?? PHAsset.fetchAssets(in: album, options: imagesOnly).firstObject
    }

    // MARK: Image loading

    func requestImage(for asset: PHAsset, targetSize: CGSize,
                      contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                if resumed { return }
                // Opportunistic delivers a degraded placeholder first, then a
                // single non-degraded final callback (image OR nil on error /
                // failed iCloud fetch). Resume on the final one regardless, so
                // a nil result can never leak the continuation.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }   // wait for the final callback
                resumed = true
                cont.resume(returning: image)
            }
        }
    }

    func startCaching(_ assets: [PHAsset], targetSize: CGSize) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        imageManager.startCachingImages(for: assets, targetSize: targetSize,
                                        contentMode: .aspectFill, options: options)
    }

    /// Drop all prefetched images — call when leaving a deck to bound memory.
    func stopCaching() {
        imageManager.stopCachingImagesForAllAssets()
    }

    // MARK: Mutations

    func setRating(_ asset: PHAsset, _ rating: PHAsset.Rating) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetChangeRequest(for: asset)
            req.rating = rating
        }
    }

    // MARK: Albums

    /// Albums the user created. Excludes smart albums (Recents, Favorites…)
    /// and shared iCloud albums by construction.
    func userAlbums() -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil)
        var albums: [PHAssetCollection] = []
        result.enumerateObjects { c, _, _ in albums.append(c) }
        return albums
    }

    func album(withLocalIdentifier id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil).firstObject
    }
}
