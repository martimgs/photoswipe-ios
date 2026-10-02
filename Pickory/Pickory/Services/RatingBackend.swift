import Foundation
import SwiftData
import Photos

/// Where an album's ratings and rejected flags are read from and saved to.
@MainActor
protocol RatingBackend {
    func ratings(for items: [PhotoItem]) -> [String: Int]
    func rejectedIDs(for items: [PhotoItem]) -> Set<String>
    /// Persist the photo's new state. `previous` is what it was before.
    func save(_ item: PhotoItem, rating: Int, rejected: Bool, previousRating: Int)
}

/// Apple Photos: ratings live in PhotoKit, rejected flags in SwiftData.
@MainActor
final class ApplePhotosRatingBackend: RatingBackend {
    private let context: ModelContext
    private let service = PhotoLibraryService()
    /// PhotoKit writes run one after another so an undo can't overtake the
    /// write it undoes.
    private var writeChain: Task<Void, Never>?

    init(context: ModelContext) { self.context = context }

    func ratings(for items: [PhotoItem]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.asset.map { (item.id, $0.rating.rawValue) }
        })
    }

    func rejectedIDs(for items: [PhotoItem]) -> Set<String> {
        PhotoStateStore(context: context).rejectedIDs(source: .applePhotos)
    }

    func save(_ item: PhotoItem, rating: Int, rejected: Bool, previousRating: Int) {
        PhotoStateStore(context: context).update(source: .applePhotos, photoID: item.id) {
            $0.isRejected = rejected
        }
        guard rating != previousRating, let asset = item.asset,
              let value = PHAsset.Rating(rawValue: rating) else { return }
        let previous = writeChain
        writeChain = Task { [service] in
            await previous?.value
            try? await service.setRating(asset, value)
        }
    }
}

/// Dropbox: SwiftData is the source of truth. Every change is saved locally
/// first (works offline), then queued to be written to Dropbox as tags.
@MainActor
final class DropboxRatingBackend: RatingBackend {
    private let context: ModelContext
    private let albumID: String

    init(context: ModelContext, albumID: String) {
        self.context = context
        self.albumID = albumID
    }

    func ratings(for items: [PhotoItem]) -> [String: Int] {
        let states = PhotoStateStore(context: context).states(source: .dropbox)
        return states.mapValues(\.rating)
    }

    func rejectedIDs(for items: [PhotoItem]) -> Set<String> {
        PhotoStateStore(context: context).rejectedIDs(source: .dropbox)
    }

    func save(_ item: PhotoItem, rating: Int, rejected: Bool, previousRating: Int) {
        PhotoStateStore(context: context).update(source: .dropbox, photoID: item.id) {
            $0.rating = rating
            $0.isRejected = rejected
            $0.changedAt = .now
        }
        SyncQueue(context: context).enqueue(fileID: item.id, albumID: albumID,
                                           rating: rating, rejected: rejected)
    }
}

/// Small helpers over `PhotoState`.
@MainActor
struct PhotoStateStore {
    let context: ModelContext

    func states(source: PhotoSourceKind) -> [String: PhotoState] {
        let raw = source.rawValue
        let all = (try? context.fetch(FetchDescriptor<PhotoState>(
            predicate: #Predicate { $0.sourceRaw == raw }))) ?? []
        return Dictionary(all.map { ($0.photoID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func rejectedIDs(source: PhotoSourceKind) -> Set<String> {
        let raw = source.rawValue
        let rejected = (try? context.fetch(FetchDescriptor<PhotoState>(
            predicate: #Predicate { $0.sourceRaw == raw && $0.isRejected }))) ?? []
        return Set(rejected.map(\.photoID))
    }

    func state(source: PhotoSourceKind, photoID: String) -> PhotoState? {
        let raw = source.rawValue
        return try? context.fetch(FetchDescriptor<PhotoState>(
            predicate: #Predicate { $0.sourceRaw == raw && $0.photoID == photoID })).first
    }

    func update(source: PhotoSourceKind, photoID: String, _ change: (PhotoState) -> Void) {
        let state = self.state(source: source, photoID: photoID) ?? {
            let s = PhotoState(source: source, photoID: photoID)
            context.insert(s)
            return s
        }()
        change(state)
        try? context.save()
    }
}

/// The pending-sync queue for Dropbox rating tags.
@MainActor
struct SyncQueue {
    let context: ModelContext

    /// Notification posted after an entry is added, so the sync engine can run.
    static let didEnqueue = Notification.Name("SyncQueue.didEnqueue")

    func enqueue(fileID: String, albumID: String, rating: Int, rejected: Bool) {
        if let existing = entry(fileID: fileID) {
            existing.rating = rating
            existing.isRejected = rejected
            existing.changedAt = .now
            existing.attempts = 0
            existing.lastError = nil
        } else {
            context.insert(SyncQueueEntry(fileID: fileID, albumID: albumID,
                                          rating: rating, isRejected: rejected))
        }
        try? context.save()
        NotificationCenter.default.post(name: Self.didEnqueue, object: nil)
    }

    func entry(fileID: String) -> SyncQueueEntry? {
        try? context.fetch(FetchDescriptor<SyncQueueEntry>(
            predicate: #Predicate { $0.fileID == fileID })).first
    }

    func pendingCount(albumID: String) -> Int {
        (try? context.fetchCount(FetchDescriptor<SyncQueueEntry>(
            predicate: #Predicate { $0.albumID == albumID }))) ?? 0
    }

    func all() -> [SyncQueueEntry] {
        (try? context.fetch(FetchDescriptor<SyncQueueEntry>(
            sortBy: [SortDescriptor(\.changedAt)]))) ?? []
    }
}
