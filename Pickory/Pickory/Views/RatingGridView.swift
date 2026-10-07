import SwiftUI

/// Review grid (mockup screen 4): the album's photos with their stars, and
/// All / Selected / Rejected tabs. Nothing is ever deleted — the Rejected tab
/// lets the user restore photos.
struct RatingGridView: View {
    @ObservedObject var vm: AlbumSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = DropboxSyncEngine.shared
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var tab: Tab = .selected
    @State private var sort: Sort = .album
    @State private var showExport = false
    @State private var exportAlert: String?
    @ObservedObject private var dropboxAuth = DropboxAuth.shared

    enum Sort: CaseIterable {
        case album, highest, lowest

        var title: String {
            switch self {
            case .album: return "Album Order"
            case .highest: return "Highest Rated First"
            case .lowest: return "Lowest Rated First"
            }
        }
    }

    enum Tab: CaseIterable {
        case all, selected, rejected

        var title: String {
            switch self {
            case .all: return "All"
            case .selected: return "Selected"
            case .rejected: return "Rejected"
            }
        }

    }

    private var selectedMin: Int { vm.minRating }

    /// Filtered by tab, then sorted. Ties keep album order.
    private var items: [PhotoItem] {
        let filtered = filteredItems
        switch sort {
        case .album:
            return filtered
        case .highest, .lowest:
            let ascending = sort == .lowest
            return filtered.enumerated().sorted { a, b in
                let ra = vm.rating(of: a.element), rb = vm.rating(of: b.element)
                if ra != rb { return ascending ? ra < rb : ra > rb }
                return a.offset < b.offset
            }.map(\.element)
        }
    }

    private var filteredItems: [PhotoItem] {
        switch tab {
        case .all:
            return vm.photos.filter { !vm.isRejected($0) }
        case .selected:
            return vm.photos.filter { !vm.isRejected($0) && vm.rating(of: $0) >= selectedMin }
        case .rejected:
            return vm.rejectedPhotos
        }
    }

    private var subtitle: String {
        let n = items.count
        let count = n == 1 ? "1 photo" : "\(n.formatted()) photos"
        return tab == .selected && selectedMin > 0 ? "\(count) · \(RatingFilter.label(selectedMin))" : count
    }

    var body: some View {
        GeometryReader { geo in
            // 2 columns on iPhone; more on wider screens (~220 pt each).
            let gap = Spacing.xs
            let inner = geo.size.width - 2 * Spacing.margin
            let columns = max(2, Int((inner + gap) / (220 + gap)))
            let side = (inner - gap * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                if items.isEmpty {
                    emptyState.frame(width: geo.size.width, height: geo.size.height * 0.8)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: gap), count: columns),
                              spacing: Spacing.m) {
                        ForEach(items) { asset in
                            cell(asset, side: side)
                        }
                    }
                    .padding(.horizontal, Spacing.margin)
                    .padding(.vertical, Spacing.xs)
                }
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(vm.title)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            if vm.album.source == .dropbox {
                ToolbarItem(placement: .topBarTrailing) {
                    AlbumStatusButton(album: vm.album, folder: vm.folder)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
            ToolbarItem(placement: .bottomBar) { tabPicker }
        }
        .onChange(of: vm.minRating) { vm.filterChanged() }
        .sheet(isPresented: $showExport) {
            ExportSheet(items: items, album: vm.album, folder: vm.folder)
        }
        .alert(exportAlert ?? "", isPresented: Binding(get: { exportAlert != nil }, set: { if !$0 { exportAlert = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Toolbar

    /// Minimum rating for the Selected tab (shared with the swipe screen).
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $vm.minRating) {
                ForEach(RatingFilter.options, id: \.self) { Text(RatingFilter.label($0)).tag($0) }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityValue(RatingFilter.label(vm.minRating))
    }

    private var moreMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            // Export what's shown (current tab, filter and sort) to Dropbox.
            Button {
                guard dropboxAuth.isSignedIn else { exportAlert = "Sign in to Dropbox in Settings to export."; return }
                guard Connectivity.shared.mayTryNetwork else { exportAlert = "Connect to the internet to export."; return }
                showExport = true
            } label: {
                Label("Export \(items.count) to Dropbox", systemImage: "square.and.arrow.up")
            }
            .disabled(items.isEmpty)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private var tabPicker: some View {
        Picker("Show", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .onChange(of: tab) { Haptics.tap() }
    }

    // MARK: Cells

    private func cell(_ asset: PhotoItem, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                guard tab != .rejected else { return }
                vm.jump(to: asset)
                dismiss()
            } label: {
                Thumbnail(item: asset, side: side, crop: vm.crop(of: asset))
                    .opacity(tab == .rejected ? 0.55 : 1)
                    .overlay(alignment: .topTrailing) { photoStatus(asset) }
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
                        .font(.smallMetadata)
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
            } else {
                RatingControl(rating: vm.rating(of: asset), size: .compact)
            }
        }
    }

    /// Marks only photos whose rating change hasn't synced to Dropbox
    /// (offline, or a failed attempt). Download state is shown per album.
    @ViewBuilder
    private func photoStatus(_ item: PhotoItem) -> some View {
        if item.source == .dropbox, sync.isUnsynced(fileID: item.id, isOnline: connectivity.isOnline) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.body)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.paper, Theme.ink.opacity(0.75))
                .padding(6)
                .accessibilityLabel("Rating not synced yet")
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
                               message: "Rejected photos are only hidden in Pickory — never deleted.")
        }
    }
}
