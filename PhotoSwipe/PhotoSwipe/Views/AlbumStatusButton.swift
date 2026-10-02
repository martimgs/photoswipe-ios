import SwiftUI

/// The one offline/sync button for a Dropbox album. Its icon shows the
/// album's state; tapping performs the next action:
/// - Online only (cloud): download for offline use
/// - Downloading (progress ring): pause / resume
/// - Changes pending (sync + count): sync now, or explain it'll sync later
/// - Offline & synced (checkmark): confirm, then remove downloads
struct AlbumStatusButton: View {
    let album: ConnectedAlbum
    @ObservedObject private var downloads = OfflineDownloadManager.shared
    @ObservedObject private var sync = DropboxSyncEngine.shared
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var alert: String?
    @State private var confirmRemove = false

    private var status: OfflineDownloadManager.Status {
        downloads.status(of: album, pending: sync.pendingCountByAlbum[album.externalID] ?? 0)
    }

    var body: some View {
        Button(action: tap) {
            AlbumStatusIcon(status: status, size: 19)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AlbumStatusIcon.label(status))
        .accessibilityHint(hint)
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog("Remove downloaded photos?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Downloads", role: .destructive) { remove() }
        } message: {
            Text("The album stays in PhotoSwipe and goes back to Online only. Your ratings are kept, and nothing in Dropbox changes.")
        }
    }

    private var hint: String {
        switch status {
        case .onlineOnly: return "Downloads the album for offline use"
        case .downloading: return "Pauses the download"
        case .paused: return "Resumes the download"
        case .pending: return "Syncs ratings to Dropbox now"
        case .offline: return "Removes the downloaded photos"
        }
    }

    private func tap() {
        Haptics.tap()
        switch status {
        case .onlineOnly:
            guard connectivity.isOnline else { alert = "Connect to the internet to download this album."; return }
            guard DropboxAuth.shared.isSignedIn else { alert = "Sign in to Dropbox in Settings to download."; return }
            downloads.download(album)
        case .downloading:
            downloads.pause(album)
        case .paused:
            guard connectivity.isOnline else { alert = "Downloads resume when you're back online."; return }
            downloads.resume(album)
        case .pending:
            guard connectivity.isOnline else { alert = "Will sync when you're back online."; return }
            Task { await sync.syncNow() }
        case .offline:
            confirmRemove = true
        }
    }

    private func remove() {
        // Never remove files while changes are pending: sync first.
        guard (sync.pendingCountByAlbum[album.externalID] ?? 0) == 0 else {
            alert = "Some ratings haven't synced yet. They'll sync first; try again after."
            Task { await sync.syncNow() }
            return
        }
        downloads.removeDownloads(album)
    }
}

/// The status icon on its own (non-tappable), used on Library rows too.
struct AlbumStatusIcon: View {
    let status: OfflineDownloadManager.Status
    var size: CGFloat = 15

    var body: some View {
        switch status {
        case .onlineOnly:
            Image(systemName: "icloud").font(.system(size: size, weight: .regular))
                .foregroundStyle(Theme.ink)
        case .downloading(let p), .paused(let p):
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: 2)
                Circle().trim(from: 0, to: max(p.fraction, 0.03))
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: p.fraction)
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }
            .frame(width: size * 1.25, height: size * 1.25)
        case .pending(let count):
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Theme.ink)
                .overlay(alignment: .topTrailing) {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: max(size * 0.5, 9), weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.paper)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.ink, in: Capsule())
                        .offset(x: size * 0.55, y: -size * 0.45)
                }
        case .offline:
            Image(systemName: "checkmark.icloud").font(.system(size: size, weight: .regular))
                .foregroundStyle(Theme.ink)
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
