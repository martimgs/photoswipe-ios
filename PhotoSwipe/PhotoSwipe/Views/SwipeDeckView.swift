import SwiftUI

/// The rating screen: header, photo card, star row, filmstrip, X / heart.
/// Right = +1 star, left = −1 star, up = pick (5 stars), down = reject.
/// Each gesture applies to the current photo, then advances.
struct SwipeDeckView: View {
    @ObservedObject var vm: AlbumSessionViewModel
    var onOpenGrid: () -> Void

    @State private var drag: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            if let current = vm.current {
                card(current)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                StarRatingView(rating: vm.rating(of: current)) { vm.setRating($0) }
                    .padding(.top, 18)
            } else {
                endState
            }
            FilmstripView(photos: vm.deck, currentID: vm.currentID) { vm.jump(to: $0) }
                .padding(.top, 10)
            actionBar
        }
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            VStack(spacing: 3) {
                Text(vm.album.name)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 60)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .regular))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back")
                Spacer()
                menu
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        let total = vm.deck.count
        let base = vm.position.map { "\($0) of \(total)" } ?? "\(total) photos"
        return vm.minRating == 0 ? base : "\(base) • \(RatingFilter.label(vm.minRating))"
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
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .regular))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("More")
        .onChange(of: vm.minRating) { vm.filterChanged() }
    }

    // MARK: Card

    private func card(_ current: PhotoItem) -> some View {
        ZStack {
            if let next = vm.next {
                PhotoCardView(item: next)
                    .scaleEffect(0.95)
                    .rotationEffect(.degrees(-3))
                    .offset(x: -8, y: 6)
                    .opacity(0.9)
                    .id("next-" + next.id)
            }
            PhotoCardView(item: current, intent: intent, intentStrength: strength)
                .id(current.id)
                .offset(drag)
                .rotationEffect(.degrees(Double(drag.width / 18)), anchor: .bottom)
                .gesture(dragGesture)
                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity),
                                        removal: .opacity))
        }
        .animation(.cardSpring, value: vm.currentID)
        .frame(maxHeight: .infinity)
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
            } else {
                MessageView(icon: "checkmark.circle", title: "You've reached the end",
                            message: "Review your picks in the grid, or go through the album again.",
                            button: "Review in Grid") { onOpenGrid() }
                Button("Back to first photo") { vm.startOver() }
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack {
            circleButton("xmark", label: "Reject") { reject() }
            Spacer()
            Button { withAnimation(.cardSpring) { drag = .zero }; vm.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 44, height: 44)
            }
            .opacity(vm.canUndo ? 1 : 0)
            .disabled(!vm.canUndo)
            .accessibilityLabel("Undo")
            Spacer()
            circleButton("heart", label: "Pick") { pick() }
        }
        .padding(.horizontal, 40)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .disabled(vm.current == nil)
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.ink)
                .frame(width: 62, height: 62)
                .background(Circle().fill(Color.white.opacity(0.75)))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
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
