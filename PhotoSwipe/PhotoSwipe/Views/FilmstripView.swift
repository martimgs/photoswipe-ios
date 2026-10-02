import SwiftUI

/// Horizontal thumbnails of the deck. Tap one to jump to it; the current photo
/// is raised and outlined, and kept scrolled into view.
struct FilmstripView: View {
    let photos: [PhotoItem]
    let currentID: String?
    let onSelect: (PhotoItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(photos) { item in
                        let isCurrent = item.id == currentID
                        Button { Haptics.tap(); onSelect(item) } label: {
                            Thumbnail(item: item, side: 56, cornerRadius: 3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(Theme.ink, lineWidth: isCurrent ? 2 : 0)
                                )
                                .scaleEffect(isCurrent ? 1.08 : 1)
                                .shadow(color: .black.opacity(isCurrent ? 0.18 : 0), radius: 6, y: 3)
                                .zIndex(isCurrent ? 1 : 0)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .accessibilityLabel(isCurrent ? "Current photo" : "Photo")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: currentID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 76)
    }
}
