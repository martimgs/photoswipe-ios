import Foundation

/// Where an album's photos come from. Stored as a raw string in SwiftData.
enum PhotoSourceKind: String, Codable, CaseIterable {
    case applePhotos
    case dropbox   // planned; not implemented yet
}
