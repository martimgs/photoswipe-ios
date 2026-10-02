import Foundation
import SwiftData
import CryptoKit

/// Where downloaded Dropbox photos live: Application Support (never Caches,
/// which iOS can purge), excluded from iCloud backup since Dropbox has them.
enum OfflineStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DropboxOffline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = dir
            try? url.setResourceValues(values)
        }
        return dir
    }

    /// Stable on-disk name for a Dropbox file ID. File IDs are
    /// case-sensitive but the iOS file system isn't, so the ID is hashed:
    /// "id:…Qw" and "id:…qw" must never share a file.
    static func fileName(for fileID: String) -> String {
        SHA256.hash(data: Data(fileID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Files from older builds were named after the ID itself ("id_…"),
    /// which collided for IDs differing only in case. Returns true if any
    /// were removed, so offline albums can be downloaded again.
    @discardableResult
    static func removeLegacyFiles() -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
        let legacy = names.filter { $0.hasPrefix("id_") }
        for name in legacy { try? fm.removeItem(at: directory.appendingPathComponent(name)) }
        // Old online-thumbnail cache used the same naming.
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: caches.appendingPathComponent("DropboxThumbnails"))
        return !legacy.isEmpty
    }

    static func localURL(for fileID: String) -> URL {
        directory.appendingPathComponent(fileName(for: fileID))
    }

    static func hasLocalCopy(_ fileID: String) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: fileID).path)
    }

    /// Removes the app's own downloaded copy. Never touches Dropbox.
    static func removeLocalCopy(_ fileID: String) {
        try? FileManager.default.removeItem(at: localURL(for: fileID))
    }

    /// Removes the local copy unless another connected album that is kept
    /// offline (or downloading) also contains this file, e.g. a subfolder
    /// connected on its own as well as through its parent.
    @MainActor
    static func removeLocalCopyIfUnused(_ fileID: String, leaving albumID: String, context: ModelContext) {
        let others = (try? context.fetch(FetchDescriptor<DropboxFile>(
            predicate: #Predicate { $0.fileID == fileID && $0.albumID != albumID }))) ?? []
        let offlineAlbums = Set(((try? context.fetch(FetchDescriptor<ConnectedAlbum>())) ?? [])
            .filter { $0.offlineState != .onlineOnly }.map(\.externalID))
        if others.contains(where: { offlineAlbums.contains($0.albumID) }) { return }
        removeLocalCopy(fileID)
    }
}
