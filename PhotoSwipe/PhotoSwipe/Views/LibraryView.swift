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

    var body: some View {
        NavigationStack {
            List {
                header
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 18, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.paper)

                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        AlbumRow(album: album)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Disconnect", role: .destructive) { disconnect(album) }
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
            .background(Theme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ConnectedAlbum.self) { album in
                AlbumScreen(album: album)
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

    private func disconnect(_ album: ConnectedAlbum) {
        context.delete(album)
        try? context.save()
    }
}

/// One connected album: cover, name, photo count. Shows "Unavailable" if the
/// album no longer exists at its source.
struct AlbumRow: View {
    let album: ConnectedAlbum
    @State private var info: AlbumInfo?

    var body: some View {
        HStack(spacing: 18) {
            Group {
                if let cover = info?.cover {
                    Thumbnail(asset: cover, side: 88, cornerRadius: 8)
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
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.vertical, 2)
        .task(id: album.externalID) { info = AlbumInfo.load(album) }
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
    var cover: PHAsset?
    var isAvailable = false

    @MainActor
    static func load(_ album: ConnectedAlbum) -> AlbumInfo {
        switch album.source {
        case .applePhotos:
            let service = PhotoLibraryService()
            guard let collection = service.album(withLocalIdentifier: album.externalID) else {
                return AlbumInfo()
            }
            return AlbumInfo(name: collection.localizedTitle,
                             count: service.photoCount(in: collection),
                             cover: service.coverPhoto(of: collection),
                             isAvailable: true)
        case .dropbox:
            return AlbumInfo()
        }
    }
}
