import SwiftUI
import SwiftData

/// Browse Dropbox folders and connect one. Connecting downloads nothing:
/// the album starts as "Online only".
struct DropboxFolderPicker: View {
    let connected: [ConnectedAlbum]
    let onConnect: () -> Void
    @EnvironmentObject private var dropbox: DropboxAuth

    var body: some View {
        Group {
            if dropbox.isSignedIn {
                FolderLevel(folder: nil, connected: connected, onConnect: onConnect)
            } else {
                MessageView(icon: "shippingbox", title: "Sign in to Dropbox",
                            message: "Sign in once to browse and connect your Dropbox folders.",
                            button: "Sign In") { dropbox.signIn() }
                    .background(Theme.paper)
                    .navigationTitle("Dropbox")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

/// One folder level: a Connect button for this folder plus its subfolders.
private struct FolderLevel: View {
    /// nil = Dropbox root.
    let folder: DropboxService.Folder?
    let connected: [ConnectedAlbum]
    let onConnect: () -> Void

    @Environment(\.modelContext) private var context
    @State private var subfolders: [DropboxService.Folder] = []
    @State private var imageCount: Int?
    @State private var error: String?
    @State private var loaded = false
    @State private var connecting = false

    private var isConnected: Bool {
        guard let folder else { return false }
        return connected.contains { $0.source == .dropbox && $0.externalID == folder.id }
    }

    var body: some View {
        List {
            if let folder {
                Section {
                    Button { connect(folder) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isConnected ? "Connected" : "Connect “\(folder.name)”")
                                    .font(.body.weight(.medium))
                                Text(countText)
                                    .font(.smallMetadata)
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                            Spacer()
                            if connecting {
                                ProgressView()
                            } else {
                                Image(systemName: isConnected ? "checkmark" : "plus.circle")
                            }
                        }
                        .foregroundStyle(Theme.ink)
                    }
                    .disabled(isConnected || imageCount == 0 || connecting)
                } footer: {
                    Text("Nothing is downloaded. Photos load from Dropbox while you're online until you make the album available offline.")
                }
                .listRowBackground(Theme.surface)
            }

            if let error {
                Text(error).font(.metadata).foregroundStyle(Theme.inkSecondary)
                    .listRowBackground(Color.clear)
            } else if loaded && subfolders.isEmpty {
                Text(folder == nil ? "No folders in your Dropbox." : "No subfolders.")
                    .font(.metadata).foregroundStyle(Theme.inkSecondary)
                    .listRowBackground(Color.clear)
            }

            if !subfolders.isEmpty {
                Section(folder == nil ? "Folders" : "Subfolders") {
                    ForEach(subfolders) { sub in
                        NavigationLink {
                            FolderLevel(folder: sub, connected: connected, onConnect: onConnect)
                        } label: {
                            Label(sub.name, systemImage: "folder")
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle(folder?.name ?? "Dropbox")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var countText: String {
        if connecting { return "Listing photos…" }
        guard let imageCount else { return "Counting photos…" }
        return imageCount == 0 ? "No photos in this folder" :
            imageCount == 1 ? "1 photo" : "\(imageCount.formatted()) photos"
    }

    private func load() async {
        guard !loaded else { return }
        do {
            subfolders = try await DropboxService.shared.subfolders(of: folder?.id ?? "")
            loaded = true
            if let folder { imageCount = try await DropboxService.shared.imageCount(in: folder.id) }
        } catch {
            self.error = Connectivity.shared.isOnline
                ? "Couldn't load folders: \(error.localizedDescription)"
                : "You're offline. Connect to the internet to browse Dropbox."
            loaded = true
        }
    }

    /// Lists the folder's files (metadata only, nothing downloaded) before
    /// closing, so the album shows its photos straight away.
    private func connect(_ folder: DropboxService.Folder) {
        connecting = true
        let album = ConnectedAlbum(source: .dropbox, externalID: folder.id, name: folder.name)
        context.insert(album)
        try? context.save()
        Task {
            do {
                try await DropboxService.shared.checkForChanges(album, context: context)
                Haptics.success()
            } catch {
                // Still connected; the next album open retries the listing.
                self.error = "Connected, but listing photos failed: \(error.localizedDescription)"
            }
            connecting = false
            onConnect()
        }
    }
}
