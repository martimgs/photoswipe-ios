import SwiftUI
import SwiftData

/// State for one connected album, shared by the swipe and grid screens.
///
/// The current photo is tracked by identifier, not index, so rejecting a
/// photo or changing the rating filter never shifts the deck under the user.
/// Ratings and rejected flags are saved through the album's `RatingBackend`
/// (PhotoKit for Apple Photos, SwiftData + sync queue for Dropbox).
@MainActor
final class AlbumSessionViewModel: ObservableObject {
    enum Phase {
        case loading
        case unavailable   // album no longer exists at its source
        case empty         // album has no photos
        case ready
    }

    let album: ConnectedAlbum
    /// Subfolder this session is limited to (Dropbox), nil = whole album.
    let folder: String?

    /// Header title: the subfolder's name, or the album's.
    var title: String {
        guard let folder, let last = folder.split(separator: "/").last else { return album.name }
        return String(last)
    }

    @Published private(set) var phase: Phase = .loading
    /// Every photo in the album, in album order.
    @Published private(set) var photos: [PhotoItem] = []
    /// The photo on the card; nil once the user has gone past the last one.
    @Published var currentID: String?
    /// Minimum star rating to show (0 = all). Always a user choice.
    @Published var minRating = 0
    @Published private(set) var rejectedIDs: Set<String> = []
    @Published private(set) var ratings: [String: Int] = [:]
    @Published private(set) var history: [SwipeAction] = []

    private var context: ModelContext?
    private var backend: RatingBackend?

    init(album: ConnectedAlbum, folder: String? = nil) {
        self.album = album
        self.folder = folder
    }

    // MARK: Derived

    func rating(of item: PhotoItem) -> Int { ratings[item.id] ?? 0 }

    func isRejected(_ item: PhotoItem) -> Bool { rejectedIDs.contains(item.id) }

    /// What the swipe deck and filmstrip show: not rejected, at or above the
    /// rating filter.
    var deck: [PhotoItem] {
        photos.filter { !isRejected($0) && rating(of: $0) >= minRating }
    }

    var current: PhotoItem? {
        guard let currentID else { return nil }
        return photos.first { $0.id == currentID }
    }

    /// The photo after `current` in the deck, for the stacked card behind.
    var next: PhotoItem? {
        let d = deck
        guard let currentID, let i = d.firstIndex(where: { $0.id == currentID }),
              d.indices.contains(i + 1) else { return nil }
        return d[i + 1]
    }

    /// 1-based position of the current photo in the deck.
    var position: Int? {
        guard let currentID else { return nil }
        return deck.firstIndex { $0.id == currentID }.map { $0 + 1 }
    }

    var canUndo: Bool { !history.isEmpty }
    var rejectedPhotos: [PhotoItem] { photos.filter(isRejected) }

    // MARK: Load

    func load(context: ModelContext) {
        self.context = context
        switch album.source {
        case .applePhotos:
            let service = PhotoLibraryService()
            guard let collection = service.album(withLocalIdentifier: album.externalID) else {
                phase = .unavailable
                return
            }
            photos = service.photos(in: collection).map(PhotoItem.init(asset:))
            backend = ApplePhotosRatingBackend(context: context)
        case .dropbox:
            photos = Self.dropboxItems(albumID: album.externalID, context: context)
                .filter { $0.isInFolder(folder) }
            backend = DropboxRatingBackend(context: context, albumID: album.externalID)
        }
        reloadState()
        guard !photos.isEmpty else { phase = .empty; return }

        // Resume where the user left off, if that photo is still in the deck.
        let d = deck
        if let last = album.lastPhotoID, d.contains(where: { $0.id == last }) {
            currentID = last
        } else {
            currentID = d.first?.id
        }
        phase = .ready
    }

    /// Re-read the album's files after a Dropbox "check for changes".
    func reloadPhotos() {
        guard let context, album.source == .dropbox else { return }
        photos = Self.dropboxItems(albumID: album.externalID, context: context)
            .filter { $0.isInFolder(folder) }
        reloadState()
        if currentID == nil || !photos.contains(where: { $0.id == currentID }) {
            currentID = deck.first?.id
        }
        phase = photos.isEmpty ? .empty : .ready
    }

