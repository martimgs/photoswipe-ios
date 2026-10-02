import Foundation
import SwiftData

/// An album the user connected on the Library screen. Removing one never
/// touches the photos themselves.
@Model
final class ConnectedAlbum {
    #Unique<ConnectedAlbum>([\.sourceRaw, \.externalID])

    var sourceRaw: String
    /// Source-specific album identifier (a PhotoKit local identifier for Apple Photos).
    var externalID: String
    /// Name at connection time; refreshed from the source when available.
    var name: String
    var dateAdded: Date
    /// Where the swipe deck was left, so reopening resumes there.
    var lastIndex: Int

    init(source: PhotoSourceKind, externalID: String, name: String) {
        self.sourceRaw = source.rawValue
        self.externalID = externalID
        self.name = name
        self.dateAdded = .now
        self.lastIndex = 0
    }

    var source: PhotoSourceKind { PhotoSourceKind(rawValue: sourceRaw) ?? .applePhotos }
}
