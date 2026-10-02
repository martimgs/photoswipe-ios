import Foundation
import Photos

/// One decision the user made on a photo. Every case carries what's needed to
/// undo it exactly.
enum Decision: Equatable {
    /// Star rating change. `from` is kept so undo restores the exact previous value.
    case rate(RatingStep, from: PHAsset.Rating, to: PHAsset.Rating)
    /// Hidden inside this app only and set to 0 stars. Never deletes the
    /// photo. `from` is the rating before, so undo can restore it.
    case reject(from: PHAsset.Rating)
}

/// How a rating was changed: right = +1, left = −1, up/heart = pick (5),
/// star row = an exact value.
enum RatingStep: Equatable {
    case up, down, pick
    case exact(PHAsset.Rating)

    func apply(to rating: PHAsset.Rating) -> PHAsset.Rating {
        switch self {
        case .up:   return PHAsset.Rating(rawValue: min(rating.rawValue + 1, 5)) ?? .five
        case .down: return PHAsset.Rating(rawValue: max(rating.rawValue - 1, 0)) ?? .unset
        case .pick: return .five
        case .exact(let r): return r
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
