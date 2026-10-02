import SwiftUI

/// Preference key used to pass the card area's largest dimension up to the
/// deck so it can prefetch at the correct pixel size.
private struct CardSizeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The rating screen: photo card, star row, filmstrip, X / heart, under a
/// native navigation bar (album name, "12 of 179", "…" menu).
/// Right = +1 star, left = −1 star, up = pick (5 stars), down = reject.
/// Each gesture applies to the current photo, then advances.
struct SwipeDeckView: View {
    @ObservedObject var vm: AlbumSessionViewModel
    var onOpenGrid: () -> Void

    @State private var drag: CGSize = .zero
    @State private var fullScreen: PhotoItem?
    /// Largest pixel dimension of the card area, used for prefetch sizing.
    @State private var cardPixelSide: CGFloat = 0
    /// Finger on the filmstrip (or its momentum): cards switch without animation.
    @State private var scrubbing = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            // Wider than tall (phone or iPad landscape): photo on the left,
            // controls in a column on the right, so the photo gets the height.
            if geo.size.width > geo.size.height * 1.15 {
                landscape
            } else {
                portrait
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
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
            actionBar
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.xs)
        }
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
    }

    private var landscape: some View {
        HStack(spacing: 0) {
            VStack(spacing: Spacing.xs) {
                if let current = vm.current {
                    card(current)
                } else {
                    endState
                }
                filmstrip
            }
            .padding(.vertical, Spacing.xs)
            .padding(.leading, Spacing.m)
            VStack(spacing: Spacing.l) {
                Spacer(minLength: 0)
                if let current = vm.current {
                    RatingControl(rating: vm.rating(of: current)) { vm.setRating($0) }
                }
                actionBar
                Spacer(minLength: 0)
            }
            .frame(width: 280)
        }
    }

    // MARK: Header

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

    private func card(_ current: PhotoItem) -> some View {
        ZStack {
            PhotoCardView(item: current, intent: intent, intentStrength: strength)
                .id(current.id)
                .offset(drag)
                .rotationEffect(.degrees(Double(drag.width / 18)), anchor: .bottom)
                // Tap = full screen; a drag of 10+ pt is a swipe instead.
                .onTapGesture { fullScreen = current }
                .gesture(dragGesture)
                .accessibilityAction(named: "View Full Screen") { fullScreen = current }
                .transition(.asymmetric(insertion: .scale(scale: 0.98).combined(with: .opacity),
                                        removal: .opacity))
        }
        .animation(scrubbing ? nil : .cardSpring, value: vm.currentID)
        .frame(maxHeight: .infinity)
        // Measure the card area so prefetchAround() uses the right pixel size.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: CardSizeKey.self,
                                       value: max(geo.size.width, geo.size.height))
            }
        )
    }

    private var isVertical: Bool { abs(drag.height) > abs(drag.width) }

    private var intent: SwipeIntent? {
        guard drag != .zero else { return nil }
        if isVertical { return drag.height < 0 ? .pick : .reject }
        return drag.width > 0 ? .up : .down
    }

    private var strength: Double {
        Double(max(abs(drag.width), abs(drag.height)) / Theme.swipeThreshold)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let t = value.translation
                let vertical = abs(t.height) > abs(t.width)
                if !vertical && t.width > Theme.swipeThreshold {
                    fling(.right) { vm.rate(.up) }
                } else if !vertical && t.width < -Theme.swipeThreshold {
                    fling(.left) { vm.rate(.down) }
                } else if vertical && t.height < -Theme.swipeThreshold {
                    pick()
                } else if vertical && t.height > Theme.swipeThreshold {
                    reject()
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

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: Spacing.xxl) {
            RoundIconButton(systemImage: "xmark", label: "Reject") { reject() }
            Button { withAnimation(.cardSpring) { drag = .zero }; vm.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body.weight(.light))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 44, height: 44)
            }
            .opacity(vm.canUndo ? 1 : 0)
            .disabled(!vm.canUndo)
            .accessibilityLabel("Undo")
            RoundIconButton(systemImage: "heart", label: "Pick") { pick() }
        }
        .frame(maxWidth: .infinity)
        .disabled(vm.current == nil)
    }

    // MARK: Fling

    private enum FlingDir { case left, right, up, down }

    private func pick() {
        Haptics.success()
        fling(.up) { vm.rate(.pick) }
    }

    private func reject() {
        Haptics.tap(.rigid)
        fling(.down) { vm.reject() }
    }

    private func fling(_ dir: FlingDir, commit: @escaping () -> Void) {
        if dir == .left || dir == .right { Haptics.tap(.light) }
        let target: CGSize
        switch dir {
        case .left:  target = CGSize(width: -760, height: 60)
        case .right: target = CGSize(width: 760, height: 60)
        case .up:    target = CGSize(width: drag.width, height: -1000)
        case .down:  target = CGSize(width: drag.width, height: 1000)
        }
        withAnimation(.fling) { drag = target }
        // Let the card fly off before committing the decision and resetting.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            commit()
            drag = .zero
        }
    }
}
