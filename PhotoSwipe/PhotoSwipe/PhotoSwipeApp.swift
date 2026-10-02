import SwiftUI
import SwiftData

@main
struct PhotoSwipeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
        }
        .modelContainer(for: [ConnectedAlbum.self, PhotoState.self])
    }
}
