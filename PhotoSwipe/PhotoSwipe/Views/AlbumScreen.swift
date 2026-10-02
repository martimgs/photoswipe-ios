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
            Text("Grid")   // replaced in the next step
        }
        .task { if vm.phase == .loading { vm.load(context: context) } }
    }
}
