import SwiftUI
import SwiftData
import Photos

/// Pick a source, then an album to connect. Apple Photos lists only albums the
/// user created — never the whole library, Recents, or shared albums.
struct ConnectAlbumSheet: View {
    let connected: [ConnectedAlbum]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AppleAlbumPicker(connected: connected) { dismiss() }
                    } label: {
                        sourceRow("photo.on.rectangle", "Apple Photos", "Albums on this \(UIDevice.current.model)")
                    }
                    NavigationLink {
                        DropboxFolderPicker(connected: connected) { dismiss() }
                    } label: {
                        sourceRow("shippingbox", "Dropbox", "Folders in your Dropbox")
                    }
                }
                .listRowBackground(Color.white.opacity(0.6))
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .navigationTitle("Connect Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(Theme.ink)
    }

    private func sourceRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.vertical, 4)
    }
}

/// The user's own Apple Photos albums. Already-connected ones are marked and
/// can't be added twice.
private struct AppleAlbumPicker: View {
    let connected: [ConnectedAlbum]
    let onConnect: () -> Void
    @Environment(\.modelContext) private var context
    @State private var albums: [PHAssetCollection] = []
    @State private var loaded = false

    private let service = PhotoLibraryService()

    var body: some View {
        List {
            if loaded && albums.isEmpty {
                Text("No albums found. Create an album in the Photos app, then come back.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.inkSecondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(albums, id: \.localIdentifier) { album in
                let isConnected = connectedIDs.contains(album.localIdentifier)
                Button { connect(album) } label: {
                    PickerAlbumRow(album: album, isConnected: isConnected)
                }
                .disabled(isConnected)
                .listRowBackground(Color.white.opacity(0.6))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle("Apple Photos")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            albums = service.userAlbums()
                .sorted { ($0.localizedTitle ?? "").localizedStandardCompare($1.localizedTitle ?? "") == .orderedAscending }
            loaded = true
        }
    }

    private var connectedIDs: Set<String> {
        Set(connected.filter { $0.source == .applePhotos }.map(\.externalID))
    }

    private func connect(_ album: PHAssetCollection) {
        context.insert(ConnectedAlbum(source: .applePhotos,
                                      externalID: album.localIdentifier,
                                      name: album.localizedTitle ?? "Untitled"))
        try? context.save()
        Haptics.success()
        onConnect()
    }
}

private struct PickerAlbumRow: View {
    let album: PHAssetCollection
    let isConnected: Bool
    @State private var cover: PhotoItem?
    @State private var count = 0

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let cover {
                    Thumbnail(item: cover, side: 52, cornerRadius: 6)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.surface).frame(width: 52, height: 52)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.localizedTitle ?? "Untitled").font(.system(size: 17))
                Text(count == 1 ? "1 photo" : "\(count.formatted()) photos")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if isConnected {
                Text("Connected")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .foregroundStyle(Theme.ink)
        .task(id: album.localIdentifier) {
            let service = PhotoLibraryService()
            cover = service.coverPhoto(of: album).map(PhotoItem.init(asset:))
            count = service.photoCount(in: album)
        }
    }
}
