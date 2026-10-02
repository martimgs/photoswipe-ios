import SwiftUI

/// A Photos-app-style scrubber: a thin strip of narrow slivers with the
/// current photo shown wider in the middle. Drag along it to move through
/// the photos (the photo under the center becomes current, with momentum
/// after a flick); tap a sliver to jump to it.
///
/// Not a ScrollView: the strip is laid out from one continuous `position`
/// (in photos) that only the finger drives, so the wider current sliver can
/// never shift the content and feed back into which photo is current.
struct FilmstripView: View {
    let photos: [PhotoItem]
    let currentID: String?
    let onSelect: (PhotoItem) -> Void
    /// True from touch-down until the strip comes to rest after a flick.
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    static let height: CGFloat = 44
    private let sliver: CGFloat = 22
    private let gap: CGFloat = 2
    private var step: CGFloat { sliver + gap }
    private var extra: CGFloat { Self.height - sliver }

    @State private var position: Double = 0
    @State private var reported: Int?
    @State private var dragStart: Double?
    @State private var momentum: Task<Void, Never>?
    @State private var scrubbing = false

    private var currentIndex: Int? {
        guard let currentID else { return nil }
        return photos.firstIndex { $0.id == currentID }
    }

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            let range = visibleRange(width: geo.size.width)
            let center = Int(position.rounded())
            ZStack {
                ForEach(range, id: \.self) { i in
                    let slot = layout(i)
                    Thumbnail(item: photos[i], side: Self.height, cornerRadius: 0)
                        .frame(width: slot.width, height: Self.height)
                        .clipped()
                        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: i == center ? 2 : 0))
                        .position(x: mid + slot.x, y: Self.height / 2)
                }
            }
            .frame(width: geo.size.width, height: Self.height)
            .contentShape(Rectangle())
            .onTapGesture { location in tap(atX: location.x - mid, in: range) }
            .gesture(dragGesture)
        }
        .frame(height: Self.height)
        .clipped()
        .onChange(of: currentID, initial: true) { old, _ in follow(animated: old != currentID) }
        .onChange(of: photos) { follow(animated: false) }
        .accessibilityElement()
        .accessibilityLabel("Photo strip")
        .accessibilityValue(currentIndex.map { "\($0 + 1) of \(photos.count)" } ?? "")
        .accessibilityAdjustableAction { direction in
            guard let i = currentIndex else { return }
            let target = direction == .increment ? i + 1 : i - 1
            if photos.indices.contains(target) { select(target); position = Double(target) }
        }
    }

    // MARK: Layout

    private func visibleRange(width: CGFloat) -> Range<Int> {
        let half = Int(width / step / 2) + 3
        let center = Int(position.rounded())
        let lo = max(0, center - half)
        let hi = min(photos.count, center + half + 1)
        return lo..<max(lo, hi)
    }

    /// How "current" sliver `i` is (0…1). Only the two photos either side of
    /// `position` are partly current, so the wide slot slides smoothly.
    private func weight(_ i: Int) -> CGFloat {
        max(0, 1 - abs(CGFloat(i) - CGFloat(position)))
    }

    /// Center offset from the strip's middle, and width, of sliver `i`.
    private func layout(_ i: Int) -> (x: CGFloat, width: CGFloat) {
        let below = Int(position.rounded(.down))
        var left: CGFloat = 0, right: CGFloat = 0
        for j in [below, below + 1] where j != i && photos.indices.contains(j) {
            if j < i { left += weight(j) } else { right += weight(j) }
        }
        let x = (CGFloat(i) - CGFloat(position)) * step + extra * (left - right) / 2
        return (x, sliver + extra * weight(i))
    }

    // MARK: Interaction

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil {
                    momentum?.cancel()
                    dragStart = position
                    setScrubbing(true)
                }
                move(to: (dragStart ?? position) - Double(value.translation.width / step))
            }
            .onEnded { value in
                dragStart = nil
                coast(velocity: -Double(value.velocity.width / step))
            }
    }

    private func tap(atX x: CGFloat, in range: Range<Int>) {
        guard let i = range.first(where: {
            let slot = layout($0)
            return abs(x - slot.x) <= slot.width / 2 + gap / 2
        }) else { return }
        momentum?.cancel()
        setScrubbing(false)
        Haptics.tap()
        select(i)
        withAnimation(.snappy(duration: 0.25)) { position = Double(i) }
    }

    /// Follow the finger; the photo nearest the middle becomes current.
    private func move(to p: Double) {
        guard !photos.isEmpty else { return }
        position = min(max(p, 0), Double(photos.count - 1))
        select(Int(position.rounded()))
    }

    private func select(_ i: Int) {
        guard i != reported, photos.indices.contains(i) else { return }
        if reported != nil, scrubbing { Haptics.soft() }
        reported = i
        onSelect(photos[i])
    }

    /// After a flick, keep moving and slow down like a scroll view
    /// (UIScrollView's normal deceleration), then settle on a photo.
    private func coast(velocity: Double) {
        momentum = Task { @MainActor in
            var v = velocity
            var last = ContinuousClock.now
            while abs(v) > 1, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                let now = ContinuousClock.now
                let dt = Double((now - last).components.attoseconds) / 1e18
                last = now
                v *= pow(0.998, dt * 1000)
                let before = position
                move(to: position + v * dt)
                if position == before { break }   // hit either end
            }
            guard !Task.isCancelled else { return }
            let target = position.rounded()
            select(Int(target))
            withAnimation(.snappy(duration: 0.18)) { position = target }
            setScrubbing(false)
        }
    }

    /// The current photo changed elsewhere (swipe, undo, filter): move the
    /// strip to it, unless the finger is the one moving it.
    private func follow(animated: Bool) {
        guard !scrubbing, let i = currentIndex else { return }
        reported = i
        guard Double(i) != position else { return }
        if animated {
            withAnimation(.snappy(duration: 0.25)) { position = Double(i) }
        } else {
            position = Double(i)
        }
    }

    private func setScrubbing(_ value: Bool) {
        guard scrubbing != value else { return }
        scrubbing = value
        onScrubbingChanged(value)
    }
}
