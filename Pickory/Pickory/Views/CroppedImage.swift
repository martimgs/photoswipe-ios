import SwiftUI

/// Part of an uncropped image (a normalized rect), filling a frame of the
/// same aspect ratio. The image itself is never cut.
struct CroppedImage: View {
    let image: UIImage
    let rect: CGRect
    /// Dashed line down the middle (two-post carousel).
    var showsSplit = false

    /// The soft-cropped part, with the carousel line when it applies.
    init(image: UIImage, crop: SoftCrop) {
        self.init(image: image, rect: crop.rect, showsSplit: crop.aspect.splitsInTwo)
    }

    init(image: UIImage, rect: CGRect, showsSplit: Bool = false) {
        self.image = image
        self.rect = rect
        self.showsSplit = showsSplit
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width / rect.width
            let height = geo.size.height / rect.height
            Image(uiImage: image)
                .resizable()
                .frame(width: width, height: height)
                .offset(x: -rect.minX * width, y: -rect.minY * height)
        }
        .clipped()
        .overlay { if showsSplit { CarouselSplitLine() } }
    }
}

/// Dashed line down the middle of an 8:5 crop: where a two-post carousel cuts.
struct CarouselSplitLine: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
            }
            .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .shadow(color: .black.opacity(0.4), radius: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Small crop-icon + "4:5" chip marking a photo that has a soft crop.
struct CropBadge: View {
    let aspect: CropAspect

    var body: some View {
        Label(aspect.rawValue, systemImage: "crop")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(6)
            .accessibilityLabel("Cropped \(aspect.rawValue)")
    }
}
