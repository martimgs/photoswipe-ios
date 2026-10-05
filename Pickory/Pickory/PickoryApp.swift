import SwiftUI
import SwiftData

@main
struct PickoryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var dropbox = DropboxAuth.shared
    @StateObject private var sync = DropboxSyncEngine.shared
    @AppStorage(Appearance.key) private var appearance = Appearance.automatic.rawValue
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: ConnectedAlbum.self, PhotoState.self, DropboxFile.self, SyncQueueEntry.self)
        } catch {
            fatalError("Could not open the Pickory database: \(error)")
        }
        DropboxAuth.setUp()
        _ = DropboxService.shared      // registers Dropbox thumbnails with ImageLoader
        _ = Connectivity.shared
        DropboxSyncEngine.shared.start(container: container)
        OfflineDownloadManager.shared.start(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(dropbox)
                .environmentObject(sync)
                .onOpenURL { dropbox.handle($0) }
                .task { dropbox.refresh() }
                .onChange(of: dropbox.isSignedIn) { _, signedIn in
                    if signedIn { sync.scheduleSync() }
                }
                .onAppear { Appearance.current.apply() }
                .onChange(of: appearance) { Appearance.current.apply() }
        }
        .modelContainer(container)
    }
}
