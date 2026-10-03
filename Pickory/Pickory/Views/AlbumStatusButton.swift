import SwiftUI

/// The one offline/sync button for a Dropbox album. Its icon shows the
/// album's state; tapping performs the next action:
/// - Online only (arrow down in a circle): download for offline use
/// - Downloading (progress ring): pause / resume
/// - Changes to sync (arrow up in a circle): sync now, or explain it'll sync later
/// - Offline & synced (checkmark in a circle): confirm, then sync anything
///   left and remove the downloaded files (back to online only)
struct AlbumStatusButton: View {
    let album: ConnectedAlbum
    /// A subfolder of the album, or nil for the whole album.
    var folder: String? = nil
    /// For folder rows: show nothing when the folder's state is the same as
    /// the whole album's, so only the album row carries the icon.
    var hidesWhenSameAsAlbum = false
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 14
    @ObservedObject private var downloads = OfflineDownloadManager.shared
    @ObservedObject private var sync = DropboxSyncEngine.shared
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var alert: String?
    @State private var confirmRemove = false
    @State private var isRemoving = false

    /// Unsynced changes in the album or one folder (counted only when they can't sync now).
    private func unsynced(in folder: String?) -> Int {
        guard (sync.pendingCountByAlbum[album.externalID] ?? 0) > 0 else { return 0 }
        return downloads.fileIDs(of: album, folder: folder)
            .filter { sync.isUnsynced(fileID: $0, isOnline: connectivity.isOnline) }.count
    }

    /// Changes waiting at all in this album/folder (for "sync before remove").
    private var pendingInScope: Int {
        guard (sync.pendingCountByAlbum[album.externalID] ?? 0) > 0 else { return 0 }
        return downloads.fileIDs(of: album, folder: folder).filter { sync.pendingFileIDs.contains($0) }.count
    }

    private var noun: String { folder == nil ? "album" : "folder" }

    private var status: OfflineDownloadManager.Status {
        downloads.status(of: album, folder: folder, pending: unsynced(in: folder))
    }

    private var isSameAsAlbum: Bool {
        guard folder != nil else { return false }
        let albumStatus = downloads.status(of: album, folder: nil, pending: unsynced(in: nil))
        return AlbumStatusIcon.sameKind(status, albumStatus)
    }

    var body: some View {
        if hidesWhenSameAsAlbum && isSameAsAlbum && !isRemoving {
            EmptyView()
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: tap) {
            Group {
                if isRemoving {
                    ProgressView()
                } else {
                    AlbumStatusIcon(status: status, size: size)
                }
            }
            .frame(width: 36, height: 44)
        }
        .buttonStyle(.borderless)   // tappable inside a List row without opening it
        .disabled(isRemoving)
        .accessibilityLabel(AlbumStatusIcon.label(status))
        .accessibilityHint(hint)
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog("Make this \(noun) online only?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Sync and Remove Downloads", role: .destructive) { Task { await syncAndRemove() } }
        } message: {
            Text("Any rating changes are synced to Dropbox first, then the downloaded photos in this \(noun) are removed from this device. Your ratings stay in Pickory, and nothing in Dropbox is deleted.")
        }
    }

    private var hint: String {
        switch status {
        case .onlineOnly: return "Downloads the \(noun) for offline use"
        case .downloading: return "Pauses the download"
        case .paused: return "Resumes the download"
        case .pending: return "Syncs ratings to Dropbox now"
        case .offline: return "Syncs, then removes the downloaded photos"
        }
    }

    private func tap() {
        Haptics.tap()
        switch status {
        case .onlineOnly:
            guard connectivity.mayTryNetwork else { alert = "Connect to the internet to download this \(noun)."; return }
            guard DropboxAuth.shared.isSignedIn else { alert = "Sign in to Dropbox in Settings to download."; return }
            downloads.download(album, folder: folder)
        case .downloading:
            downloads.pause(album)
        case .paused:
            guard connectivity.mayTryNetwork else { alert = "Downloads resume when you're back online."; return }
            downloads.resume(album)
        case .pending:
            // Always try: the user may know they're online even if the
            // connectivity monitor hasn't noticed yet.
            guard connectivity.mayTryNetwork else { alert = "Will sync when you're back online."; return }
            Task {
                isRemoving = true
                await sync.syncNow(force: true)
                isRemoving = false
                if pendingInScope > 0 {
                    alert = "Couldn't reach Dropbox. Will sync when you're back online."
                }
            }
        case .offline:
            confirmRemove = true
        }
    }

    /// Sync first, then remove. Files are never removed while changes are
    /// still pending (e.g. offline or a failed sync).
    private func syncAndRemove() async {
        isRemoving = true
        defer { isRemoving = false }
        if pendingInScope > 0 {
            guard connectivity.mayTryNetwork else {
                alert = "You're offline. Ratings will sync when you're back online; the downloads are kept until then."
                return
            }
            await sync.syncNow(force: true)
        }
        guard pendingInScope == 0 else {
            alert = "Some ratings couldn't sync yet, so the downloads were kept. Try again in a moment."
            return
        }
        downloads.removeDownloads(album, folder: folder)
        Haptics.success()
    }
}

/// The status icon on its own: a small filled circle in ink or gray with a
/// light glyph, like the Files and Dropbox apps but black and white.
struct AlbumStatusIcon: View {
    let status: OfflineDownloadManager.Status
    var size: CGFloat = 14

    var body: some View {
        switch status {
        case .onlineOnly:
            badge("cloud.circle.fill", Theme.inkTertiary)
        case .downloading(let p), .paused(let p):
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: 1.5)
                Circle().trim(from: 0, to: max(p.fraction, 0.03))
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: p.fraction)
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: size * 0.4, weight: .regular))
                    .foregroundStyle(Theme.ink)
            }
            .frame(width: size, height: size)
        case .pending:
            // The count is in the accessibility label.
            badge("arrow.up.circle.fill", Theme.ink)
        case .offline:
            badge("checkmark.circle.fill", Theme.ink)
        }
    }

    private func badge(_ name: String, _ fill: Color) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.palette)
            .foregroundStyle(Theme.paper, fill)
            .font(.system(size: size, weight: .semibold))
    }

    /// Same state, ignoring counts and progress.
    static func sameKind(_ a: OfflineDownloadManager.Status, _ b: OfflineDownloadManager.Status) -> Bool {
        switch (a, b) {
        case (.onlineOnly, .onlineOnly), (.downloading, .downloading), (.paused, .paused),
             (.pending, .pending), (.offline, .offline):
            return true
        default:
            return false
        }
    }

    private var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    static func label(_ status: OfflineDownloadManager.Status) -> String {
        switch status {
        case .onlineOnly: return "Online only"
        case .downloading(let p): return "Downloading, \(p.done) of \(p.total)"
        case .paused(let p): return "Download paused, \(p.done) of \(p.total)"
        case .pending(let n): return "\(n) change\(n == 1 ? "" : "s") waiting to sync"
        case .offline: return "Available offline, synced"
        }
    }
}
