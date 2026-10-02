import SwiftUI
import Photos

/// Review grid (mockup screen 4): the album's photos with their stars, and
/// All / Selected / Rejected tabs. Nothing is ever deleted — the Rejected tab
/// lets the user restore photos.
struct RatingGridView: View {
    @ObservedObject var vm: AlbumSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .selected

    enum Tab: CaseIterable {
        case all, selected, rejected

        var title: String {
            switch self {
            case .all: return "All"
            case .selected: return "Selected"
            case .rejected: return "Rejected"
            }
        }

        var icon: String {
            switch self {
            case .all: return "photo"
            case .selected: return "star.fill"
            case .rejected: return "eye.slash"
            }
        }
    }

    /// Selected means rated at or above the filter; with no filter, any
    /// rating (1+ star) counts as selected.
    private var selectedMin: Int { max(vm.minRating, 1) }

    private var items: [PHAsset] {
        switch tab {
        case .all:
            return vm.photos.filter { !vm.isRejected($0) }
        case .selected:
            return vm.photos.filter { !vm.isRejected($0) && vm.rating(of: $0).rawValue >= selectedMin }
        case .rejected:
            return vm.rejectedPhotos
        }
    }

    private var subtitle: String {
        let n = items.count
        switch tab {
        case .all: return n == 1 ? "1 photo" : "\(n) photos"
        case .selected: return "\(n) selected • \(RatingFilter.label(selectedMin))"
        case .rejected: return "\(n) rejected"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                let side = (geo.size.width - 16 * 2 - 8) / 2
                ScrollView {
                    if items.isEmpty {
                        emptyState.frame(width: geo.size.width, height: geo.size.height * 0.8)
                    } else {
                        LazyVGrid(columns: [GridItem(.fixed(side), spacing: 8),
                                            GridItem(.fixed(side), spacing: 8)], spacing: 14) {
                            ForEach(items, id: \.localIdentifier) { asset in
                                cell(asset, side: side)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            }
            tabBar
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            VStack(spacing: 3) {
                Text(vm.album.name)
                    .font(.system(size: 16))
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
                        .font(.system(size: 19))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back")
                Spacer()
                Menu {
                    Picker("Selected", selection: $vm.minRating) {
                        ForEach(RatingFilter.options, id: \.self) { min in
                            Text(min == 0 ? "Any rating (1+ stars)" : RatingFilter.label(min)).tag(min)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 19))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Filter")
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
        .onChange(of: vm.minRating) { vm.filterChanged() }
    }

    // MARK: Cells

    private func cell(_ asset: PHAsset, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                guard tab != .rejected else { return }
                vm.jump(to: asset)
                dismiss()
            } label: {
                Thumbnail(asset: asset, side: side, cornerRadius: 4)
                    .opacity(tab == .rejected ? 0.55 : 1)
            }
            .buttonStyle(.plain)
            .disabled(tab == .rejected)
            .accessibilityLabel(tab == .rejected ? "Rejected photo" : "Open in swipe view")

            if tab == .rejected {
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { vm.unreject(asset) }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            } else {
                StarRatingView(rating: vm.rating(of: asset), size: 12, spacing: 3)
                    .padding(.leading, 4)
            }
        }
    }

    private var emptyState: some View {
        switch tab {
        case .all:
            return MessageView(icon: "photo", title: "No photos",
                               message: "Every photo in this album is rejected.")
        case .selected:
            return MessageView(icon: "star", title: "Nothing selected yet",
                               message: "Photos rated \(RatingFilter.label(selectedMin)) appear here.")
        case .rejected:
            return MessageView(icon: "eye.slash", title: "No rejected photos",
                               message: "Rejected photos are only hidden in PhotoSwipe — never deleted.")
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    Haptics.tap()
                    tab = t
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 19, weight: .light))
                        Text(t.title).font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(tab == t ? Theme.surface : .clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.paper)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
