import SwiftUI

/// A Photos-app-style scrubber: a thin strip of narrow slivers with the
/// current photo shown wider in the middle. Drag a finger along it to move
/// through the photos (the photo under the center becomes current); tap a
/// sliver to jump to it.
struct FilmstripView: View {
    let photos: [PhotoItem]
    let currentID: String?
    let onSelect: (PhotoItem) -> Void

    static let height: CGFloat = 44
    private let sliverWidth: CGFloat = 22
    private let spacing: CGFloat = 2

    /// The photo at the center of the strip, driven by scrolling.
    @State private var centeredID: String?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(photos) { item in
                        let isCurrent = item.id == currentID
                        Thumbnail(item: item, side: Self.height, cornerRadius: 0)
                            .frame(width: isCurrent ? Self.height : sliverWidth, height: Self.height)
                            .clipped()
                            .overlay(
                                Rectangle().strokeBorder(Theme.ink, lineWidth: isCurrent ? 2 : 0)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.tap()
                                withAnimation(.snappy) { centeredID = item.id }
                                onSelect(item)
                            }
                            .id(item.id)
                            .accessibilityLabel(isCurrent ? "Current photo" : "Photo")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .scrollTargetLayout()
            }
            // Let the first and last photo reach the center.
            .safeAreaPadding(.horizontal, max(0, geo.size.width / 2 - Self.height / 2))
            .scrollPosition(id: $centeredID, anchor: .center)
            .scrollTargetBehavior(.viewAligned)
            .animation(.snappy(duration: 0.2), value: currentID)
            .onChange(of: centeredID) { _, id in
                // Scrubbing: the photo under the center becomes current.
                guard let id, id != currentID, let item = photos.first(where: { $0.id == id }) else { return }
                Haptics.soft()
                onSelect(item)
            }
            .onChange(of: currentID, initial: true) { _, id in
                // Swiping a card moves the strip along.
                guard let id, id != centeredID else { return }
                withAnimation(.snappy) { centeredID = id }
            }
        }
        .frame(height: Self.height)
    }
}
