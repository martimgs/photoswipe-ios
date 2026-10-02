import Foundation

/// Dropbox app settings. The app key is not a secret in the PKCE flow.
/// Keep `Info.plist`'s `db-<appKey>` URL scheme in sync with `appKey`.
enum DropboxConfig {
    static let appKey = "2cxial18cqnu0i9"

    /// Must match the permissions enabled in the Dropbox app console.
    /// Never request files.content.write: the app never changes file contents.
    static let scopes = [
        "account_info.read",     // who is signed in
        "files.metadata.read",   // list folders, read tags, check for changes
        "files.metadata.write",  // add/remove rating tags
        "files.content.read",    // thumbnails and offline downloads
    ]
}
