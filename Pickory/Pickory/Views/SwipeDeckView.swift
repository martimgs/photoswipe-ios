import SwiftUI

/// Preference key used to pass the card area's largest dimension up to the
/// deck so it can prefetch at the correct pixel size.
private struct CardSizeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The rating screen: photo card, star row and filmstrip under a native
/// navigation bar (album name, "12 of 179", Undo, "…" menu). In landscape the
/// stars move into the bar so the photo gets all the height.
/// Right = +1 star, left = next (rating unchanged), up = pick (5 stars),
/// down = reject.
/// Each gesture applies to the current photo, then advances. Pinching zooms
/// the photo for as long as the fingers stay down, then it snaps back.
struct SwipeDeckView: View {
    @ObservedObject var vm: AlbumSessionViewModel
    var onOpenGrid: () -> Void

    @State private var drag: CGSize = .zero
    /// Cards flying off screen. Purely visual: the decision is already
    /// made, so the filmstrip, counter and stars move on straight away.
    @State private var flyers: [Flyer] = []
    @State private var fullScreen: PhotoItem?
    /// Largest pixel dimension of the card area, used for prefetch sizing.
    @State private var cardPixelSide: CGFloat = 0
    /// Finger on the filmstrip (or its momentum): cards switch without animation.
    @State private var scrubbing = false
    /// Wider than tall (phone or iPad landscape): stars live in the bar.
    @State private var isLandscape = false
    /// Zoom of the pinch under way (or snapping back).
    @State private var peek = Peek.none
    /// From the first pinch until the photo is back in place: no swiping.
    @State private var isPeeking = false
    /// Where the pinch started, relative to the middle of the card area.
    @State private var peekStart: CGPoint = .zero
    @State private var cardArea: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    private static let maxPeekScale: CGFloat = 6

