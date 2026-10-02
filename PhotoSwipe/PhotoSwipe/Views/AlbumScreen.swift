import SwiftUI

/// Hosts one connected album's session.
struct AlbumScreen: View {
    @StateObject private var vm: SwipeDeckViewModel

    init(album: ConnectedAlbum) {
        _vm = StateObject(wrappedValue: SwipeDeckViewModel(album: album))
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
            case .swiping:
                SwipeDeckView(vm: vm)
            case .done:
                MessageView(icon: "checkmark.circle", title: "All rated",
                            message: "You've been through every photo.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
        .task { vm.load() }
    }
}
