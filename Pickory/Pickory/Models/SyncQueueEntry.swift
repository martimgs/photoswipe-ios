import Foundation
import SwiftData

/// A rating change waiting to be written to Dropbox as tags. One entry per
/// photo: a newer change overwrites the older one, so the newest change wins.
@Model
final class SyncQueueEntry {
    #Unique<SyncQueueEntry>([\.fileID])

    var fileID: String
    var albumID: String
    var rating: Int
    var isRejected: Bool
    var changedAt: Date
    var attempts: Int
    var lastError: String?

    init(fileID: String, albumID: String, rating: Int, isRejected: Bool) {
        self.fileID = fileID
        self.albumID = albumID
        self.rating = rating
        self.isRejected = isRejected
        self.changedAt = .now
        self.attempts = 0
    }
}
