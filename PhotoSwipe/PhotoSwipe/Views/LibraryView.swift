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
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 18, trailing: 20))
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
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.paper)

                Button { Haptics.tap(); showConnect = true } label: { connectRow }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.paper)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
            .background(Theme.paper)
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
        HStack(alignment: .center) {
            Text("My Photos")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.ink)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var connectRow: some View {
        HStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface)
                .frame(width: 88, height: 88)
                .overlay(Image(systemName: "plus").font(.system(size: 26, weight: .light)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect Album")
                    .font(.system(size: 17))
                Text("Add from Apple Photos or Dropbox")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
        }
        .foregroundStyle(Theme.ink)
        .contentShape(Rectangle())
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
        HStack(spacing: 18) {
            Group {
                if let cover = info?.cover {
                    Thumbnail(item: cover, side: 88, cornerRadius: 8)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: 88, height: 88)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(info?.name ?? album.name)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 0) {
                    Text(subtitle)
                    if folderCount > 0 {
                        FolderToggle(count: folderCount, isExpanded: isExpanded, action: onToggleFolders)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 8)
            if album.source == .dropbox {
                // Album-level offline/sync control.
                AlbumStatusButton(album: album, size: 20)
            }
        }
        .padding(.vertical, 2)
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
            HStack(spacing: 3) {
                Text("\(count) folder\(count == 1 ? "" : "s")")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(Theme.ink)
            .padding(.vertical, 6)
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
        HStack(spacing: 14) {
            Group {
                if let cover = node.cover {
                    Thumbnail(item: cover, side: 52, cornerRadius: 6)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.surface).frame(width: 52, height: 52)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Label(node.name, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 0) {
                    Text(node.count == 1 ? "1 photo" : "\(node.count.formatted()) photos")
                    if !node.children.isEmpty {
                        FolderToggle(count: node.children.count, isExpanded: isExpanded, action: onToggle)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 0)
            // Keep just this folder (and its subfolders) offline.
            AlbumStatusButton(album: album, folder: node.path, size: 18)
        }
        .padding(.leading, CGFloat(depth) * 28)
        .padding(.vertical, 1)
    }
}
