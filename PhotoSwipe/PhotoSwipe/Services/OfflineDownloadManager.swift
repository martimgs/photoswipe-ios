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
        if OfflineStore.removeLegacyFiles() {
            // Re-download albums that were (partly) offline under the old naming.
            for album in albums() where album.offlineState != .onlineOnly {
                album.offlineState = .downloading
                for file in files(of: album) {
                    file.localFileName = nil
                    file.localSize = 0
                }
            }
            try? context?.save()
            ImageLoader.shared.forgetAll()
        }
        // Albums left "downloading" by a previous run resume once requests
        // have reconnected (or immediately if none survived).
        Task {
            try? await Task.sleep(for: .seconds(2))
            for album in albums() where album.offlineState == .downloading {
                resume(album)
            }
            removeStaleParts()
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
        waiting[album.externalID] = nil
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

    /// Files waiting to start, per album. At most `maxConcurrent` requests
    /// run at once (Dropbox rate-limits bursts of thumbnail requests).
    private var waiting: [String: [String]] = [:]
    private var attempts: [String: Int] = [:]
    private static let maxConcurrent = 6
    private static let maxAttempts = 3

    private var runningCount: Int { outstanding.values.reduce(0) { $0 + $1.count } }

    private func enqueueMissing(_ album: ConnectedAlbum) {
        let albumID = album.externalID
        let all = files(of: album)
        let missing = all.filter { !OfflineStore.hasLocalCopy($0.fileID) }
        progress[albumID] = Progress(done: all.count - missing.count, total: all.count, failed: 0)
        guard DropboxClientsManager.authorizedBackgroundClient != nil else {
            log.error("No background client; pausing \(albumID, privacy: .public)")
            album.offlineState = .paused
            try? context?.save()
            return
        }
        if missing.isEmpty { finishIfComplete(album); return }
        let running = Set(outstanding[albumID]?.keys.map { $0 } ?? [])
        waiting[albumID] = missing.map(\.fileID).filter { !running.contains($0) }
        for id in waiting[albumID] ?? [] { attempts[id] = 0 }
        log.info("Queue \(albumID, privacy: .public): \(missing.count) missing, \(running.count) running, \(self.runningCount) total running")
        pump()
    }

    /// Start waiting downloads up to the concurrency limit.
    private func pump() {
        guard let client = DropboxClientsManager.authorizedBackgroundClient else { return }
        while runningCount < Self.maxConcurrent,
              let (albumID, fileID) = nextWaiting() {
            guard let album = album(albumID) else { continue }
            let quality = DownloadQuality(rawValue: album.offlineQualityRaw ?? "") ?? Self.defaultQuality
            start(fileID: fileID, albumID: albumID, quality: quality, client: client)
        }
    }

    private func nextWaiting() -> (String, String)? {
        for (albumID, ids) in waiting where isActive(albumID) {
            var ids = ids
            while let id = ids.first {
                ids.removeFirst()
                if !OfflineStore.hasLocalCopy(id), outstanding[albumID]?[id] == nil {
                    waiting[albumID] = ids
                    return (albumID, id)
                }
            }
            waiting[albumID] = nil
        }
        return nil
    }

    /// Each request writes to its own temporary file, which then replaces
    /// the final file. Duplicate requests (e.g. a background request from
    /// a previous session finishing after a resume) can't collide.
    private func start(fileID: String, albumID: String, quality: DownloadQuality, client: DropboxClient) {
        let temp = OfflineStore.directory.appendingPathComponent(".part-\(UUID().uuidString)")
        let tag = Self.persistedTag(albumID: albumID, fileID: fileID, quality: quality, temp: temp)
        switch quality {
        case .optimized:
            let request = client.files.getThumbnailV2(
                resource: .path(fileID), format: .jpeg, size: .w2048h1536, mode: .bestfit,
                overwrite: true, destination: temp)
                .persistingString(string: tag)
            track(albumID, fileID) { request.cancel() }
            request.response { [weak self] _, error in
                Task { @MainActor in
                    self?.completed(fileID: fileID, albumID: albumID, quality: .optimized,
                                    temp: temp, error: error.map { "\($0)" }, thumbnailFailed: error != nil)
                }
            }
        case .originals:
            let request = client.files.download(path: fileID, overwrite: true, destination: temp)
                .persistingString(string: tag)
            track(albumID, fileID) { request.cancel() }
            request.response { [weak self] _, error in
                Task { @MainActor in
                    self?.completed(fileID: fileID, albumID: albumID, quality: .originals,
                                    temp: temp, error: error.map { "\($0)" }, thumbnailFailed: false)
                }
            }
        }
    }

    private func completed(fileID: String, albumID: String, quality: DownloadQuality,
                           temp: URL?, error: String?, thumbnailFailed: Bool) {
        untrack(albumID, fileID)
        defer { pump() }
        let final = OfflineStore.localURL(for: fileID)
        if error == nil, let temp, FileManager.default.fileExists(atPath: temp.path) {
            do {
                if FileManager.default.fileExists(atPath: final.path) {
                    _ = try FileManager.default.replaceItemAt(final, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: final)
                }
            } catch {
                log.error("Couldn't save \(fileID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let temp { try? FileManager.default.removeItem(at: temp) }
        guard let album = album(albumID) else { return }

        if OfflineStore.hasLocalCopy(fileID) {
            // Success — or a duplicate request for a file another one saved.
            if let file = files(of: album).first(where: { $0.fileID == fileID }), file.localFileName == nil {
                file.localFileName = OfflineStore.fileName(for: fileID)
                file.localQualityRaw = quality.rawValue
                let attrs = try? FileManager.default.attributesOfItem(atPath: final.path)
                file.localSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                try? context?.save()
            }
            refreshProgress(album)
        } else if isActive(albumID), let error {
            log.error("Download failed \(fileID, privacy: .public): \(error, privacy: .public)")
            attempts[fileID, default: 0] += 1
            if thumbnailFailed && attempts[fileID, default: 0] == 1,
               let client = DropboxClientsManager.authorizedBackgroundClient {
                // Formats Dropbox can't render (e.g. HEIC, >20 MB): use the original.
                start(fileID: fileID, albumID: albumID, quality: .originals, client: client)
                return
            }
            if attempts[fileID, default: 0] < Self.maxAttempts {
                waiting[albumID, default: []].append(fileID)
            } else {
                progress[albumID]?.failed += 1
            }
        }
        finishIfComplete(album)
    }

    private func refreshProgress(_ album: ConnectedAlbum) {
        let all = files(of: album)
        let done = all.filter { OfflineStore.hasLocalCopy($0.fileID) }.count
        progress[album.externalID] = Progress(done: done, total: all.count,
                                              failed: progress[album.externalID]?.failed ?? 0)
    }

    /// Nothing running or waiting: everything local -> Offline; otherwise
    /// Paused (tap resumes, retrying just the missing files).
    private func finishIfComplete(_ album: ConnectedAlbum) {
        let albumID = album.externalID
        guard album.offlineState == .downloading,
              outstanding[albumID]?.isEmpty ?? true,
              waiting[albumID]?.isEmpty ?? true else { return }
        let allLocal = files(of: album).allSatisfy { OfflineStore.hasLocalCopy($0.fileID) }
        album.offlineState = allLocal ? .offline : .paused
        progress[albumID]?.failed = 0
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

    static func persistedTag(albumID: String, fileID: String, quality: DownloadQuality, temp: URL) -> String {
        [albumID, fileID, quality.rawValue, temp.lastPathComponent].joined(separator: "|")
    }

    /// Reattach handlers to background requests from a previous app session.
    nonisolated static func reconnect(_ results: [Result<DropboxBaseRequestBox, ReconnectionError>]) {
        Task { @MainActor in shared.reconnect(results) }
    }

    private func reconnect(_ results: [Result<DropboxBaseRequestBox, ReconnectionError>]) {
        log.info("Reconnect: \(results.count) background requests from a previous session")
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
        let parts = tag?.split(separator: "|", maxSplits: 3).map(String.init) ?? []
        guard parts.count >= 3, let quality = DownloadQuality(rawValue: parts[2]) else { return }
        let (albumID, fileID) = (parts[0], parts[1])
        let temp = parts.count == 4 ? OfflineStore.directory.appendingPathComponent(parts[3]) : nil
        track(albumID, fileID, cancel: cancel)
        respond { [weak self] error in
            Task { @MainActor in
                self?.completed(fileID: fileID, albumID: albumID, quality: quality,
                                temp: temp, error: error, thumbnailFailed: false)
            }
        }
    }

    /// Temporary files not owned by a running request (left by a crash or
    /// a cancelled request) are removed.
    private func removeStaleParts() {
        guard runningCount == 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: OfflineStore.directory.path) else { return }
        for name in names where name.hasPrefix(".part-") {
            try? FileManager.default.removeItem(at: OfflineStore.directory.appendingPathComponent(name))
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
