import Foundation
import SwiftData

/// An image file inside a connected Dropbox folder. Identified by its Dropbox
/// file ID, so ratings follow files that are renamed or moved.
@Model
final class DropboxFile {
    #Unique<DropboxFile>([\.fileID, \.albumID])

    /// Dropbox file ID ("id:…").
    var fileID: String
    /// `ConnectedAlbum.externalID` (the folder's ID) this file belongs to.
    var albumID: String
    /// Display only; never used to look a file up.
    var name: String
    /// Original file size in bytes, from Dropbox.
    var size: Int64
    var serverModified: Date?
    var clientModified: Date?
    var contentHash: String?
    /// File name inside the album's offline folder, once downloaded.
    var localFileName: String?
    /// Raw value of `DownloadQuality` the local copy was downloaded at.
    var localQualityRaw: String?
    /// Bytes on disk for the local copy.
    var localSize: Int64

    init(fileID: String, albumID: String, name: String, size: Int64,
         serverModified: Date?, clientModified: Date?, contentHash: String?) {
        self.fileID = fileID
        self.albumID = albumID
        self.name = name
        self.size = size
        self.serverModified = serverModified
        self.clientModified = clientModified
        self.contentHash = contentHash
        self.localSize = 0
    }

    /// Best guess at when the photo was taken.
    var date: Date? { clientModified ?? serverModified }
}
