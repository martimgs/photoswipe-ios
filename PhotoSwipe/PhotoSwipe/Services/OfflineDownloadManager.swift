import Foundation
import SwiftData
import SwiftyDropbox
import os

/// Downloads Dropbox albums for offline use with SwiftyDropbox's background
/// URLSession client, so downloads continue when the app is in the
/// background and reconnect after a relaunch. Files go to Application
/// Support (`OfflineStore`), never Caches.
///
/// Pausing cancels the outstanding requests; finished files are kept and a
/// file that was mid-download starts over on resume.
@MainActor
final class OfflineDownloadManager: ObservableObject {
    static let shared = OfflineDownloadManager()

    static let backgroundSessionIdentifier = "PhotoSwipe.DropboxDownloads"
    static let qualityKey = "downloadQuality"

    struct Progress: Equatable {
        var done: Int
        var total: Int
        var failed: Int
        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    /// Live progress per album (`ConnectedAlbum.externalID`).
    @Published private(set) var progress: [String: Progress] = [:]

    private var container: ModelContainer?
    private var context: ModelContext? { container?.mainContext }
    /// Outstanding requests per album, so pause can cancel them.
    private var outstanding: [String: [String: () -> Void]] = [:]
    private let log = Logger(subsystem: "PhotoSwipe", category: "OfflineDownloads")

    private init() {}

    static var defaultQuality: DownloadQuality {
        DownloadQuality(rawValue: UserDefaults.standard.string(forKey: qualityKey) ?? "") ?? .optimized
    }

    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        // Albums left "downloading" by a previous run resume once requests
        // have reconnected (or immediately if none survived).
        Task {
            try? await Task.sleep(for: .seconds(2))
            for album in albums() where album.offlineState == .downloading {
                resume(album)
            }
        }
    }

    // MARK: Status

    enum Status: Equatable {
        case onlineOnly
        case downloading(Progress)
        case paused(Progress)
        case pending(Int)
        case offline
    }

    func status(of album: ConnectedAlbum, pending: Int) -> Status {
        switch album.offlineState {
        case .downloading: return .downloading(progress[album.externalID] ?? currentProgress(album))
        case .paused: return .paused(progress[album.externalID] ?? currentProgress(album))
        default: break
        }
        if pending > 0 { return .pending(pending) }
        return album.offlineState == .offline ? .offline : .onlineOnly
    }

    private func currentProgress(_ album: ConnectedAlbum) -> Progress {
        let files = files(of: album)
        return Progress(done: files.filter { OfflineStore.hasLocalCopy($0.fileID) }.count,
                        total: files.count, failed: 0)
    }

    // MARK: Actions

    /// Online only -> Downloading, using the default quality from Settings.
    func download(_ album: ConnectedAlbum) {
        album.offlineQualityRaw = Self.defaultQuality.rawValue
        album.offlineState = .downloading
        try? context?.save()
        enqueueMissing(album)
    }

    func pause(_ album: ConnectedAlbum) {
        album.offlineState = .paused
        try? context?.save()
        outstanding[album.externalID]?.values.forEach { $0() }
        outstanding[album.externalID] = nil
    }

    func resume(_ album: ConnectedAlbum) {
        album.offlineState = .downloading
        try? context?.save()
        enqueueMissing(album)
    }

    /// Offline -> Online only. Deletes only the app's own copies; Dropbox
    /// files are never touched and ratings are kept. Callers must make sure
    /// no changes are pending first.
    func removeDownloads(_ album: ConnectedAlbum) {
        pause(album)
        for file in files(of: album) {
            OfflineStore.removeLocalCopy(file.fileID)
            file.localFileName = nil
            file.localQualityRaw = nil
            file.localSize = 0
        }
        album.offlineState = .onlineOnly
        album.offlineQualityRaw = nil
        progress[album.externalID] = nil
        try? context?.save()
        ImageLoader.shared.forgetAll()
    }

