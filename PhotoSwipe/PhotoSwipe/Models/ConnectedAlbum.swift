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
    /// The photo the swipe deck was left on, so reopening resumes there.
    var lastPhotoID: String?

    // MARK: Dropbox only

    /// Lowercased Dropbox path of the folder, refreshed on each check. Used
    /// only to match deleted entries (which carry no ID) and skip subfolders.
    var folderPathLower: String?
    /// `list_folder` cursor for incremental "check for changes".
    var listCursor: String?
    var lastCheckedAt: Date?
    /// Raw value of `OfflineState`.
    var offlineStateRaw: String = OfflineState.onlineOnly.rawValue
    /// Raw value of `DownloadQuality` used for this album's offline copy.
    var offlineQualityRaw: String?

    init(source: PhotoSourceKind, externalID: String, name: String) {
        self.sourceRaw = source.rawValue
        self.externalID = externalID
        self.name = name
        self.dateAdded = .now
    }

    var source: PhotoSourceKind { PhotoSourceKind(rawValue: sourceRaw) ?? .applePhotos }

    var offlineState: OfflineState {
        get { OfflineState(rawValue: offlineStateRaw) ?? .onlineOnly }
        set { offlineStateRaw = newValue.rawValue }
    }
}

/// Whether a Dropbox album's photos are kept on the device.
enum OfflineState: String, Codable {
    case onlineOnly
    case downloading
    case paused
    case offline
}

/// Quality for offline copies of Dropbox photos.
enum DownloadQuality: String, Codable, CaseIterable {
    /// Dropbox-rendered JPEG, max 2048×1536.
    case optimized
    case originals

    var title: String {
        switch self {
        case .optimized: return "Optimized"
        case .originals: return "Originals"
        }
    }
}
