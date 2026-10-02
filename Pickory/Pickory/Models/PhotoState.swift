import Foundation
import SwiftData

/// App-local state for one photo, keyed by (source, photo identifier).
///
/// For Dropbox photos this is the source of truth for the rating and the
/// rejected flag. Apple Photos ratings live in PhotoKit; only `isRejected`
/// is used for them.
@Model
final class PhotoState {
    #Unique<PhotoState>([\.sourceRaw, \.photoID])

    var sourceRaw: String
    var photoID: String
    /// Hidden inside this app only. The photo is never deleted.
    var isRejected: Bool
    /// 0–5. Dropbox photos only.
    var rating: Int = 0
    /// When the user last changed this photo. Nil = never (e.g. imported from tags).
    var changedAt: Date?

    init(source: PhotoSourceKind, photoID: String, isRejected: Bool = false, rating: Int = 0) {
        self.sourceRaw = source.rawValue
        self.photoID = photoID
        self.isRejected = isRejected
        self.rating = rating
    }
}
