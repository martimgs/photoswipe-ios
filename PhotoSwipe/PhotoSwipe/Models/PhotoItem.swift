import Foundation
import Photos

/// One photo from any source. Screens and the session view model work with
/// this instead of a source-specific type.
struct PhotoItem: Identifiable, Hashable {
    /// PhotoKit local identifier, or Dropbox file ID ("id:…"). Never a path or name.
    let id: String
    let source: PhotoSourceKind
    let date: Date?
    /// Apple Photos only.
    let asset: PHAsset?
    /// Dropbox only: subfolder inside the album ("" = top level).
    var folder: String = ""

    init(asset: PHAsset) {
        id = asset.localIdentifier
        source = .applePhotos
        date = asset.creationDate
        self.asset = asset
    }

    init(dropboxFileID: String, date: Date?, folder: String = "") {
        id = dropboxFileID
        source = .dropbox
        self.date = date
        asset = nil
        self.folder = folder
    }

    /// True if the photo is in `scope` or any folder below it (nil = whole album).
    func isInFolder(_ scope: String?) -> Bool {
        guard let scope, !scope.isEmpty else { return true }
        return folder == scope || folder.hasPrefix(scope + "/")
    }

    static func == (a: PhotoItem, b: PhotoItem) -> Bool { a.id == b.id && a.source == b.source }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(source)
    }
}

/// Star ratings are 0 (unrated) through 5 everywhere in the app.
enum Stars {
    static let range = 0...5
    static func clamp(_ value: Int) -> Int { min(max(value, 0), 5) }
}
