import Foundation

/// How many photos of an album or folder have each star rating (1–5).
/// Unrated and rejected photos aren't counted.
struct RatingTally: Equatable, Sendable {
    private var counts = [0, 0, 0, 0, 0]

    mutating func add(rating: Int) {
        guard (1...5).contains(rating) else { return }
        counts[rating - 1] += 1
    }

    /// Only the star levels that have photos, lowest first.
    var levels: [(stars: Int, count: Int)] {
        counts.enumerated().compactMap { $1 > 0 ? (stars: $0 + 1, count: $1) : nil }
    }
}
