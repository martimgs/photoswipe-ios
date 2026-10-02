import SwiftUI
import SwiftData

/// Hosts one connected album's session. The swipe and grid screens share the
/// same view model.
struct AlbumScreen: View {
    @StateObject private var vm: AlbumSessionViewModel
    @Environment(\.modelContext) private var context
    @State private var showGrid = false

    init(album: ConnectedAlbum) {
        _vm = StateObject(wrappedValue: AlbumSessionViewModel(album: album))
    }

    /// Dropbox: pick up new/removed files whenever the album opens online.
    private func checkForChanges() async {
        guard vm.album.source == .dropbox, Connectivity.shared.isOnline,
              DropboxAuth.shared.isSignedIn else { return }
        if (try? await DropboxService.shared.checkForChanges(vm.album, context: context)) != nil {
            vm.reloadPhotos()
            // Offline albums: fetch only the files that are new.
            OfflineDownloadManager.shared.downloadNewFiles(vm.album)
        }
    }

    var body: some View {
        Group {
            switch vm.phase {
            case .loading:
                Theme.paper
            case .unavailable:
                MessageView(icon: "questionmark.folder", title: "Album unavailable",
                            message: "This album no longer exists in Photos. You can disconnect it from My Photos.")
            case .empty:
                MessageView(icon: "photo", title: "No photos",
                            message: "This album has no photos yet.")
            case .ready:
                SwipeDeckView(vm: vm) { showGrid = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
        .navigationDestination(isPresented: $showGrid) {
            RatingGridView(vm: vm)
        }
        .task {
            if vm.phase == .loading { vm.load(context: context) }
            await checkForChanges()
        }
    }
}
