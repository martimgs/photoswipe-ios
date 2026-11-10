import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Soft brightness: a tone curve that lifts (or lowers) the midtones like
/// dragging the middle of a Photoshop curve. Black and white stay where they
/// are, so highlights compress instead of clipping.
///
/// Only ever applied to copies in memory or to exported copies, never to
/// the photo itself.
enum BrightnessCurve {
    static let range = -3...3

    /// P3, so wide-gamut colours stay inside the curve's 0–1 range.
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
    ])
    /// Curve bend per step. The largest step's total must stay under 1, or
    /// the curve would stop rising towards white.
    private static let bendPerStep: CGFloat = 0.3

    /// "0", "+1", "-2".
    static func label(_ step: Int) -> String {
        step == 0 ? "0" : String(format: "%+d", step)
    }

    /// Off the main thread, at the image's own size and orientation.
    static func apply(_ step: Int, to image: UIImage) async -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let scale = image.scale, orientation = image.imageOrientation
        return await Task.detached(priority: .userInitiated) {
            render(step, cg).map { UIImage(cgImage: $0, scale: scale, orientation: orientation) }
        }.value
    }

    /// The image with the curve applied. Blocks while it renders.
    static func render(_ step: Int, _ cg: CGImage) -> CGImage? {
        let bend = CGFloat(min(max(step, range.lowerBound), range.upperBound)) * bendPerStep
        func point(_ x: CGFloat) -> CGPoint { CGPoint(x: x, y: x + bend * x * (1 - x)) }
        let input = CIImage(cgImage: cg)
        let filter = CIFilter.toneCurve()
        filter.inputImage = input
        filter.point0 = point(0)
        filter.point1 = point(0.25)
        filter.point2 = point(0.5)
        filter.point3 = point(0.75)
        filter.point4 = point(1)
        guard let output = filter.outputImage,
              let space = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: space)
    }
}
