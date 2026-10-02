import Foundation

/// A part of an album: nil = the whole album, otherwise a subfolder path
/// ("Day 1/Morning") including everything below it.
enum FolderScope {
    static func contains(_ scope: String?, folder: String) -> Bool {
        guard let scope, !scope.isEmpty else { return true }
        return folder == scope || folder.hasPrefix(scope + "/")
    }

    /// "a/b" -> "a", "a" -> "" (the album's top level).
    static func parent(of folder: String) -> String? {
        guard !folder.isEmpty else { return nil }
        return folder.split(separator: "/").dropLast().joined(separator: "/")
    }
}
