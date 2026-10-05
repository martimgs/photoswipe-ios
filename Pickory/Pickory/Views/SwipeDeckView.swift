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
/// Each gesture applies to the current photo, then advances.
struct SwipeDeckView: View {
    @ObservedObject var vm: AlbumSessionViewModel
    var onOpenGrid: () -> Void

    @State private var drag: CGSize = .zero
    /// A card flying off screen whose decision hasn't been committed yet.
    @State private var flight: Flight?
    @State private var fullScreen: PhotoItem?
    /// Largest pixel dimension of the card area, used for prefetch sizing.
    @State private var cardPixelSide: CGFloat = 0
    /// Finger on the filmstrip (or its momentum): cards switch without animation.
    @State private var scrubbing = false
    /// Wider than tall (phone or iPad landscape): stars live in the bar.
    @State private var isLandscape = false
    @Environment(\.displayScale) private var displayScale

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
        .fullScreenCover(item: $fullScreen) { FullScreenPhotoView(item: $0) }
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
                if !scrubbing, cardPixelSide > 0, distance <= 5 {
                    requests.append(.init(item: d[i], pixelSize: full, fill: false))
                }
                requests.append(.init(item: d[i], pixelSize: ImageLoader.previewSize, fill: false))
                requests.append(.init(item: d[i], pixelSize: thumb, fill: true))
            }
        }
        ImageLoader.shared.prefetch(requests)
    }

    private var filmstrip: some View {
        FilmstripView(photos: vm.deck, currentID: vm.currentID,
                      onSelect: { land(); vm.jump(to: $0, remember: !scrubbing) },
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
        Button { land(); withAnimation(.cardSpring) { drag = .zero }; vm.undo() } label: {
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

    /// The current photo on top of the next one. Both are keyed by photo id,
    /// so when a swipe commits, the card underneath simply becomes the
    /// current card (same view, image already loaded): nothing fades or
    /// reloads. Scrubbing and filmstrip taps just swap the cards.
    private func card(_ current: PhotoItem) -> some View {
        let stack = [vm.next, current].compactMap { $0 }
        return ZStack {
            ForEach(stack) { item in
                let isCurrent = item.id == current.id
                PhotoCardView(item: item,
                              intent: isCurrent ? intent : nil,
                              intentStrength: isCurrent ? strength : 0)
                    .modifier(DeckCardStyle(isCurrent: isCurrent, drag: drag, progress: progress))
                    .zIndex(isCurrent ? 1 : 0)
                    .allowsHitTesting(isCurrent)
                    .accessibilityHidden(!isCurrent)
                    .transition(.identity)
            }
        }
        .contentShape(Rectangle())
        // Tap = full screen; a drag of 10+ pt is a swipe instead. On the
        // whole area, so a new swipe can start while the last card flies off.
        .onTapGesture { land(); fullScreen = vm.current }
        .gesture(dragGesture)
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
            .onChanged { value in
                if flight != nil { land() }
                drag = value.translation
            }
            .onEnded { value in
                guard flight == nil else { return }
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

    private struct Flight {
        let token: UUID
        let photoID: String
        let commit: () -> Void
    }

    private func pick(velocity: CGSize = .zero) {
        Haptics.success()
        fling(.up, velocity: velocity) { vm.rate(.pick) }
    }

    private func reject(velocity: CGSize = .zero) {
        Haptics.tap(.rigid)
        fling(.down, velocity: velocity) { vm.reject() }
    }

    /// Sends the current card off screen, carrying on at the finger's speed,
    /// and commits the decision once it's gone. The next card is already
    /// underneath, growing into place as the top card leaves.
    private func fling(_ dir: FlingDir, velocity: CGSize, commit: @escaping () -> Void) {
        if flight != nil { land() }
        guard let id = vm.currentID else { return }
        if dir == .left || dir == .right { Haptics.tap(.light) }
        let target: CGSize
        let speed: CGFloat
        switch dir {
        case .left:  target = CGSize(width: -900, height: drag.height + 60); speed = -velocity.width
        case .right: target = CGSize(width: 900, height: drag.height + 60);  speed = velocity.width
        case .up:    target = CGSize(width: drag.width, height: -1100);       speed = -velocity.height
        case .down:  target = CGSize(width: drag.width, height: 1100);        speed = velocity.height
        }
        let distance = max(hypot(target.width - drag.width, target.height - drag.height), 1)
        // Spring velocity is in fractions of the distance per second.
        let initial = Double(max(speed, 0) / distance)
        let token = UUID()
        flight = Flight(token: token, photoID: id, commit: commit)
        withAnimation(.interpolatingSpring(duration: 0.32, bounce: 0, initialVelocity: initial),
                      completionCriteria: .logicallyComplete) {
            drag = target
        } completion: {
            if flight?.token == token { land() }
        }
    }

    /// Commits the flying card's decision and resets, without animation:
    /// the card is off screen and the one underneath is already in place.
    /// Also called early when a new swipe or tap starts mid-flight.
    private func land() {
        guard let f = flight else { return }
        flight = nil
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            // Only if the user hasn't moved elsewhere (filmstrip) meanwhile.
            if vm.currentID == f.photoID { f.commit() }
            drag = .zero
        }
    }
}

/// Top card follows the finger; the card underneath sits a little smaller
/// and hidden at rest (photos differ in shape, so it would peek out), and
/// comes up to full size as the drag progresses.
private struct DeckCardStyle: ViewModifier {
    let isCurrent: Bool
    let drag: CGSize
    let progress: Double

    func body(content: Content) -> some View {
        if isCurrent {
            content
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
