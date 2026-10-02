import Foundation
import Photos

/// One decision the user made on a photo. Drives the undo stack and the
/// pending-delete set that gets committed at review time.
enum Decision: Equatable {
    case keep
    case trash
    case favorite
    case skip   // decide later — not persisted, reappears next session
    case album(localIdentifier: String, title: String)
    /// Star rating change. `from` is kept so undo restores the exact previous value.
    case rate(RatingStep, from: PHAsset.Rating, to: PHAsset.Rating)
}

/// Which rating gesture was used: right = +1, left = −1, up = straight to 5.
enum RatingStep: Equatable {
    case up, down, max

    func apply(to rating: PHAsset.Rating) -> PHAsset.Rating {
        switch self {
        case .up:   return PHAsset.Rating(rawValue: min(rating.rawValue + 1, 5)) ?? .five
        case .down: return PHAsset.Rating(rawValue: Swift.max(rating.rawValue - 1, 0)) ?? .unset
        case .max:  return .five
        }
    }
}

struct SwipeAction: Identifiable, Equatable {
    let id = UUID()
    let asset: PHAsset
    let decision: Decision

    static func == (lhs: SwipeAction, rhs: SwipeAction) -> Bool {
        lhs.id == rhs.id
    }
}
