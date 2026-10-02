import SwiftUI
import SwiftData
import Photos

/// State for one connected album, shared by the swipe and grid screens.
///
/// The current photo is tracked by identifier, not index, so rejecting a
/// photo or changing the rating filter never shifts the deck under the user.
@MainActor
final class AlbumSessionViewModel: ObservableObject {
    enum Phase {
        case loading
        case unavailable   // album no longer exists at its source
        case empty         // album has no photos
        case ready
    }

    let album: ConnectedAlbum

    @Published private(set) var phase: Phase = .loading
    /// Every photo in the album, in album order.
    @Published private(set) var photos: [PHAsset] = []
    /// The photo on the card; nil once the user has gone past the last one.
    @Published var currentID: String?
    /// Minimum star rating to show (0 = any). Always a user choice.
    @Published var minRating = 0
    @Published private(set) var rejectedIDs: Set<String> = []
    @Published private(set) var history: [SwipeAction] = []

    // Ratings written this session. `PHAsset` is an immutable snapshot, so its
    // `rating` goes stale after a write — this map is the source of truth.
    @Published private(set) var ratingOverrides: [String: PHAsset.Rating] = [:]

    private let service = PhotoLibraryService()
    private var context: ModelContext?
    /// Rating writes run one after another so an undo can't overtake the
    /// write it undoes.
    private var writeChain: Task<Void, Never>?

    init(album: ConnectedAlbum) {
        self.album = album
    }

    // MARK: Derived

    func rating(of asset: PHAsset) -> PHAsset.Rating {
        ratingOverrides[asset.localIdentifier] ?? asset.rating
    }

    func isRejected(_ asset: PHAsset) -> Bool {
        rejectedIDs.contains(asset.localIdentifier)
    }

    /// What the swipe deck and filmstrip show: not rejected, at or above the
    /// rating filter.
    var deck: [PHAsset] {
        photos.filter { !isRejected($0) && rating(of: $0).rawValue >= minRating }
    }

    var current: PHAsset? {
        guard let currentID else { return nil }
        return photos.first { $0.localIdentifier == currentID }
    }

    /// The photo after `current` in the deck, for the stacked card behind.
    var next: PHAsset? {
        let d = deck
        guard let currentID, let i = d.firstIndex(where: { $0.localIdentifier == currentID }),
              d.indices.contains(i + 1) else { return nil }
        return d[i + 1]
    }

    /// 1-based position of the current photo in the deck.
    var position: Int? {
        guard let currentID else { return nil }
        return deck.firstIndex { $0.localIdentifier == currentID }.map { $0 + 1 }
    }

    var canUndo: Bool { !history.isEmpty }
    var rejectedPhotos: [PHAsset] { photos.filter(isRejected) }

    // MARK: Load

    func load(context: ModelContext) {
        self.context = context
        guard let collection = service.album(withLocalIdentifier: album.externalID) else {
            phase = .unavailable
            return
        }
        photos = service.photos(in: collection)
        rejectedIDs = loadRejectedIDs()
        guard !photos.isEmpty else { phase = .empty; return }

        // Resume where the user left off, if that photo is still in the deck.
        let d = deck
        if let last = album.lastPhotoID, d.contains(where: { $0.localIdentifier == last }) {
            currentID = last
        } else {
            currentID = d.first?.localIdentifier
        }
        phase = .ready
    }

    // MARK: Navigation

    func jump(to asset: PHAsset) {
        currentID = asset.localIdentifier
        rememberPosition()
    }

    func startOver() {
        currentID = deck.first?.localIdentifier
        rememberPosition()
    }

    /// Re-anchor after the filter changes: stay on the current photo if it
    /// still qualifies, otherwise move to the next one that does.
    func filterChanged() {
        guard let id = currentID else { currentID = deck.first?.localIdentifier; return }
        if !deck.contains(where: { $0.localIdentifier == id }) { currentID = nextInDeck(after: id) }
        rememberPosition()
    }

    // MARK: Decisions

    /// Swipe right/left/up or the heart button: change the rating, then advance.
    func rate(_ step: RatingStep) {
        guard let asset = current else { return }
        let from = rating(of: asset)
        record(.rate(step, from: from, to: step.apply(to: from)), on: asset)
        advance(from: asset)
    }

    /// Star row: set an exact rating and stay on the photo.
    func setRating(_ value: PHAsset.Rating) {
        guard let asset = current else { return }
        let from = rating(of: asset)
        guard from != value else { return }
        record(.rate(.exact(value), from: from, to: value), on: asset)
    }

    /// Swipe down or X: hide the photo in this app (never deletes it), then advance.
    func reject() {
        guard let asset = current else { return }
        record(.reject, on: asset)
        advance(from: asset)
    }

    /// Bring a rejected photo back into the pool (grid's Rejected tab).
    func unreject(_ asset: PHAsset) {
        rejectedIDs.remove(asset.localIdentifier)
        persistRejected(asset.localIdentifier, false)
    }

    func undo() {
        guard let last = history.popLast() else { return }
        Haptics.tap(.medium)
        switch last.decision {
        case .rate(_, let from, let to):
            writeRating(last.asset, from: to, to: from)
        case .reject:
            unreject(last.asset)
        }
        currentID = last.asset.localIdentifier
        rememberPosition()
    }

    private func record(_ decision: Decision, on asset: PHAsset) {
        history.append(SwipeAction(asset: asset, decision: decision))
        switch decision {
        case .rate(_, let from, let to):
            writeRating(asset, from: from, to: to)
        case .reject:
            rejectedIDs.insert(asset.localIdentifier)
            persistRejected(asset.localIdentifier, true)
        }
    }

    private func advance(from asset: PHAsset) {
        currentID = nextInDeck(after: asset.localIdentifier)
        rememberPosition()
    }

    /// The next photo in album order (after `id`) that is in the deck. Works
    /// even when `id` itself just left the deck.
    private func nextInDeck(after id: String) -> String? {
        guard let i = photos.firstIndex(where: { $0.localIdentifier == id }) else { return nil }
        return photos[(i + 1)...].first {
            !isRejected($0) && rating(of: $0).rawValue >= minRating
        }?.localIdentifier
    }

    private func rememberPosition() {
        album.lastPhotoID = currentID
        try? context?.save()
    }

    // MARK: Ratings (PhotoKit)

    private func writeRating(_ asset: PHAsset, from: PHAsset.Rating, to: PHAsset.Rating) {
        ratingOverrides[asset.localIdentifier] = to
        guard from != to else { return }   // e.g. −1 on an unrated photo
        let previous = writeChain
        writeChain = Task { [service] in
            await previous?.value
            try? await service.setRating(asset, to)
        }
    }

    // MARK: Rejected (SwiftData)

    private var sourceRaw: String { album.sourceRaw }

    private func loadRejectedIDs() -> Set<String> {
        guard let context else { return [] }
        let source = sourceRaw
        let descriptor = FetchDescriptor<PhotoState>(
            predicate: #Predicate { $0.sourceRaw == source && $0.isRejected })
        let states = (try? context.fetch(descriptor)) ?? []
        return Set(states.map(\.photoID))
    }

    private func persistRejected(_ photoID: String, _ rejected: Bool) {
        guard let context else { return }
        let source = sourceRaw
        let descriptor = FetchDescriptor<PhotoState>(
            predicate: #Predicate { $0.sourceRaw == source && $0.photoID == photoID })
        if let state = try? context.fetch(descriptor).first {
            state.isRejected = rejected
        } else {
            context.insert(PhotoState(source: album.source, photoID: photoID, isRejected: rejected))
        }
        try? context.save()
    }
}