    /// After "check for changes" on an offline album: fetch just the new files.
    func downloadNewFiles(_ album: ConnectedAlbum) {
        guard album.offlineState == .offline || album.offlineState == .downloading else { return }
        let missing = files(of: album).filter { !OfflineStore.hasLocalCopy($0.fileID) }
        guard !missing.isEmpty else { return }
        album.offlineState = .downloading
        try? context?.save()
        enqueueMissing(album)
    }

    // MARK: Queueing

    private func enqueueMissing(_ album: ConnectedAlbum) {
        let albumID = album.externalID
        let all = files(of: album)
        let missing = all.filter { !OfflineStore.hasLocalCopy($0.fileID) }
        progress[albumID] = Progress(done: all.count - missing.count, total: all.count, failed: 0)
        guard let client = DropboxClientsManager.authorizedBackgroundClient else {
            log.error("No background client; pausing \(albumID, privacy: .public)")
            album.offlineState = .paused
            try? context?.save()
            return
        }
        if missing.isEmpty { finishIfComplete(album); return }
        let quality = DownloadQuality(rawValue: album.offlineQualityRaw ?? "") ?? Self.defaultQuality
        for file in missing where outstanding[albumID]?[file.fileID] == nil {
            enqueue(fileID: file.fileID, albumID: albumID, quality: quality, client: client)
        }
    }

    private func enqueue(fileID: String, albumID: String, quality: DownloadQuality, client: DropboxClient) {
        let destination = OfflineStore.localURL(for: fileID)
        let tag = Self.persistedTag(albumID: albumID, fileID: fileID, quality: quality)
        switch quality {
        case .optimized:
            let request = client.files.getThumbnailV2(
                resource: .path(fileID), format: .jpeg, size: .w2048h1536, mode: .bestfit,
                overwrite: true, destination: destination)
                .persistingString(string: tag)
            track(albumID, fileID) { request.cancel() }
            request.response { [weak self] _, error in
                Task { @MainActor in
                    // Formats Dropbox can't thumbnail (e.g. HEIC) fall back to the original.
                    if error != nil, let self, self.isActive(albumID) {
                        self.untrack(albumID, fileID)
                        self.enqueue(fileID: fileID, albumID: albumID, quality: .originals, client: client)
                    } else {
                        self?.completed(fileID: fileID, albumID: albumID, quality: .optimized, error: error.map { "\($0)" })
                    }
                }
            }
        case .originals:
            let request = client.files.download(path: fileID, overwrite: true, destination: destination)
                .persistingString(string: tag)
            track(albumID, fileID) { request.cancel() }
            request.response { [weak self] _, error in
                Task { @MainActor in
                    self?.completed(fileID: fileID, albumID: albumID, quality: .originals, error: error.map { "\($0)" })
                }
            }
        }
    }

    private func completed(fileID: String, albumID: String, quality: DownloadQuality, error: String?) {
        untrack(albumID, fileID)
        guard let album = album(albumID) else { return }
        if let error {
            if isActive(albumID) {
                log.error("Download failed \(fileID, privacy: .public): \(error, privacy: .public)")
                progress[albumID]?.failed += 1
            }
        } else if let file = files(of: album).first(where: { $0.fileID == fileID }) {
            file.localFileName = OfflineStore.fileName(for: fileID)
            file.localQualityRaw = quality.rawValue
            let attrs = try? FileManager.default.attributesOfItem(atPath: OfflineStore.localURL(for: fileID).path)
            file.localSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            progress[albumID]?.done += 1
            try? context?.save()
        }
        finishIfComplete(album)
    }

    /// All requests settled: everything local -> Offline; failures -> Paused
    /// (tap resumes, retrying just the failed files).
    private func finishIfComplete(_ album: ConnectedAlbum) {
        guard album.offlineState == .downloading, outstanding[album.externalID]?.isEmpty ?? true else { return }
        let allLocal = files(of: album).allSatisfy { OfflineStore.hasLocalCopy($0.fileID) }
        album.offlineState = allLocal ? .offline : .paused
        progress[album.externalID]?.failed = 0
        try? context?.save()
        objectWillChange.send()
    }

