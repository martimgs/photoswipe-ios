import SwiftUI
import SwiftData
import Photos

/// Landing screen ("My Photos"): the albums the user has connected, plus a
/// "Connect Album" row. Swiping a row away disconnects it — the photos
/// themselves are never touched.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ConnectedAlbum.dateAdded) private var albums: [ConnectedAlbum]
    @State private var showConnect = false
    @State private var showSettings = false
    /// Expanded albums ("albumID") and subfolders ("albumID|path").
    @State private var expanded: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                header
                    .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.margin,
                                              bottom: Spacing.l, trailing: Spacing.margin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.paper)

                ForEach(albums) { album in
                    let folders = folderTree(for: album)
                    NavigationLink(value: AlbumRoute(album: album)) {
                        AlbumRow(album: album, folderCount: folders.count,
                                 isExpanded: expanded.contains(album.externalID)) {
                            toggle(album.externalID)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Disconnect", role: .destructive) { disconnect(album) }
                    }
                    if expanded.contains(album.externalID) {
                        ForEach(flatten(folders, album: album), id: \.node.id) { entry in
                            NavigationLink(value: AlbumRoute(album: album, folder: entry.node.path)) {
                                FolderRow(album: album, node: entry.node, depth: entry.depth,
                                          isExpanded: expanded.contains(key(album, entry.node))) {
                                    toggle(key(album, entry.node))
                                }
                            }
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
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
            .background(Theme.paper)
            .navigationTitle("My Photos")
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
        }
        .tint(Theme.ink)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("My Photos")
                .font(.screenTitle)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.light))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.trailing, -Spacing.xs)   // glyph lines up with the row chevrons
            .accessibilityLabel("Settings")
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
    private func folderTree(for album: ConnectedAlbum) -> [FolderNode] {
        guard album.source == .dropbox else { return [] }
        _ = album.lastCheckedAt   // re-read after each check for changes
        return FolderNode.tree(from: AlbumSessionViewModel.dropboxItems(albumID: album.externalID, context: context))
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

    /// Removes the connection only. For Dropbox albums the app's own
    /// downloaded copies are deleted; files in Dropbox are never touched.
    /// Ratings and any pending tag syncs are kept.
    private func disconnect(_ album: ConnectedAlbum) {
        if album.source == .dropbox {
            let albumID = album.externalID
            let files = (try? context.fetch(FetchDescriptor<DropboxFile>(
                predicate: #Predicate { $0.albumID == albumID }))) ?? []
            for file in files {
                OfflineStore.removeLocalCopyIfUnused(file.fileID, leaving: albumID, context: context)
                context.delete(file)
            }
        }
        context.delete(album)
        try? context.save()
    }
}

/// One connected album: cover, name, photo count. Shows "Unavailable" if the
/// album no longer exists at its source.
struct AlbumRow: View {
    let album: ConnectedAlbum
    var folderCount = 0
    var isExpanded = false
    var onToggleFolders: () -> Void = {}
    @State private var info: AlbumInfo?
    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(spacing: Spacing.m) {
            Group {
                if let cover = info?.cover {
                    Thumbnail(item: cover, side: Thumbnail.album)
                } else {
                    RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: Thumbnail.album, height: Thumbnail.album)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.name ?? album.name)
                    .font(.rowTitle)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.metadata)
                    .foregroundStyle(Theme.inkSecondary)
                if folderCount > 0 {
                    FolderToggle(count: folderCount, isExpanded: isExpanded, action: onToggleFolders)
                }
            }
            Spacer(minLength: Spacing.xs)
            if album.source == .dropbox {
                // Album-level offline/sync control.
                AlbumStatusButton(album: album)
            }
        }
        // Re-read after each Dropbox "check for changes".
        .task(id: "\(album.externalID)|\(album.lastCheckedAt?.timeIntervalSince1970 ?? 0)") {
            info = AlbumInfo.load(album, context: context)
        }
    }

    private var subtitle: String {
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
        HStack(spacing: Spacing.s) {
            Group {
                if let cover = node.cover {
                    Thumbnail(item: cover, side: Thumbnail.folder)
                } else {
                    RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: Thumbnail.folder, height: Thumbnail.folder)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.metadata)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.count == 1 ? "1 photo" : "\(node.count.formatted()) photos")
                    .font(.smallMetadata)
                    .foregroundStyle(Theme.inkSecondary)
                if !node.children.isEmpty {
                    FolderToggle(count: node.children.count, isExpanded: isExpanded, action: onToggle)
                }
            }
            Spacer(minLength: 0)
            // Keep just this folder (and its subfolders) offline.
            AlbumStatusButton(album: album, folder: node.path)
        }
        .padding(.leading, CGFloat(depth) * Spacing.l)
    }
}
