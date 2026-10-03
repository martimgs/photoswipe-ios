import Foundation

/// Where the album screen opens: a whole album, or one subfolder of a
/// Dropbox album (that folder and everything below it).
struct AlbumRoute: Hashable {
    let album: ConnectedAlbum
    /// Relative subfolder path, nil = whole album.
    let folder: String?

    init(album: ConnectedAlbum, folder: String? = nil) {
        self.album = album
        self.folder = folder
    }
}

/// One subfolder of a Dropbox album, built from its files' folder paths.
/// Only folders that contain photos (directly or below) appear.
struct FolderNode: Identifiable {
    let path: String          // "Day 1/Morning"
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var count = 0             // photos in this folder and below
    var cover: PhotoItem?
    var children: [FolderNode] = []
    var id: String { path }

    /// Builds the tree of subfolders below the album root.
    static func tree(from items: [PhotoItem]) -> [FolderNode] {
        var nodes: [String: FolderNode] = [:]
        for item in items where !item.folder.isEmpty {
            let parts = item.folder.split(separator: "/").map(String.init)
            for depth in 1...parts.count {
                let path = parts[0..<depth].joined(separator: "/")
                var node = nodes[path] ?? FolderNode(path: path)
                node.count += 1
                if node.cover == nil { node.cover = item }
                nodes[path] = node
            }
        }
        func children(of parent: String?) -> [FolderNode] {
            nodes.values
                .filter { node in
                    let parentPath = node.path.split(separator: "/").dropLast().joined(separator: "/")
                    return parent == nil ? !node.path.contains("/") : parentPath == parent
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { node in
                    var n = node
                    n.children = children(of: node.path)
                    return n
                }
        }
        return children(of: nil)
    }
}
