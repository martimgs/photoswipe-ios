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

    init(asset: PHAsset) {
        id = asset.localIdentifier
        source = .applePhotos
        date = asset.creationDate
        self.asset = asset
    }

    init(dropboxFileID: String, date: Date?) {
        id = dropboxFileID
        source = .dropbox
        self.date = date
        asset = nil
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