    private func reloadState() {
        guard let backend else { return }
        ratings = backend.ratings(for: photos)
        rejectedIDs = backend.rejectedIDs(for: photos).intersection(photos.map(\.id))
    }

    static func dropboxItems(albumID: String, context: ModelContext) -> [PhotoItem] {
        let files = (try? context.fetch(FetchDescriptor<DropboxFile>(
            predicate: #Predicate { $0.albumID == albumID }))) ?? []
        // Grouped by subfolder (top level first, then folders A–Z), then by date.
        return files
            .sorted { a, b in
                if a.folderPath != b.folderPath {
                    if a.folderPath.isEmpty || b.folderPath.isEmpty { return a.folderPath.isEmpty }
                    return a.folderPath.localizedStandardCompare(b.folderPath) == .orderedAscending
                }
                return (a.date ?? .distantPast, a.name) < (b.date ?? .distantPast, b.name)
            }
            .map { PhotoItem(dropboxFileID: $0.fileID, date: $0.date, folder: $0.folderPath) }
    }

    // MARK: Navigation

    func jump(to item: PhotoItem) {
        currentID = item.id
        rememberPosition()
    }

    func startOver() {
        currentID = deck.first?.id
        rememberPosition()
    }

    /// Re-anchor after the filter changes: stay on the current photo if it
    /// still qualifies, otherwise move to the next one that does.
    func filterChanged() {
        guard let id = currentID else { currentID = deck.first?.id; return }
        if !deck.contains(where: { $0.id == id }) { currentID = nextInDeck(after: id) }
        rememberPosition()
    }

    // MARK: Decisions

    /// Swipe right/left/up or the heart button: change the rating, then advance.
    func rate(_ step: RatingStep) {
        guard let item = current else { return }
        let from = rating(of: item)
        record(.rate(step, from: from, to: step.apply(to: from)), on: item)
        advance(from: item)
    }

    /// Star row: set an exact rating and stay on the photo.
    func setRating(_ value: Int) {
        guard let item = current else { return }
        let from = rating(of: item)
        guard from != value else { return }
        record(.rate(.exact(value), from: from, to: value), on: item)
    }

    /// Swipe down or X: set to 0 stars and hide the photo in this app (never
    /// deletes it), then advance.
    func reject() {
        guard let item = current else { return }
        record(.reject(from: rating(of: item)), on: item)
        advance(from: item)
    }

    /// Bring a rejected photo back into the pool (grid's Rejected tab). It
    /// stays at 0 stars; only Undo restores the earlier rating.
    func unreject(_ item: PhotoItem) {
        apply(item, rating: rating(of: item), rejected: false)
    }

    func undo() {
        guard let last = history.popLast() else { return }
        Haptics.tap(.medium)
        switch last.decision {
        case .rate(_, let from, _):
            apply(last.item, rating: from, rejected: isRejected(last.item))
        case .reject(let from):
            apply(last.item, rating: from, rejected: false)
        }
        currentID = last.item.id
        rememberPosition()
    }

    private func record(_ decision: Decision, on item: PhotoItem) {
        history.append(SwipeAction(item: item, decision: decision))
        switch decision {
        case .rate(_, _, let to):
            apply(item, rating: to, rejected: isRejected(item))
        case .reject:
            apply(item, rating: 0, rejected: true)
        }
    }

    /// Update in memory, then persist through the backend.
    private func apply(_ item: PhotoItem, rating: Int, rejected: Bool) {
        let previous = self.rating(of: item)
        ratings[item.id] = rating
        if rejected { rejectedIDs.insert(item.id) } else { rejectedIDs.remove(item.id) }
        backend?.save(item, rating: rating, rejected: rejected, previousRating: previous)
    }

    private func advance(from item: PhotoItem) {
        currentID = nextInDeck(after: item.id)
        rememberPosition()
    }

    /// The next photo in album order (after `id`) that is in the deck. Works
    /// even when `id` itself just left the deck.
    private func nextInDeck(after id: String) -> String? {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return nil }
        return photos[(i + 1)...].first {
            !isRejected($0) && rating(of: $0) >= minRating
        }?.id
    }

    private func rememberPosition() {
        album.lastPhotoID = currentID
        try? context?.save()
    }
}
