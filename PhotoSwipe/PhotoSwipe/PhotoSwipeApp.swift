import SwiftUI
import SwiftData

@main
struct PhotoSwipeApp: App {
    @StateObject private var dropbox = DropboxAuth.shared
    @StateObject private var sync = DropboxSyncEngine.shared
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: ConnectedAlbum.self, PhotoState.self, DropboxFile.self, SyncQueueEntry.self)
        } catch {
            fatalError("Could not open the PhotoSwipe database: \(error)")
        }
        DropboxAuth.setUp()
        _ = DropboxService.shared      // registers Dropbox thumbnails with ImageLoader
        _ = Connectivity.shared
        DropboxSyncEngine.shared.start(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
                .environmentObject(dropbox)
                .environmentObject(sync)
                .onOpenURL { dropbox.handle($0) }
                .task { dropbox.refresh() }
                .onChange(of: dropbox.isSignedIn) { _, signedIn in
                    if signedIn { sync.scheduleSync() }
                }
        }
        .modelContainer(container)
    }
}
