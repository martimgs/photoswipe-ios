import SwiftUI

/// The soft-cropped part of an uncropped image, filling a frame of the
/// crop's aspect ratio. The image itself is never cut.
struct CroppedImage: View {
    let image: UIImage
    let crop: SoftCrop

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width / crop.rect.width
            let height = geo.size.height / crop.rect.height
            Image(uiImage: image)
                .resizable()
                .frame(width: width, height: height)
                .offset(x: -crop.rect.minX * width, y: -crop.rect.minY * height)
        }
        .clipped()
        .overlay { if crop.aspect.splitsInTwo { CarouselSplitLine() } }
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
