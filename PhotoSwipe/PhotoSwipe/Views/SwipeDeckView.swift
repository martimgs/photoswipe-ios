import SwiftUI
import Photos

/// The swiping surface. Header + action bar are pinned via `safeAreaInset`, so
/// the layout adapts to every phone (notch, Dynamic Island, home-indicator)
/// without clipping. Right = +1 star, left = −1 star, up = 5 stars,
/// down = reject (queue for deletion).
struct SwipeDeckView: View {
    @ObservedObject var vm: SwipeDeckViewModel
    @State private var drag: CGSize = .zero

    var body: some View {
        deck
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
    }

    // MARK: Header (premium / techy)

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Button { Haptics.tap() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.stroke))
                }
                .buttonStyle(PressableStyle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("ALL PHOTOS")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(Theme.textDim)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(vm.remaining)")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(value: Double(vm.remaining)))
                            .animation(.snappy(duration: 0.35), value: vm.remaining)
                        Text("/ \(vm.assets.count)")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textDim)
                    }
                    .fixedSize()
                }
                Spacer(minLength: 12)
                undoButton
            }
            progressBar
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial.opacity(0.0)) // keep aurora visible
    }

    private var undoButton: some View {
        Button {
            Haptics.tap(.medium)
            vm.undo()
            withAnimation(.cardSpring) { drag = .zero }
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke))
        }
        .buttonStyle(PressableStyle())
        .disabled(!vm.canUndo)
        .opacity(vm.canUndo ? 1 : 0.3)
        .animation(.snappy, value: vm.canUndo)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                Capsule()
                    .fill(Theme.gradient(Theme.album, Theme.keep))
                    .frame(width: max(6, geo.size.width * vm.progress))
                    .shadow(color: Theme.keep.opacity(0.4), radius: 6)
                    .animation(.snappy(duration: 0.4), value: vm.progress)
            }
        }
        .frame(height: 5)
    }

    // MARK: Deck

    private var deck: some View {
        ZStack {
            ForEach(Array(stride(from: 2, through: 1, by: -1)), id: \.self) { depth in
                if let asset = vm.peek(depth) {
                    PhotoCardView(asset: asset, rating: vm.rating(of: asset), isTop: false)
                        .scaleEffect(1 - CGFloat(depth) * 0.05)
                        .offset(y: CGFloat(depth) * 14)
                        .opacity(depth == 2 ? 0.5 : 0.85)
                        .id(asset.localIdentifier)
                }
            }
            if let current = vm.current {
                PhotoCardView(asset: current, rating: vm.rating(of: current),
                              translation: drag, isTop: true)
                    .id(current.localIdentifier)
                    .offset(drag)
                    .rotationEffect(.degrees(Double(drag.width / 16)), anchor: .bottom)
                    .gesture(dragGesture)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.cardSpring, value: vm.index)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let t = value.translation
                if t.width > Theme.swipeThreshold {
                    fling(.right, rating: .up)
                } else if t.width < -Theme.swipeThreshold {
                    fling(.left, rating: .down)
                } else if t.height < -Theme.swipeThreshold {
                    fling(.up, rating: .pick)
                } else if t.height > Theme.swipeThreshold {
                    fling(.down, decision: .reject)
                } else {
                    Haptics.soft()
                    withAnimation(.cardSpring) { drag = .zero }
                }
            }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 18) {
            actionButton("minus", Theme.album, Theme.album2) { fling(.left, rating: .down) }
            actionButton("xmark", Theme.trash, Theme.trash2, big: false) { fling(.down, decision: .reject) }
            actionButton("star.fill", Theme.favorite, Theme.favorite2, big: false) { fling(.up, rating: .pick) }
            actionButton("plus", Theme.keep, Theme.keep2) { fling(.right, rating: .up) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func actionButton(_ icon: String, _ c1: Color, _ c2: Color, big: Bool = true,
                              action: @escaping () -> Void) -> some View {
        let size: CGFloat = big ? 64 : 56
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Theme.gradient(c1, c2))
                .frame(width: size, height: size)
                .background(
                    ZStack {
                        Circle().fill(Theme.card)
                        Circle().fill(c1.opacity(0.10))
                    }
                )
                .overlay(Circle().strokeBorder(c1.opacity(0.45), lineWidth: 1.5))
                .shadow(color: c1.opacity(0.30), radius: 12, y: 5)
        }
        .buttonStyle(PressableStyle(scale: 0.86))
    }

    // MARK: Fling

    private enum FlingDir { case left, right, up, down }

    private func fling(_ dir: FlingDir, decision: Decision) {
        Haptics.tap(.rigid)
        fling(dir) { vm.reject() }
    }

    /// The new rating is computed when the card lands, so it always builds on
    /// the latest value (e.g. after an undo).
    private func fling(_ dir: FlingDir, rating step: RatingStep) {
        if step == .pick { Haptics.success() } else { Haptics.tap(.light) }
        fling(dir) { vm.rate(step) }
    }

    private func fling(_ dir: FlingDir, commit: @escaping () -> Void) {
        let target: CGSize
        switch dir {
        case .left:  target = CGSize(width: -760, height: 80)
        case .right: target = CGSize(width: 760, height: 80)
        case .up:    target = CGSize(width: drag.width, height: -960)
        case .down:  target = CGSize(width: drag.width, height: 960)
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