    private func isActive(_ albumID: String) -> Bool { album(albumID)?.offlineState == .downloading }

    private func track(_ albumID: String, _ fileID: String, cancel: @escaping () -> Void) {
        outstanding[albumID, default: [:]][fileID] = cancel
    }

    private func untrack(_ albumID: String, _ fileID: String) {
        outstanding[albumID]?[fileID] = nil
    }

    // MARK: Reconnection after relaunch

    static func persistedTag(albumID: String, fileID: String, quality: DownloadQuality) -> String {
        [albumID, fileID, quality.rawValue].joined(separator: "|")
    }

    /// Reattach handlers to background requests from a previous app session.
    nonisolated static func reconnect(_ results: [Result<DropboxBaseRequestBox, ReconnectionError>]) {
        Task { @MainActor in shared.reconnect(results) }
    }

    private func reconnect(_ results: [Result<DropboxBaseRequestBox, ReconnectionError>]) {
        for case .success(let box) in results {
            switch box {
            case .files_download(let request):
                attach(request.clientPersistedString, cancel: { request.cancel() }) { handler in
                    request.response { _, error in handler(error.map { "\($0)" }) }
                }
            case .files_getThumbnailV2(let request):
                attach(request.clientPersistedString, cancel: { request.cancel() }) { handler in
                    request.response { _, error in handler(error.map { "\($0)" }) }
                }
            default:
                break
            }
        }
    }

    private func attach(_ tag: String?, cancel: @escaping () -> Void,
                        respond: (@escaping (String?) -> Void) -> Void) {
        let parts = tag?.split(separator: "|", maxSplits: 2).map(String.init) ?? []
        guard parts.count == 3, let quality = DownloadQuality(rawValue: parts[2]) else { return }
        let (albumID, fileID) = (parts[0], parts[1])
        track(albumID, fileID, cancel: cancel)
        respond { [weak self] error in
            Task { @MainActor in self?.completed(fileID: fileID, albumID: albumID, quality: quality, error: error) }
        }
    }

    // MARK: Data

    private func albums() -> [ConnectedAlbum] {
        let raw = PhotoSourceKind.dropbox.rawValue
        return (try? context?.fetch(FetchDescriptor<ConnectedAlbum>(
            predicate: #Predicate { $0.sourceRaw == raw }))) ?? []
    }

    private func album(_ albumID: String) -> ConnectedAlbum? {
        albums().first { $0.externalID == albumID }
    }

    private func files(of album: ConnectedAlbum) -> [DropboxFile] {
        let albumID = album.externalID
        return (try? context?.fetch(FetchDescriptor<DropboxFile>(
            predicate: #Predicate { $0.albumID == albumID }))) ?? []
    }

    // MARK: Size estimates (Settings)

    /// Bytes to download every connected Dropbox album at each quality.
    /// Originals is exact (sum of file sizes). Optimized is an estimate:
    /// the average of optimized copies already downloaded, else ~0.6 MB.
    func estimatedSizes() -> (optimized: Int64, originals: Int64, photos: Int) {
        guard let context else { return (0, 0, 0) }
        let albumIDs = Set(albums().map(\.externalID))
        let files = ((try? context.fetch(FetchDescriptor<DropboxFile>())) ?? []).filter { albumIDs.contains($0.albumID) }
        let originals = files.reduce(Int64(0)) { $0 + $1.size }
        let optimizedSamples = files.filter { $0.localQualityRaw == DownloadQuality.optimized.rawValue && $0.localSize > 0 }
        let perPhoto = optimizedSamples.isEmpty ? 600_000
            : optimizedSamples.reduce(Int64(0)) { $0 + $1.localSize } / Int64(optimizedSamples.count)
        // A Dropbox-rendered copy is never larger than the original.
        let optimized = files.reduce(Int64(0)) { $0 + min(perPhoto, $1.size) }
        return (optimized, originals, files.count)
    }
}
