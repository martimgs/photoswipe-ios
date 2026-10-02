import Foundation
import SwiftData

/// App-local state for one photo, keyed by (source, photo identifier) so
/// Dropbox photos can share the model later. Star ratings for Apple Photos
/// live in PhotoKit, not here.
@Model
final class PhotoState {
    #Unique<PhotoState>([\.sourceRaw, \.photoID])

    var sourceRaw: String
    var photoID: String
    /// Hidden inside this app only. The photo is never deleted.
    var isRejected: Bool

    init(source: PhotoSourceKind, photoID: String, isRejected: Bool = false) {
        self.sourceRaw = source.rawValue
        self.photoID = photoID
        self.isRejected = isRejected
    }
}
