import Foundation

/// One decision the user made on a photo. Every case carries what's needed to
/// undo it exactly.
enum Decision: Equatable {
    /// Star rating change. `from` is kept so undo restores the exact previous value.
    case rate(RatingStep, from: Int, to: Int)
    /// Hidden inside this app only and set to 0 stars. Never deletes the
    /// photo. `from` is the rating before, so undo can restore it.
    case reject(from: Int)
}

/// How a rating was changed: right = +1, left = −1, up/heart = pick (5),
/// star row = an exact value.
enum RatingStep: Equatable {
    case up, down, pick
    case exact(Int)

    func apply(to rating: Int) -> Int {
        switch self {
        case .up:   return Stars.clamp(rating + 1)
        case .down: return Stars.clamp(rating - 1)
        case .pick: return 5
        case .exact(let r): return Stars.clamp(r)
        }
    }
}

struct SwipeAction: Identifiable, Equatable {
    let id = UUID()
    let item: PhotoItem
    let decision: Decision

    static func == (lhs: SwipeAction, rhs: SwipeAction) -> Bool {
        lhs.id == rhs.id
    }
}
