import CoreGraphics
import Foundation

/// Instagram shapes offered in the full-screen viewer: feed portrait and
/// square, Stories, and a two-post carousel (two 4:5 halves side by side).
enum CropAspect: String, CaseIterable, Identifiable {
    case portrait = "4:5"
    case square = "1:1"
    case story = "9:16"
    case carousel = "8:5"

    var id: String { rawValue }
    /// Width ÷ height.
    var ratio: CGFloat {
        switch self {
        case .portrait: return 4.0 / 5.0
        case .square:   return 1
        case .story:    return 9.0 / 16.0
        case .carousel: return 8.0 / 5.0
        }
    }
    /// Shown with a dashed line down the middle, where the two posts meet.
    var splitsInTwo: Bool { self == .carousel }
    /// Suffix for the cropped copy's file name ("4x5" — no colon in file names).
    var fileLabel: String { rawValue.replacingOccurrences(of: ":", with: "x") }
}

/// A crop that is only remembered, never applied to the photo. Exports add a
/// cropped copy next to the untouched original.
struct SoftCrop: Equatable {
    let aspect: CropAspect
    /// Normalized (0–1) in the upright photo, origin top-left.
    let rect: CGRect

    /// Same shape and nearly the same framing (ignores sub-pixel scroll drift).
    func isClose(to other: SoftCrop?) -> Bool {
        guard let other, other.aspect == aspect else { return false }
        let t: CGFloat = 0.002
        return abs(rect.minX - other.rect.minX) < t && abs(rect.minY - other.rect.minY) < t
            && abs(rect.width - other.rect.width) < t && abs(rect.height - other.rect.height) < t
    }

    /// The crop in whole pixels for an upright image of `size`, exactly at
    /// the aspect ratio and inside the image.
    func pixelRect(in size: CGSize) -> CGRect {
        // A carousel splits into two halves, so keep its width even.
        let step: CGFloat = aspect.splitsInTwo ? 2 : 1
        var width = ((rect.width * size.width) / step).rounded() * step
        var height = (width / aspect.ratio).rounded()
        if height > size.height {
            height = size.height
            width = ((height * aspect.ratio) / step).rounded(.down) * step
        }
        let x = min(max((rect.minX * size.width).rounded(), 0), size.width - width)
        let y = min(max((rect.minY * size.height).rounded(), 0), size.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