    var body: some View {
        Group {
            if isLandscape { landscape } else { portrait }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height * 1.15 } action: {
            isLandscape = $0
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationSubtitle(isLandscape ? "" : subtitle)
        .toolbar { toolbarContent }
        .fullScreenCover(item: $fullScreen, onDismiss: vm.reloadEdits) { FullScreenPhotoView(item: $0) }
        .onPreferenceChange(CardSizeKey.self) { side in
            if side > 0 { cardPixelSide = side * displayScale }
        }
        .onChange(of: vm.currentID, initial: true) { _, _ in prefetchAround() }
    }

    /// Nearest photo first: filmstrip thumbnails and card previews for a wide
    /// window, sharp card images only close by and only when not scrubbing.
    private func prefetchAround() {
        let d = vm.deck
        guard let idx = d.firstIndex(where: { $0.id == vm.currentID }) else { return }
        let thumb = CGSize(width: FilmstripView.height * displayScale, height: FilmstripView.height * displayScale)
        let full = CGSize(width: cardPixelSide, height: cardPixelSide)
        var requests: [ImageLoader.Request] = []
        for distance in 0...40 {
            for i in Set([idx - distance, idx + distance]).sorted() where d.indices.contains(i) {
                let brightness = vm.brightness(of: d[i])
                if !scrubbing, cardPixelSide > 0, distance <= 3 {
                    requests.append(.init(item: d[i], pixelSize: full, fill: false, brightness: brightness))
                }
                if distance <= 20 {
                    requests.append(.init(item: d[i], pixelSize: ImageLoader.previewSize, fill: false,
                                          brightness: brightness))
                }
                requests.append(.init(item: d[i], pixelSize: thumb, fill: true))
            }
        }
        ImageLoader.shared.prefetch(requests)
    }

    private var filmstrip: some View {
        FilmstripView(photos: vm.deck, currentID: vm.currentID,
                      onSelect: { vm.jump(to: $0, remember: !scrubbing) },
                      onScrubbingChanged: { active in
                          scrubbing = active
                          if !active {
                              vm.rememberPosition()
                              prefetchAround()
                          }
                      })
    }

    private var portrait: some View {
        VStack(spacing: 0) {
            if let current = vm.current {
                // Fixed area; the photo fits inside it, so everything below
                // stays put between portrait and landscape photos.
                card(current)
                    .padding(.horizontal, Spacing.margin)
                    .padding(.top, Spacing.xs)
                RatingControl(rating: vm.rating(of: current)) { vm.setRating($0) }
                    .padding(.top, Spacing.m)
            } else {
                endState
            }
            filmstrip
                .padding(.top, Spacing.s)
                .padding(.bottom, Spacing.xs)
        }
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
    }

    /// Photo above a full-width filmstrip; the stars are in the bar.
    private var landscape: some View {
        VStack(spacing: Spacing.xs) {
            if let current = vm.current {
                card(current)
                    .padding(.horizontal, Spacing.m)
            } else {
                endState
            }
            filmstrip
        }
        .padding(.top, Spacing.xxs)
        .padding(.bottom, Spacing.xs)
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isLandscape {
            // Replaces the centered title: name and count sit on the left,
            // next to the back button, as one line.
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            ToolbarItem(placement: .topBarLeading) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(vm.title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .lineLimit(1)
                // Toolbar items are proposed little width; keep it whole.
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
            if let current = vm.current {
                ToolbarItem(placement: .topBarTrailing) {
                    RatingControl(rating: vm.rating(of: current), size: .header) { vm.setRating($0) }
                        .padding(.horizontal, Spacing.xs)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
        }
        ToolbarItem(placement: .topBarTrailing) { undoButton }
        ToolbarItem(placement: .topBarTrailing) { menu }
    }

    private var undoButton: some View {
        Button { flyers.removeAll(); withAnimation(.cardSpring) { drag = .zero }; vm.undo() } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
        }
        .disabled(!vm.canUndo)
    }

    private var subtitle: String {
        let total = vm.deck.count
        let base = vm.position.map { "\($0) of \(total)" } ?? "\(total) photos"
        return vm.minRating == 0 ? base : "\(base) · \(RatingFilter.label(vm.minRating))"
    }

    private var menu: some View {
        Menu {
            Picker("Show", selection: $vm.minRating) {
                ForEach(RatingFilter.options, id: \.self) { Text(RatingFilter.label($0)).tag($0) }
            }
            Divider()
            Button { onOpenGrid() } label: { Label("Review in Grid", systemImage: "square.grid.2x2") }
            Button { vm.startOver() } label: { Label("Back to First Photo", systemImage: "arrow.counterclockwise") }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .onChange(of: vm.minRating) { vm.filterChanged() }
    }

    // MARK: Card

    /// The current photo on top of the next one, with any swiped cards
    /// flying off above. Keyed by photo id, so when a swipe commits the card
    /// underneath simply becomes the current card (same view, image already
    /// loaded) and the swiped one flies off from where the finger left it:
    /// nothing fades. Scrubbing and filmstrip taps just swap the cards.
    private func card(_ current: PhotoItem) -> some View {
        // The next card only exists while a swipe is under way (it's hidden
        // at rest anyway). Keeping a second card in the stack while the
        // filmstrip changes the current photo garbles the strip's drag.
        let showNext = !scrubbing && (drag != .zero || !flyers.isEmpty)
        let base = [showNext ? vm.next : nil, current].compactMap { $0 }
        let flying = flyers.filter { f in !base.contains { $0.id == f.id } }
        return ZStack {
            ForEach(base) { item in
                let isCurrent = item.id == current.id
                PhotoCardView(item: item, crop: vm.crop(of: item), brightness: vm.brightness(of: item),
                              intent: isCurrent ? intent : nil,
                              intentStrength: isCurrent ? strength : 0,
                              isPeeking: isCurrent && isPeeking)
                    .modifier(DeckCardStyle(role: isCurrent ? .current : .next,
                                            drag: drag, progress: progress, peek: peek))
                    .zIndex(isCurrent ? 1 : 0)
                    .allowsHitTesting(isCurrent)
                    .accessibilityHidden(!isCurrent)
                    .transition(.identity)
            }
            ForEach(flying) { f in
                PhotoCardView(item: f.item, crop: vm.crop(of: f.item), brightness: vm.brightness(of: f.item),
                              intent: f.intent, intentStrength: 1)
                    .modifier(DeckCardStyle(role: .current, drag: f.offset, progress: 1))
                    .zIndex(2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.identity)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardArea = $0 }
        // Tap = full screen; a drag of 10+ pt is a swipe instead. On the
        // whole area, so a new swipe can start while the last card flies off.
        .onTapGesture { if !isPeeking { fullScreen = vm.current } }
        .gesture(dragGesture, isEnabled: !isPeeking)
        .gesture(PeekPinchGesture(onBegan: beginPeek, onChanged: updatePeek, onEnded: endPeek))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "View Full Screen") { fullScreen = current }
        .accessibilityAction(named: "Pick") { pick() }
        .accessibilityAction(named: "Reject") { reject() }
        .frame(maxHeight: .infinity)
        // Measure the card area so prefetchAround() uses the right pixel size.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: CardSizeKey.self,
                                       value: max(geo.size.width, geo.size.height))
            }
        )
        // A zoomed photo goes over the stars and the filmstrip.
        .zIndex(isPeeking ? 1 : 0)
    }

    /// 0 at rest, 1 once the drag reaches the swipe threshold (or the card
    /// is flying off).
    private var progress: Double { min(strength, 1) }

    private var isVertical: Bool { abs(drag.height) > abs(drag.width) }

    private var intent: SwipeIntent? {
        guard drag != .zero else { return nil }
        if isVertical { return drag.height < 0 ? .pick : .reject }
        return drag.width > 0 ? .up : .skip
    }

    private var strength: Double {
        Double(max(abs(drag.width), abs(drag.height)) / Theme.swipeThreshold)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { if !isPeeking { drag = $0.translation } }
            .onEnded { value in
                guard !isPeeking else { return }
                let t = value.translation
                let v = value.velocity
                let vertical = abs(t.height) > abs(t.width)
                if !vertical && t.width > Theme.swipeThreshold {
                    fling(.right, velocity: v) { vm.rate(.up) }
                } else if !vertical && t.width < -Theme.swipeThreshold {
                    fling(.left, velocity: v) { vm.skip() }
                } else if vertical && t.height < -Theme.swipeThreshold {
                    pick(velocity: v)
                } else if vertical && t.height > Theme.swipeThreshold {
                    reject(velocity: v)
                } else {
                    Haptics.soft()
                    withAnimation(.cardSpring) { drag = .zero }
                }
            }
    }

    // MARK: Pinch to peek

    private func cardPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - cardArea.width / 2, y: location.y - cardArea.height / 2)
    }

    private func beginPeek(at location: CGPoint) {
        peekStart = cardPoint(location)
        isPeeking = true
        // The first finger may already have started a swipe.
        withAnimation(.cardSpring) { drag = .zero }
    }

    /// Keeps the part of the photo that was under the fingers under the fingers.
    private func updatePeek(scale: CGFloat, at location: CGPoint) {
        let point = cardPoint(location)
        let s = min(max(scale, 1), Self.maxPeekScale)
        isPeeking = true
        peek = Peek(scale: s, offset: CGSize(width: point.x - s * peekStart.x,
                                             height: point.y - s * peekStart.y))
    }

    private func endPeek() {
        withAnimation(.cardSpring, completionCriteria: .logicallyComplete) {
            peek = .none
        } completion: {
            // Not if a new pinch started while this one was snapping back.
            if peek == .none { isPeeking = false }
        }
    }

    // MARK: End of deck

    private var endState: some View {
        VStack(spacing: 14) {
            Spacer()
            if vm.deck.isEmpty {
                MessageView(icon: "line.3.horizontal.decrease.circle",
                            title: "No photos to show",
                            message: vm.minRating == 0
                                ? "Every photo in this album is rejected. Restore some from the grid."
                                : "No photos match \(RatingFilter.label(vm.minRating)).",
                            button: vm.minRating == 0 ? "Open Grid" : "Show All Photos") {
                    if vm.minRating == 0 { onOpenGrid() } else { vm.minRating = 0 }
                }
            } else if vm.minRating >= 5 {
                MessageView(icon: "checkmark.circle", title: "All done!",
                            message: "You've been through every 5-star photo.",
                            button: "Review in Grid") { onOpenGrid() }
            } else {
                // Tap anywhere to go round again, one star stricter.
                Button { Haptics.success(); vm.nextRound() } label: {
                    MessageView(icon: "arrow.counterclockwise.circle", title: "You've reached the end",
                                message: "Tap to start from the beginning with \(RatingFilter.label(vm.minRating + 1)).")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Raises the rating filter to \(RatingFilter.label(vm.minRating + 1))")
                Button("Review in Grid") { onOpenGrid() }
                    .font(.metadata)
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Fling

    private enum FlingDir { case left, right, up, down }

    private struct Flyer: Identifiable {
        let item: PhotoItem
        let intent: SwipeIntent?
        var offset: CGSize
        var id: String { item.id }
    }

    private func pick(velocity: CGSize = .zero) {
        Haptics.success()
        fling(.up, velocity: velocity) { vm.rate(.pick) }
    }

    private func reject(velocity: CGSize = .zero) {
        Haptics.tap(.rigid)
        fling(.down, velocity: velocity) { vm.reject() }
    }

    /// Commits the decision straight away (the next card is already
    /// underneath and becomes current), then sends the swiped card off
    /// screen as a flyer, carrying on at the finger's speed.
    private func fling(_ dir: FlingDir, velocity: CGSize, commit: () -> Void) {
        guard let item = vm.current else { return }
        if dir == .left || dir == .right { Haptics.tap(.light) }
        let start = drag
        let target: CGSize
        let speed: CGFloat
        switch dir {
        case .left:  target = CGSize(width: -900, height: start.height + 60); speed = -velocity.width
        case .right: target = CGSize(width: 900, height: start.height + 60);  speed = velocity.width
        case .up:    target = CGSize(width: start.width, height: -1100);       speed = -velocity.height
        case .down:  target = CGSize(width: start.width, height: 1100);        speed = velocity.height
        }
        let distance = max(hypot(target.width - start.width, target.height - start.height), 1)
        // Spring velocity is in fractions of the distance per second.
        let initial = Double(max(speed, 0) / distance)

        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            flyers.removeAll { $0.id == item.id }
            flyers.append(Flyer(item: item, intent: intent, offset: start))
            commit()
            drag = .zero
        }
        withAnimation(.interpolatingSpring(duration: 0.32, bounce: 0, initialVelocity: initial),
                      completionCriteria: .logicallyComplete) {
            if let i = flyers.firstIndex(where: { $0.id == item.id }) { flyers[i].offset = target }
        } completion: {
            flyers.removeAll { $0.id == item.id && $0.offset == target }
        }
    }
}

/// How far the current card is pinched.
private struct Peek: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    static let none = Peek()
}

/// A UIKit pinch because it reports where the fingers are as they move, so
/// the zoom can follow them. Runs alongside the card's drag and tap.
private struct PeekPinchGesture: UIGestureRecognizerRepresentable {
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGFloat, CGPoint) -> Void
    let onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let pinch = UIPinchGestureRecognizer()
        pinch.delegate = context.coordinator
        return pinch
    }

    func handleUIGestureRecognizerAction(_ pinch: UIPinchGestureRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch pinch.state {
        case .began:
            onBegan(location)
            onChanged(pinch.scale, location)
        case .changed:
            // The midpoint jumps once one of the two fingers has lifted.
            if pinch.numberOfTouches >= 2 { onChanged(pinch.scale, location) }
        case .ended, .cancelled, .failed:
            onEnded()
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Top card follows the finger; the card underneath sits a little smaller
/// and hidden at rest (photos differ in shape, so it would peek out), and
/// comes up to full size as the drag progresses.
private struct DeckCardStyle: ViewModifier {
    enum Role { case current, next }
    let role: Role
    let drag: CGSize
    let progress: Double
    var peek = Peek.none

    func body(content: Content) -> some View {
        if role == .current {
            content
                .scaleEffect(peek.scale)
                .offset(peek.offset)
                .offset(drag)
                .rotationEffect(.degrees(Double(drag.width / 18)), anchor: .bottom)
        } else {
            content
                .scaleEffect(0.94 + 0.06 * progress)
                // Revealed by the first part of the drag, in step with the finger.
                .opacity(min(progress * 2.5, 1))
        }
    }
}
