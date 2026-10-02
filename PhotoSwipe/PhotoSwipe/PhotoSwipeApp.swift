import SwiftUI
import SwiftData

@main
struct PhotoSwipeApp: App {
    @StateObject private var dropbox = DropboxAuth.shared

    init() {
        DropboxAuth.setUp()
        _ = DropboxService.shared      // registers Dropbox thumbnails with ImageLoader
        _ = Connectivity.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
                .environmentObject(dropbox)
                .onOpenURL { dropbox.handle($0) }
                .task { dropbox.refresh() }
        }
        .modelContainer(for: [ConnectedAlbum.self, PhotoState.self, DropboxFile.self, SyncQueueEntry.self])
    }
}
