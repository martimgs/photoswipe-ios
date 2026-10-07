import SwiftUI
import SwiftData
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Full-screen, uncropped view of one photo. Pinch or double-tap to zoom,
/// drag to pan when zoomed, X to close.
///
/// Review tools along the bottom:
/// - Exposure −1 / +1 (one stop each). Preview only, never saved.
/// - Instagram crop 4:5 / 1:1 / 9:16 (Stories) / 8:5 (two-post carousel,
///   dashed line where it splits). The button sticks; drag and pinch the photo
///   inside the frame. On close, the crop can be saved as a soft crop: the
///   photo itself is never changed, exports add a cropped copy.
struct FullScreenPhotoView: View {
    let item: PhotoItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.modelContext) private var context
    @State private var original: UIImage?
    /// `original` with the exposure preview applied.
    @State private var shown: UIImage?
    /// Preview brightness in stops. Never saved.
    @State private var exposure = 0
    @State private var aspect: CropAspect?
    /// The soft crop stored for this photo when the viewer opened.
    @State private var saved: SoftCrop?
    @State private var tracker = CropTracker()
    @State private var prompt: Prompt?
    /// Height of the bottom controls, kept clear of the crop frame.
    @State private var controlsHeight: CGFloat = 60

    private static let exposureRange = -3...3

    private enum Prompt { case save, remove }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let shown {
                PhotoCanvasView(image: shown, aspect: aspect, initialCrop: saved,
                                bottomReserve: controlsHeight) { tracker.crop = $0 }
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottom) { if shown != nil { controls } }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .alert("Save Crop?", isPresented: isPrompting(.save)) {
            Button("Save") { save(tracker.crop) }
            Button("Don't Save", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved as a soft crop: the photo itself isn't changed. Exports add a cropped copy.")
        }
        .alert("Remove Saved Crop?", isPresented: isPrompting(.remove)) {
            Button("Remove", role: .destructive) { save(nil) }
            Button("Keep Crop") { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photo itself isn't changed either way.")
        }
        .task(id: item.id) {
            saved = PhotoStateStore(context: context).state(source: item.source, photoID: item.id)?.softCrop
            aspect = saved?.aspect
            // Higher resolution than the card so zooming stays sharp.
            let bounds = UIScreen.current?.bounds.size ?? CGSize(width: 1024, height: 1024)
            let side = max(bounds.width, bounds.height) * displayScale * 2
            original = await ImageLoader.shared.image(for: item, pixelSize: CGSize(width: side, height: side), fill: false)
            shown = original
        }
        .task(id: exposure) {
            guard let original else { return }
            if exposure == 0 { shown = original; return }
            if let adjusted = await ExposurePreview.apply(Float(exposure), to: original), !Task.isCancelled {
                shown = adjusted
            }
        }
    }

    // MARK: Controls

    /// One row when it fits, otherwise exposure above crop (narrow phones).
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s) { exposureControls; cropControls }
            VStack(spacing: Spacing.xs) { exposureControls; cropControls }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.m)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
    }

    private var exposureControls: some View {
        HStack(spacing: 0) {
            controlButton("−1", label: "Darker", enabled: exposure > Self.exposureRange.lowerBound) {
                exposure -= 1
            }
            Button { exposure = 0 } label: {
                Text(exposureLabel)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(exposure == 0 ? .white.opacity(0.6) : .white)
                    .frame(minWidth: 52, minHeight: 44)
            }
            .accessibilityLabel("Exposure \(exposureLabel)")
            .accessibilityHint("Resets the exposure preview")
            controlButton("+1", label: "Brighter", enabled: exposure < Self.exposureRange.upperBound) {
                exposure += 1
            }
        }
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var cropControls: some View {
        HStack(spacing: 0) {
            ForEach(CropAspect.allCases) { a in
                Button {
                    Haptics.tap()
                    aspect = aspect == a ? nil : a
                } label: {
                    Text(a.rawValue)
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(aspect == a ? .black : .white)
                        .frame(width: 48, height: 36)
                        .background(aspect == a ? Color.white : .clear, in: Capsule())
                        .padding(4)
                }
                .accessibilityLabel(a.splitsInTwo ? "Crop \(a.rawValue), two-post carousel" : "Crop \(a.rawValue)")
                .accessibilityAddTraits(aspect == a ? .isSelected : [])
            }
        }
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func controlButton(_ title: String, label: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                .frame(width: 48, height: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var exposureLabel: String {
        exposure == 0 ? "0 EV" : String(format: "%+d EV", exposure)
    }

    // MARK: Closing

    private func close() {
        guard shown != nil else { dismiss(); return }
        if aspect != nil, let crop = tracker.crop {
            if crop.isClose(to: saved) { dismiss() } else { prompt = .save }
        } else if aspect == nil, saved != nil {
            prompt = .remove
        } else {
            dismiss()
        }
    }

    private func save(_ crop: SoftCrop?) {
        PhotoStateStore(context: context).update(source: item.source, photoID: item.id) {
            $0.softCrop = crop
        }
        if crop != nil { Haptics.success() }
        dismiss()
    }

    private func isPrompting(_ p: Prompt) -> Binding<Bool> {
        Binding(get: { prompt == p }, set: { if !$0 { prompt = nil } })
    }
}

/// Latest framing reported by the canvas. A plain class so scrolling doesn't
/// re-render the SwiftUI view on every frame.
private final class CropTracker {
    var crop: SoftCrop?
}

/// Review-only brightness: Core Image exposure adjust, rendered off the main
/// thread at the image's own size so zoom and crop framing are untouched.
private enum ExposurePreview {
    private static let context = CIContext()

    static func apply(_ ev: Float, to image: UIImage) async -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let scale = image.scale, orientation = image.imageOrientation
        return await Task.detached(priority: .userInitiated) {
            let input = CIImage(cgImage: cg)
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = input
            filter.ev = ev
            guard let output = filter.outputImage,
                  let space = CGColorSpace(name: CGColorSpace.displayP3),
                  let rendered = context.createCGImage(output, from: input.extent,
                                                       format: .RGBA8, colorSpace: space)
            else { return nil }
            return UIImage(cgImage: rendered, scale: scale, orientation: orientation)
        }.value
    }
}

private extension UIScreen {
    /// The screen of the active window scene (`UIScreen.main` is deprecated).
    @MainActor static var current: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.screen
    }
}

// MARK: - Canvas

private struct PhotoCanvasView: UIViewRepresentable {
    let image: UIImage
    let aspect: CropAspect?
    /// Framing to start from the first time its aspect is shown.
    let initialCrop: SoftCrop?
    /// Space the controls take at the bottom (above the safe area).
    let bottomReserve: CGFloat
    let onCrop: (SoftCrop?) -> Void

    func makeUIView(context: Context) -> PhotoCanvas {
        let view = PhotoCanvas()
        if let initialCrop { view.remember(initialCrop) }
        return view
    }

    func updateUIView(_ view: PhotoCanvas, context: Context) {
        view.onCrop = onCrop
        view.bottomReserve = bottomReserve
        view.setImage(image)
        view.setAspect(aspect)
    }
}

/// UIScrollView-backed zooming: smooth pinch, pan and double-tap, and the
/// photo stays centered and fully visible at minimum zoom.
///
/// With a crop aspect the photo instead fills a fixed frame: the scroll
/// view's content insets equal the margins around the frame, so the photo
/// can be dragged until its edge meets the frame's edge, never further.
private final class PhotoCanvas: UIView, UIScrollViewDelegate {
    var onCrop: ((SoftCrop?) -> Void)?
    var bottomReserve: CGFloat = 60 {
        didSet { if bottomReserve != oldValue { setNeedsLayout() } }
    }

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let overlay = CropMaskView()
    private var aspect: CropAspect?
    /// Last framing per aspect, so switching 4:5 → 1:1 → 4:5 comes back to it.
    private var framings: [CropAspect: CGRect] = [:]
    private var fitted: FitKey?

    private struct FitKey: Equatable {
        var bounds: CGSize
        var image: CGSize
        var crop: CGRect?
        var aspect: CropAspect?
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        addSubview(scrollView)
        overlay.isUserInteractionEnabled = false
        overlay.alpha = 0
        addSubview(overlay)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    func remember(_ crop: SoftCrop) { framings[crop.aspect] = crop.rect }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        setNeedsLayout()
    }

    func setAspect(_ aspect: CropAspect?) {
        guard aspect != self.aspect else { return }
        if let old = self.aspect, let rect = currentCropRect() { framings[old] = rect }
        self.aspect = aspect
        UIView.animate(withDuration: 0.2) { self.overlay.alpha = aspect == nil ? 0 : 1 }
        setNeedsLayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        overlay.frame = bounds
        // Re-fit on first layout, rotation, a new image size or a crop change.
        let key = FitKey(bounds: bounds.size, image: imageView.image?.size ?? .zero, crop: cropFrame, aspect: aspect)
        if key != fitted {
            // Keep the framing across rotation.
            if fitted?.aspect == aspect, let aspect, let rect = currentCropRect() { framings[aspect] = rect }
            fitted = key
            fit()
        }
    }

    /// The crop frame on screen, clear of the close button and the controls.
    private var cropFrame: CGRect? {
        guard let aspect else { return nil }
        let area = bounds.inset(by: UIEdgeInsets(top: safeAreaInsets.top + 72,
                                                 left: safeAreaInsets.left + 16,
                                                 bottom: safeAreaInsets.bottom + bottomReserve + 12,
                                                 right: safeAreaInsets.right + 16))
        guard area.width > 0, area.height > 0 else { return nil }
        let width = min(area.width, area.height * aspect.ratio)
        let height = width / aspect.ratio
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    private func fit() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let crop = cropFrame
        overlay.cropFrame = crop
        overlay.splitsInTwo = aspect?.splitsInTwo ?? false
        scrollView.minimumZoomScale = 1
        scrollView.zoomScale = 1
        let target = crop ?? bounds
        let scale = crop == nil
            ? min(target.width / image.size.width, target.height / image.size.height)
            : max(target.width / image.size.width, target.height / image.size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        scrollView.contentSize = imageView.frame.size
        scrollView.maximumZoomScale = max(4, maxNativeZoom())

        guard let crop, let aspect else {
            centerImage()
            onCrop?(nil)
            return
        }
        scrollView.contentInset = UIEdgeInsets(top: crop.minY, left: crop.minX,
                                               bottom: bounds.height - crop.maxY,
                                               right: bounds.width - crop.maxX)
        if let rect = framings[aspect], rect.width > 0 {
            let zoom = crop.width / (rect.width * imageView.bounds.width)
            scrollView.zoomScale = min(max(zoom, 1), scrollView.maximumZoomScale)
            let size = imageView.frame.size
            scrollView.contentOffset = clampedOffset(CGPoint(x: rect.minX * size.width - crop.minX,
                                                             y: rect.minY * size.height - crop.minY))
        } else {
            let size = imageView.frame.size
            scrollView.contentOffset = CGPoint(x: (size.width - crop.width) / 2 - crop.minX,
                                               y: (size.height - crop.height) / 2 - crop.minY)
        }
        reportCrop()
    }

    private func clampedOffset(_ p: CGPoint) -> CGPoint {
        let inset = scrollView.contentInset
        let size = scrollView.contentSize
        return CGPoint(
            x: min(max(p.x, -inset.left), size.width + inset.right - bounds.width),
            y: min(max(p.y, -inset.top), size.height + inset.bottom - bounds.height))
    }

    /// The part of the photo inside the frame, normalized to 0–1.
    private func currentCropRect() -> CGRect? {
        guard let crop = overlay.cropFrame, aspect != nil else { return nil }
        let f = imageView.frame
        guard f.width > 0, f.height > 0 else { return nil }
        let x = (scrollView.contentOffset.x + crop.minX - f.minX) / f.width
        let y = (scrollView.contentOffset.y + crop.minY - f.minY) / f.height
        let rect = CGRect(x: x, y: y, width: crop.width / f.width, height: crop.height / f.height)
        return rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func reportCrop() {
        guard let aspect, let rect = currentCropRect() else { return }
        onCrop?(SoftCrop(aspect: aspect, rect: rect))
    }

    /// Zoom up to the photo's own pixel size (at least 4x).
    private func maxNativeZoom() -> CGFloat {
        guard let image = imageView.image, imageView.bounds.width > 0 else { return 4 }
        return image.size.width * image.scale / (imageView.bounds.width * traitCollection.displayScale) * 2
    }

    private func centerImage() {
        let dx = max(0, (bounds.width - scrollView.contentSize.width) / 2)
        let dy = max(0, (bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if aspect == nil { centerImage() } else { reportCrop() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if aspect != nil { reportCrop() }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale * 1.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let target = min(scrollView.maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }
}

/// Dims everything outside the crop frame, with a thin border and
/// rule-of-thirds lines inside it. A two-post carousel crop gets a dashed
/// line where the posts meet instead of the thirds.
private final class CropMaskView: UIView {
    var cropFrame: CGRect? { didSet { setNeedsDisplay() } }
    var splitsInTwo = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let crop = cropFrame, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addRect(bounds)
        ctx.addRect(crop)
        ctx.fillPath(using: .evenOdd)

        if splitsInTwo {
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [6, 5])
            ctx.move(to: CGPoint(x: crop.midX, y: crop.minY)); ctx.addLine(to: CGPoint(x: crop.midX, y: crop.maxY))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        } else {
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(0.5)
            for i in 1...2 {
                let x = crop.minX + crop.width * CGFloat(i) / 3
                let y = crop.minY + crop.height * CGFloat(i) / 3
                ctx.move(to: CGPoint(x: x, y: crop.minY)); ctx.addLine(to: CGPoint(x: x, y: crop.maxY))
                ctx.move(to: CGPoint(x: crop.minX, y: y)); ctx.addLine(to: CGPoint(x: crop.maxX, y: y))
            }
            ctx.strokePath()
        }

        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(crop.insetBy(dx: 0.5, dy: 0.5))
    }
}
