import SwiftUI
import UIKit

/// Full-screen, uncropped view of one photo. Pinch or double-tap to zoom,
/// drag to pan when zoomed, X to close.
struct FullScreenPhotoView: View {
    let item: PhotoItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImage(image: image)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        .statusBarHidden()
        .task(id: item.id) {
            // Higher resolution than the card so zooming stays sharp.
            let bounds = UIScreen.current?.bounds.size ?? CGSize(width: 1024, height: 1024)
            let side = max(bounds.width, bounds.height) * displayScale * 2
            image = await ImageLoader.shared.image(for: item, pixelSize: CGSize(width: side, height: side), fill: false)
        }
    }
}

private extension UIScreen {
    /// The screen of the active window scene (`UIScreen.main` is deprecated).
    @MainActor static var current: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.screen
    }
}

/// UIScrollView-backed zooming: smooth pinch, pan and double-tap, and the
/// photo stays centered and fully visible at minimum zoom.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView(image: image)
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.setImage(image)
    }
}

private final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        setImage(image)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        setNeedsLayout()
    }

    private var lastBounds: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // Re-fit on first layout and on rotation.
        if bounds.size != lastBounds {
            lastBounds = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fittedSize())
            contentSize = imageView.frame.size
            minimumZoomScale = 1
            maximumZoomScale = max(4, maxNativeZoom())
        }
        centerImage()
    }

    /// Image size that fits the screen at zoom 1.
    private func fittedSize() -> CGSize {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds.size }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    /// Zoom up to the photo's own pixel size (at least 4x).
    private func maxNativeZoom() -> CGFloat {
        guard let image = imageView.image, imageView.frame.width > 0 else { return 4 }
        return image.size.width * image.scale / (imageView.frame.width * traitCollection.displayScale) * 2
    }

    private func centerImage() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let target = min(maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}
