import SwiftUI
import Photos

@MainActor
final class SwipeDeckViewModel: ObservableObject {
    enum Phase {
        case loading
        case permissionDenied
        case empty
        case swiping
        case done
    }

    @Published var phase: Phase = .loading
    @Published private(set) var assets: [PHAsset] = []
    @Published var index: Int = 0
    @Published private(set) var history: [SwipeAction] = []
    @Published private(set) var rejectedIDs: Set<String> = []

    // Ratings written this session. `PHAsset` is an immutable snapshot, so its
    // `rating` goes stale after a write — this map is the source of truth.
    @Published private(set) var ratingOverrides: [String: PHAsset.Rating] = [:]

    private let service = PhotoLibraryService()

    // MARK: Derived

    var current: PHAsset? { peek(0) }
    func peek(_ offset: Int) -> PHAsset? {
        let i = index + offset
        return assets.indices.contains(i) ? assets[i] : nil
    }
    var remaining: Int { max(assets.count - index, 0) }
    var progress: Double { assets.isEmpty ? 0 : Double(index) / Double(assets.count) }
    var canUndo: Bool { !history.isEmpty }

    func rating(of asset: PHAsset) -> PHAsset.Rating {
        ratingOverrides[asset.localIdentifier] ?? asset.rating
    }

    // MARK: Bootstrap

    func bootstrap() async {
        switch service.authorizationStatus() {
        case .authorized, .limited:
            loadLibrary()
        case .notDetermined:
            let s = await service.requestAuthorization()
            if s == .authorized || s == .limited { loadLibrary() } else { phase = .permissionDenied }
        default:
            phase = .permissionDenied
        }
    }

    private func loadLibrary() {
        assets = service.fetchAllPhotos()
        index = 0
        history = []
        phase = assets.isEmpty ? .empty : .swiping
    }

    // MARK: Decisions

    func rate(_ step: RatingStep) {
        guard let asset = current else { return }
        let from = rating(of: asset)
        decide(.rate(step, from: from, to: step.apply(to: from)))
    }

    func reject() { decide(.reject) }

    private func decide(_ decision: Decision) {
        guard let asset = current else { return }
        history.append(SwipeAction(asset: asset, decision: decision))
        switch decision {
        case .rate(_, let from, let to):
            setRating(asset, from: from, to: to)
        case .reject:
            rejectedIDs.insert(asset.localIdentifier)
        }
        advance()
    }

    private func advance() {
        if index + 1 >= assets.count {
            index = assets.count
            phase = .done
        } else {
            index += 1
        }
    }

    func undo() {
        guard let last = history.popLast() else { return }
        if phase == .done { phase = .swiping }
        index = max(index - 1, 0)
        Haptics.tap(.medium)
        switch last.decision {
        case .rate(_, let from, let to):
            setRating(last.asset, from: to, to: from)
        case .reject:
            rejectedIDs.remove(last.asset.localIdentifier)
        }
    }

    private func setRating(_ asset: PHAsset, from: PHAsset.Rating, to: PHAsset.Rating) {
        ratingOverrides[asset.localIdentifier] = to
        guard from != to else { return }   // e.g. −1 on an unrated photo
        Task { try? await service.setRating(asset, to) }
    }
}
