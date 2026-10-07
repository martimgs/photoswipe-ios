import SwiftUI
import SwiftData
import Photos

/// Landing screen: a fixed logo header over the albums the user has connected, plus a
/// "Connect Album" row. Swiping a row away disconnects it — the photos
/// themselves are never touched. Renaming an album only changes its name in
/// this app, never at the source.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ConnectedAlbum.dateAdded) private var albums: [ConnectedAlbum]
    @State private var showConnect = false
    @State private var showSettings = false
    /// The list is scrolled under the header: show its divider.
    @State private var scrolled = false
    /// Expanded albums ("albumID") and subfolders ("albumID|path").
    @State private var expanded: Set<String> = []
    @State private var summaries = DropboxSummaryCache()
    @State private var renaming: ConnectedAlbum?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(albums) { album in
                    let summary = dropboxSummary(for: album)
                    let folders = summary?.folders ?? []
                    NavigationLink(value: AlbumRoute(album: album)) {
                        AlbumRow(album: album, summary: summary, folderCount: folders.count,
                                 isExpanded: expanded.contains(album.externalID)) {
                            toggle(album.externalID)
                        }
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .swipeActions(edge: .trailing) {
                        Button("Disconnect", role: .destructive) { disconnect(album) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Rename") { startRenaming(album) }
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { startRenaming(album) }
                        Button("Disconnect", systemImage: "minus.circle", role: .destructive) {
                            disconnect(album)
                        }
                    }
                    if expanded.contains(album.externalID) {
                        ForEach(flatten(folders, album: album), id: \.node.id) { entry in
                            NavigationLink(value: AlbumRoute(album: album, folder: entry.node.path)) {
                                FolderRow(album: album, node: entry.node, depth: entry.depth,
                                          isExpanded: expanded.contains(key(album, entry.node))) {
                                    toggle(key(album, entry.node))
                                }
                            }
                            .navigationLinkIndicatorVisibility(.hidden)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.margin,
                                          bottom: Spacing.xs, trailing: Spacing.margin))
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.paper)

                Button { Haptics.tap(); showConnect = true } label: { connectRow }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: Spacing.l, leading: Spacing.margin,
                                              bottom: Spacing.xs, trailing: Spacing.margin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.paper)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, Spacing.s, for: .scrollContent)
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
            // Stays put; the albums scroll under it.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 1
            } action: { _, isScrolled in
                withAnimation(.easeOut(duration: 0.15)) { scrolled = isScrolled }
            }
            .safeAreaBar(edge: .top) { header }
            .scrollEdgeEffectHidden(true, for: .top)
            .background(Theme.paper)
            .navigationTitle("Pickory")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AlbumRoute.self) { route in
                AlbumScreen(route: route)
            }
            .sheet(isPresented: $showConnect) {
                ConnectAlbumSheet(connected: albums)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("Rename Album", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }
            ), presenting: renaming) { album in
                TextField(album.name, text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { rename(album) }
            } message: { album in
                Text("Only changes the name in Pickory. Leave empty to use “\(album.name)”.")
            }
        }
        .tint(Theme.ink)
    }

    /// Logo left, name centered, settings right.
    private var header: some View {
        HStack {
            Image(.splashLogo)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.light))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.trailing, -Spacing.s)   // glyph lines up with the row chevrons
            .accessibilityLabel("Settings")
        }
        .overlay {
            Image(.splashName)
                .resizable()
                .scaledToFit()
                .frame(width: 150)
                .foregroundStyle(Theme.ink)
                .accessibilityLabel("Pickory")
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.xxs)
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
        .background(Theme.paper.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                .opacity(scrolled ? 1 : 0)
        }
    }

    /// A secondary action, not another album.
    private var connectRow: some View {
        Label("Connect Album", systemImage: "plus")
            .font(.metadata)
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHint("Add from Apple Photos or Dropbox")
    }

    // MARK: Subfolders

    /// Subfolders of a Dropbox album (empty for Apple Photos albums).
    /// Count, cover and folders of a Dropbox album (nil for Apple Photos).
    /// Built once per check for changes: it fetches and sorts every file in
    /// the album, and the list redraws often (e.g. while downloading).
    private func dropboxSummary(for album: ConnectedAlbum) -> DropboxSummary? {
        guard album.source == .dropbox else { return nil }
        let checked = album.lastCheckedAt
        if let cached = summaries.byAlbum[album.externalID], cached.checked == checked {
            return cached
        }
        let items = AlbumSessionViewModel.dropboxItems(albumID: album.externalID, context: context)
        let summary = DropboxSummary(checked: checked, count: items.count, cover: items.first,
                                     folders: FolderNode.tree(from: items))
        summaries.byAlbum[album.externalID] = summary
        // All covers in a few batched requests, before any folder is expanded.
        let covers = summary.coverIDs
        Task { await DropboxService.shared.prefetchCovers(covers) }
        return summary
    }

    private func key(_ album: ConnectedAlbum, _ node: FolderNode) -> String {
        album.externalID + "|" + node.path
    }

    private func toggle(_ key: String) {
        Haptics.tap()
        withAnimation(.snappy) {
            if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        }
    }

    /// Visible rows of the tree: a folder's children show only when it's expanded.
    private func flatten(_ nodes: [FolderNode], album: ConnectedAlbum, depth: Int = 1)
        -> [(node: FolderNode, depth: Int)] {
        nodes.flatMap { node -> [(node: FolderNode, depth: Int)] in
            var rows = [(node: node, depth: depth)]
            if expanded.contains(key(album, node)) {
                rows += flatten(node.children, album: album, depth: depth + 1)
            }
            return rows
        }
    }

    // MARK: Renaming

    private func startRenaming(_ album: ConnectedAlbum) {
        newName = album.customName ?? ""
        renaming = album
    }

    /// Stores the name in the app only; empty (or the source's name) clears it.
    private func rename(_ album: ConnectedAlbum) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        album.customName = name.isEmpty || name == album.name ? nil : name
        try? context.save()
    }

    /// Removes the connection only. For Dropbox albums the app's own
    /// downloaded copies are deleted; files in Dropbox are never touched.
    /// Ratings and any pending tag syncs are kept.
    private func disconnect(_ album: ConnectedAlbum) {
        let albumID = album.externalID
        if album.source == .dropbox {
            let files = (try? context.fetch(FetchDescriptor<DropboxFile>(
                predicate: #Predicate { $0.albumID == albumID }))) ?? []
            for file in files {
                OfflineStore.removeLocalCopyIfUnused(file.fileID, leaving: albumID, context: context)
                context.delete(file)
            }
        }
        context.delete(album)
        try? context.save()
        OfflineDownloadManager.shared.filesChanged(albumID: albumID)
    }
}

/// What the library shows for a Dropbox album, as of its last check for changes.
struct DropboxSummary {
    var checked: Date?
    var count: Int
    var cover: PhotoItem?
    var folders: [FolderNode]

    /// The album's cover, then every folder's (all levels).
    var coverIDs: [String] {
        func ids(_ nodes: [FolderNode]) -> [String] {
            nodes.flatMap { [$0.cover?.id].compactMap { $0 } + ids($0.children) }
        }
        return [cover?.id].compactMap { $0 } + ids(folders)
    }
}

/// Summaries by album ID. A plain class so filling it during `body`
/// doesn't redraw.
final class DropboxSummaryCache {
    var byAlbum: [String: DropboxSummary] = [:]
}

/// One connected album: cover, name, photo count. Shows "Unavailable" if the
/// album no longer exists at its source.
struct AlbumRow: View {
    let album: ConnectedAlbum
    /// Dropbox albums: already counted by the list, so nothing loads here.
    var summary: DropboxSummary?
    var folderCount = 0
    var isExpanded = false
    var onToggleFolders: () -> Void = {}
    @State private var info: AlbumInfo?
    @Environment(\.modelContext) private var context

    var body: some View {
        let info = summary.map { AlbumInfo(name: album.name, count: $0.count, cover: $0.cover, isAvailable: true) }
            ?? self.info
        HStack(spacing: 20) {
            Group {
                if let cover = info?.cover {
                    Thumbnail(item: cover, side: Thumbnail.album)
                } else {
                    RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: Thumbnail.album, height: Thumbnail.album)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(album.customName ?? info?.name ?? album.name)
                    .font(.callout)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .padding(.bottom, 2)
                Text(subtitle(info))
                    .font(.smallMetadata)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                if folderCount > 0 {
                    FolderToggle(count: folderCount, isExpanded: isExpanded, action: onToggleFolders)
                }
            }
            // The text column takes all the width the trailing controls don't need.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: Spacing.xxs) {
                if album.source == .dropbox {
                    // Album-level offline/sync control.
                    AlbumStatusButton(album: album)
                }
                RowChevron()
            }
            .fixedSize()
        }
        // Re-read after each Dropbox "check for changes".
        .task(id: "\(album.externalID)|\(album.lastCheckedAt?.timeIntervalSince1970 ?? 0)") {
            guard summary == nil else { return }
            self.info = AlbumInfo.load(album, context: context)
        }
    }

    private func subtitle(_ info: AlbumInfo?) -> String {
        guard let info else { return " " }
        guard info.isAvailable else { return "Unavailable" }
        return info.count == 1 ? "1 photo" : "\(info.count.formatted()) photos"
    }
}

/// Live details for a connected album, read from its source.
struct AlbumInfo {
    var name: String?
    var count = 0
    var cover: PhotoItem?
    var isAvailable = false

    @MainActor
    static func load(_ album: ConnectedAlbum, context: ModelContext) -> AlbumInfo {
        switch album.source {
        case .applePhotos:
            let service = PhotoLibraryService()
            guard let collection = service.album(withLocalIdentifier: album.externalID) else {
                return AlbumInfo()
            }
            return AlbumInfo(name: collection.localizedTitle,
                             count: service.photoCount(in: collection),
                             cover: service.coverPhoto(of: collection).map(PhotoItem.init(asset:)),
                             isAvailable: true)
        case .dropbox:
            // Dropbox albums always stay in the app, online or not.
            let items = AlbumSessionViewModel.dropboxItems(albumID: album.externalID, context: context)
            return AlbumInfo(name: album.name, count: items.count, cover: items.first, isAvailable: true)
        }
    }
}

/// "· 10 folders ⌄" — expands or collapses a row's subfolders. Borderless so
/// it can be tapped inside a list row without opening the album.
struct FolderToggle: View {
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xxs) {
                Text("\(count) folder\(count == 1 ? "" : "s")")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.medium))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .font(.smallMetadata)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.vertical, Spacing.xxs)
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isExpanded ? "Hide \(count) folders" : "Show \(count) folders")
    }
}

/// A subfolder of a Dropbox album, indented by depth. Opening it rates only
/// that folder and the folders below it.
struct FolderRow: View {
    let album: ConnectedAlbum
    let node: FolderNode
    let depth: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            Group {
                if let cover = node.cover {
                    Thumbnail(item: cover, side: Thumbnail.folder)
                } else {
                    RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: Thumbnail.folder, height: Thumbnail.folder)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(node.name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.count == 1 ? "1 photo" : "\(node.count.formatted()) photos")
                    .font(.smallMetadata)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                if !node.children.isEmpty {
                    FolderToggle(count: node.children.count, isExpanded: isExpanded, action: onToggle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: Spacing.xxs) {
                // Keep just this folder (and its subfolders) offline.
                // Shown only when it differs from the album's own icon.
                AlbumStatusButton(album: album, folder: node.path, hidesWhenSameAsAlbum: true)
                RowChevron()
            }
            .fixedSize()
        }
        // Top-level folders line up with the album; deeper ones indent.
        .padding(.leading, CGFloat(depth - 1) * Spacing.l)
    }
}

/// A small, light disclosure chevron for album and folder rows.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.inkTertiary)
            .accessibilityHidden(true)
    }
}
