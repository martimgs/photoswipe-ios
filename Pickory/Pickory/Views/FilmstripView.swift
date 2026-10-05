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

    static let height: CGFloat = 50
    private let sliver: CGFloat = 22
    private let gap: CGFloat = 2
    private var step: CGFloat { sliver + gap }
    private var extra: CGFloat { Self.height - sliver }
    /// How far past the halfway point (in photos) the strip must move before
    /// the current photo changes, so small wobbles and finger roll don't.
    private let stickiness = 0.2
    /// Release speed (pt/s) that counts as a flick; anything slower just stops.
    private let flickSpeed: CGFloat = 250
    /// Finger movement (pt) before a touch becomes a scrub instead of a tap.
    private let scrubSlop: CGFloat = 3
    /// A single move larger than this (in photos) glides instead of jumping.
    private let maxJump = 0.75
    /// Glide speed, in photos per 8 ms tick (~1000 pt/s): fast enough to keep
    /// up, slow enough to show every photo it passes.
    private let glideStep = 0.35

    private struct Sample { let time: Date; let x: CGFloat }

    @State private var position: Double = 0
    @State private var reported: Int?
    @State private var dragStart: Double?
    /// The finger has moved far enough for this touch to be a scrub.
    @State private var moved = false
    @State private var touchStart: Date?
    /// Where the finger wants the strip while a glide catches up.
    @State private var glideTarget: Double?
    @State private var glide: Task<Void, Never>?
    @State private var samples: [Sample] = []
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
            let center = reported ?? Int(position.rounded())
            ZStack {
                ForEach(range, id: \.self) { i in
                    let slot = layout(i)
                    Thumbnail(item: photos[i], side: Self.height, cornerRadius: 0)
                        .frame(width: slot.width, height: Self.height)
                        .clipped()
                        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: i == center ? 1.5 : 0))
                        .position(x: mid + slot.x, y: Self.height / 2)
                }
            }
            .frame(width: geo.size.width, height: Self.height)
            .contentShape(Rectangle())
            .gesture(touchGesture(mid: mid, range: range))
        }
        .frame(height: Self.height)
        .clipped()
        // The strip sits near the home indicator; without this the system
        // holds touches back to check for a home swipe, so scrubs start late.
        .defersSystemGestures(on: .bottom)
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

    /// Taps and scrubs in one gesture that sees the touch from the moment it
    /// lands, so a scrub starts after a few points of movement instead of
    /// waiting for a separate tap gesture to give up.
    private func touchGesture(mid: CGFloat, range: Range<Int>) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    // Touching a coasting strip stops it, like a scroll view.
                    momentum?.cancel()
                    stopGlide()
                    dragStart = position
                    touchStart = value.time
                    moved = false
                    samples = []
                }
                if !moved {
                    guard abs(value.translation.width) >= scrubSlop else { return }
                    moved = true
                    setScrubbing(true)
                }
                samples.append(Sample(time: value.time, x: value.translation.width))
                samples.removeAll { value.time.timeIntervalSince($0.time) > 0.1 }
                move(to: (dragStart ?? position) - Double(value.translation.width / step), glide: true)
            }
            .onEnded { value in
                defer { dragStart = nil; moved = false; touchStart = nil }
                if moved {
                    // Finish any glide first so the flick starts from the finger.
                    if let target = glideTarget { stopGlide(); move(to: target) }
                    coast(velocity: -Double(releaseVelocity(at: value.time) / step))
                } else if let start = touchStart, value.time.timeIntervalSince(start) < 0.4 {
                    tap(atX: value.location.x - mid, in: range)
                } else if scrubbing {
                    // Long press that caught a coasting strip: settle it.
                    coast(velocity: 0)
                }
            }
    }

    /// Finger speed over the last moments of the drag, or 0 unless it was a
    /// real flick. `DragGesture`'s own velocity includes the finger rolling
    /// off the glass, which made slow, careful scrubs slide on release.
    private func releaseVelocity(at end: Date) -> CGFloat {
        let recent = samples.filter { end.timeIntervalSince($0.time) <= 0.08 }
        samples = []
        guard let first = recent.first, let last = recent.last else { return 0 }
        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0.01 else { return 0 }
        let v = (last.x - first.x) / dt
        return abs(v) >= flickSpeed ? v : 0
    }

    private func tap(atX x: CGFloat, in range: Range<Int>) {
        guard let i = range.first(where: {
            let slot = layout($0)
            return abs(x - slot.x) <= slot.width / 2 + gap / 2
        }) else { return }
        momentum?.cancel()
        stopGlide()
        setScrubbing(false)
        Haptics.tap()
        select(i)
        withAnimation(.snappy(duration: 0.25)) { position = Double(i) }
    }

    /// Follow the finger; the photo nearest the middle becomes current.
    /// With `glide`, a move too big for one step (the finger outran the
    /// touch events) slides there instead, showing each photo on the way.
    private func move(to p: Double, glide gliding: Bool = false) {
        guard !photos.isEmpty else { return }
        let target = min(max(p, 0), Double(photos.count - 1))
        if gliding, glideTarget != nil || abs(target - position) > maxJump {
            glideTarget = target
            startGlide()
            return
        }
        position = target
        select(nearest(to: position))
    }

    private func startGlide() {
        guard glide == nil else { return }
        glide = Task { @MainActor in
            while let target = glideTarget, !Task.isCancelled {
                let delta = target - position
                if abs(delta) <= glideStep {
                    glideTarget = nil
                    position = target
                    select(nearest(to: position))
                    break
                }
                position += delta > 0 ? glideStep : -glideStep
                select(nearest(to: position))
                try? await Task.sleep(for: .milliseconds(8))
            }
            // A cancelled glide may already have been replaced.
            if !Task.isCancelled { glide = nil }
        }
    }

    private func stopGlide() {
        glide?.cancel()
        glide = nil
        glideTarget = nil
    }

    /// The photo at `p`, sticking with the current one until the strip is
    /// clearly past the halfway point to the next.
    private func nearest(to p: Double) -> Int {
        if let cur = reported, abs(p - Double(cur)) < 0.5 + stickiness { return cur }
        return Int(p.rounded())
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
            let i = nearest(to: position)
            select(i)
            let target = Double(i)
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
