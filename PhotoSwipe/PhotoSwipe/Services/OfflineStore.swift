import Foundation

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

    /// Stable on-disk name for a Dropbox file ID ("id:abc" -> "id_abc").
    static func fileName(for fileID: String) -> String {
        fileID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
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
}
