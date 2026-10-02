import Foundation
import SwiftData
import SwiftyDropbox
import UIKit

/// Read-only Dropbox operations: browsing folders, listing a connected
/// folder's images, checking for changes, and thumbnails. Nothing here
/// changes files in Dropbox (rating tags are in `DropboxSyncEngine`).
@MainActor
final class DropboxService {
    static let shared = DropboxService()

    enum ServiceError: LocalizedError {
        case signedOut
        var errorDescription: String? { "Sign in to Dropbox in Settings first." }
    }

    struct Folder: Identifiable, Hashable {
        let id: String          // folder ID ("id:…")
        let name: String
        let pathDisplay: String
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp"]

    private var client: DropboxClient {
        get throws {
            guard let client = DropboxClientsManager.authorizedClient else { throw ServiceError.signedOut }
            return client
        }
    }

    private init() {
        ImageLoader.shared.dropboxThumbnail = { [weak self] fileID, maxPixels in
            await self?.thumbnail(fileID: fileID, maxPixels: maxPixels)
        }
    }

    // MARK: Browsing

    /// Subfolders of `path` ("" = Dropbox root), sorted by name.
    func subfolders(of path: String) async throws -> [Folder] {
        var folders: [Folder] = []
        var result = try await client.files.listFolder(path: path).response()
        while true {
            folders += result.entries.compactMap { entry in
                guard let folder = entry as? Files.FolderMetadata else { return nil }
                return Folder(id: folder.id, name: folder.name, pathDisplay: folder.pathDisplay ?? folder.name)
            }
            guard result.hasMore else { break }
            result = try await client.files.listFolderContinue(cursor: result.cursor).response()
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Number of images directly inside a folder (for the picker).
    func imageCount(in folderID: String) async throws -> Int {
        var count = 0
        var result = try await client.files.listFolder(path: folderID).response()
        while true {
            count += result.entries.filter { Self.isImage($0) }.count
            guard result.hasMore else { break }
            result = try await client.files.listFolderContinue(cursor: result.cursor).response()
        }
        return count
    }

    static func isImage(_ entry: Files.Metadata) -> Bool {
        guard entry is Files.FileMetadata else { return false }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    // MARK: Check for changes

    struct ChangeSummary {
        var added: [String] = []     // file IDs
        var removed: [String] = []
        var updated: [String] = []
    }

    /// Brings the album's `DropboxFile` records up to date with the folder.
    /// First run lists everything; later runs use the saved cursor so only
    /// changes come back. Only files directly in the folder are included.
    @discardableResult
    func checkForChanges(_ album: ConnectedAlbum, context: ModelContext) async throws -> ChangeSummary {
        let albumID = album.externalID
        var summary = ChangeSummary()
        // Folder ID is stable across renames/moves; refresh its current path.
        if let path = try await folderPathLower(album) { album.folderPathLower = path }
        var existing = Dictionary(
            ((try? context.fetch(FetchDescriptor<DropboxFile>(
                predicate: #Predicate { $0.albumID == albumID }))) ?? []).map { ($0.fileID, $0) },
            uniquingKeysWith: { a, _ in a })

        var isFullListing = album.listCursor == nil
        var result: Files.ListFolderResult
        if let cursor = album.listCursor {
            do {
                result = try await client.files.listFolderContinue(cursor: cursor).response()
            } catch {
                // Expired/reset cursor: fall back to a full listing.
                result = try await client.files.listFolder(path: albumID, includeDeleted: true).response()
                isFullListing = true
            }
        } else {
            result = try await client.files.listFolder(path: albumID, includeDeleted: true).response()
        }

        var seen = Set<String>()
        var newFiles: [(fileID: String, pathLower: String)] = []
        while true {
            for entry in result.entries {
                if let file = entry as? Files.FileMetadata {
                    // Not an image (or renamed to a non-image): treat as gone.
                    guard Self.isImage(file), Self.isDirectChild(file, of: album) else {
                        if let gone = existing.removeValue(forKey: file.id) {
                            remove(gone, context: context, summary: &summary)
                        }
                        continue
                    }
                    seen.insert(file.id)
                    if let record = existing[file.id] {
                        let changed = record.contentHash != file.contentHash
                        record.name = file.name
                        record.size = Int64(file.size)
                        record.serverModified = file.serverModified
                        record.clientModified = file.clientModified
                        if changed {
                            record.contentHash = file.contentHash
                            summary.updated.append(file.id)
                        }
                    } else {
                        let record = DropboxFile(
                            fileID: file.id, albumID: albumID, name: file.name, size: Int64(file.size),
                            serverModified: file.serverModified, clientModified: file.clientModified,
                            contentHash: file.contentHash)
                        context.insert(record)
                        existing[file.id] = record
                        summary.added.append(file.id)
                        if let lower = file.pathLower { newFiles.append((file.id, lower)) }
                    }
                } else if entry is Files.DeletedMetadata {
                    // Deleted entries carry no ID; match by lowercased path.
                    if let lower = entry.pathLower,
                       let gone = existing.values.first(where: { Self.pathLower(of: $0, in: album) == lower }) {
                        existing.removeValue(forKey: gone.fileID)
                        remove(gone, context: context, summary: &summary)
                    }
                }
            }
            guard result.hasMore else { break }
            result = try await client.files.listFolderContinue(cursor: result.cursor).response()
        }

        // A full listing is authoritative: anything not seen is gone.
        if isFullListing {
            for (id, record) in existing where !seen.contains(id) {
                remove(record, context: context, summary: &summary)
            }
        }

        album.listCursor = result.cursor
        try? context.save()
        // Ratings set on another device come in as tags on new files.
        await DropboxSyncEngine.shared.importTags(for: newFiles, context: context)
        album.lastCheckedAt = .now
        try? context.save()
        return summary
    }

    /// Removes a file that left the folder. Its rating stays in `PhotoState`.
    /// Only the app's own downloaded copy is deleted; Dropbox is untouched.
    private func remove(_ record: DropboxFile, context: ModelContext, summary: inout ChangeSummary) {
        OfflineStore.removeLocalCopy(record.fileID)
        summary.removed.append(record.fileID)
        context.delete(record)
    }

    private static func isDirectChild(_ file: Files.FileMetadata, of album: ConnectedAlbum) -> Bool {
        guard let folder = album.folderPathLower, let path = file.pathLower else { return true }
        return (path as NSString).deletingLastPathComponent == folder
    }

    private static func pathLower(of record: DropboxFile, in album: ConnectedAlbum) -> String? {
        guard let folder = album.folderPathLower else { return nil }
        return (folder as NSString).appendingPathComponent(record.name.lowercased())
    }

    private func folderPathLower(_ album: ConnectedAlbum) async throws -> String? {
        let metadata = try await client.files.getMetadata(path: album.externalID).response()
        return metadata.pathLower
    }

    // MARK: Thumbnails (online-only photos)

    private var thumbnailCache: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropboxThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A Dropbox-rendered JPEG sized for the request, cached in Caches (fine to
    /// lose; it's re-fetched when online). Falls back to the original file for
    /// formats Dropbox can't thumbnail (e.g. HEIC), downsampled on device.
    func thumbnail(fileID: String, maxPixels: CGFloat) async -> UIImage? {
        let size: Files.ThumbnailSize = maxPixels <= 256 ? .w256h256 : maxPixels <= 1024 ? .w1024h768 : .w2048h1536
        let cached = thumbnailCache.appendingPathComponent("\(OfflineStore.fileName(for: fileID))-\(size).jpg")
        if FileManager.default.fileExists(atPath: cached.path) {
            return await ImageLoader.downsample(cached, maxPixels: maxPixels)
        }
        guard Connectivity.shared.isOnline, let client = try? client else { return nil }
        do {
            _ = try await client.files.getThumbnailV2(
                resource: .path(fileID), format: .jpeg, size: size, mode: .bestfit,
                overwrite: true, destination: cached).response()
            return await ImageLoader.downsample(cached, maxPixels: maxPixels)
        } catch {
            let original = thumbnailCache.appendingPathComponent(OfflineStore.fileName(for: fileID) + "-original")
            if !FileManager.default.fileExists(atPath: original.path) {
                guard (try? await client.files.download(path: fileID, overwrite: true, destination: original).response()) != nil
                else { return nil }
            }
            return await ImageLoader.downsample(original, maxPixels: maxPixels)
        }
    }
}
