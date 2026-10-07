import Foundation
import SwiftData
import SwiftyDropbox
import os

/// Downloads Dropbox albums for offline use with SwiftyDropbox's background
/// URLSession client, so downloads continue when the app is in the
/// background and reconnect after a relaunch. Files go to Application
/// Support (`OfflineStore`), never Caches.
///
/// Offline is per folder: each album keeps a list of folders to hold on the
/// device. Downloading a parent adds all its subfolders; files download
/// folder by folder. Pausing cancels the outstanding requests; finished
/// files are kept and a file that was mid-download starts over on resume.
@MainActor
final class OfflineDownloadManager: ObservableObject {
    static let shared = OfflineDownloadManager()

    // Kept from before the rename so in-flight background downloads still resume.
    static let backgroundSessionIdentifier = "PhotoSwipe.DropboxDownloads"
    static let qualityKey = "downloadQuality"

    struct Progress: Equatable {
        var done: Int
        var total: Int
        var failed: Int
        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    /// Bumped whenever a download finishes or offline folders change, so
    /// status icons refresh.
    @Published private(set) var revision = 0

    private var container: ModelContainer?
    private var context: ModelContext? { container?.mainContext }
    /// Outstanding requests per album, so pause can cancel them.
    private var outstanding: [String: [String: () -> Void]] = [:]
    private let log = Logger(subsystem: "Pickory", category: "OfflineDownloads")

    private init() {}

    static var defaultQuality: DownloadQuality {
        DownloadQuality(rawValue: UserDefaults.standard.string(forKey: qualityKey) ?? "") ?? .optimized
    }

    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        NotificationCenter.default.addObserver(forName: Connectivity.becameOnline, object: nil, queue: .main) { _ in
            Task { @MainActor in OfflineDownloadManager.shared.pump() }
        }
        migrateWholeAlbumOffline()
        if OfflineStore.removeLegacyFiles() {
            // Re-download whatever was offline under the old file naming.
            for album in albums() {
                album.downloadPaused = false
                for file in files(of: album) {
                    file.localFileName = nil
                    file.localSize = 0
                }
            }
            try? context?.save()
            indexes = [:]
            ImageLoader.shared.forgetAll()
        }
        // Downloads left unfinished by a previous run resume once requests
        // have reconnected (or immediately if none survived).
        Task {
            try? await Task.sleep(for: .seconds(2))
            for album in albums() where !album.downloadPaused && !album.offlineFolders.isEmpty {
                enqueueMissing(album)
            }
            removeStaleParts()
        }
    }

    /// Albums made offline before per-folder offline: every folder offline.
    private func migrateWholeAlbumOffline() {
        for album in albums() where !album.offlineMigrated {
            if album.offlineState != .onlineOnly {
                album.offlineFolders = Array(Set(files(of: album).map(\.folderPath)))
                album.downloadPaused = album.offlineState == .paused
            }
            album.offlineMigrated = true
        }
        try? context?.save()
    }

    // MARK: Status

    enum Status: Equatable {
        case onlineOnly
        case downloading(Progress)
        case paused(Progress)
        case pending(Int)
        case offline
    }

    /// State of an album or one of its folders (`folder` nil = whole album).
    /// Downloaded = `DropboxFile.localFileName` is set. Read from the
    /// in-memory index: every status icon asks on each refresh, so this
    /// must not fetch or touch the disk.
    func status(of album: ConnectedAlbum, folder: String? = nil, pending: Int) -> Status {
        _ = revision
        let wanted = Set(album.offlineFolders)
        var scope = 0, inList = 0, done = 0
        for (path, count) in index(of: album).counts where FolderScope.contains(folder, folder: path) {
            scope += count.total
            if wanted.contains(path) {
                inList += count.total
                done += count.local
            }
        }
        if done < inList {
            let p = Progress(done: done, total: inList, failed: 0)
            return album.downloadPaused ? .paused(p) : .downloading(p)
        }
        if pending > 0 { return .pending(pending) }
        if scope > 0 && inList == scope { return .offline }
        return .onlineOnly
    }

    /// File IDs in an album or folder (for per-scope unsynced counts).
    func fileIDs(of album: ConnectedAlbum, folder: String?) -> [String] {
        index(of: album).idsByFolder.flatMap { FolderScope.contains(folder, folder: $0) ? $1 : [] }
    }

    /// Folder paths that exist (contain photos) in an album or folder.
    private func folderPaths(of album: ConnectedAlbum, under folder: String?) -> Set<String> {
        Set(index(of: album).counts.keys.filter { FolderScope.contains(folder, folder: $0) })
    }

    // MARK: Index

    /// Per-album summary of its `DropboxFile` records, kept in memory and
    /// updated as downloads finish.
    private struct Index {
        struct Count { var total = 0, local = 0 }
        var folderOf: [String: String] = [:]   // file ID -> folder path
        var local: Set<String> = []            // downloaded file IDs
        var counts: [String: Count] = [:]      // folder path -> files
        var idsByFolder: [String: [String]] = [:]

        mutating func markLocal(_ fileID: String) {
            guard let folder = folderOf[fileID], local.insert(fileID).inserted else { return }
            counts[folder, default: Count()].local += 1
        }
    }

    private var indexes: [String: Index] = [:]

    private func index(of album: ConnectedAlbum) -> Index {
        if let index = indexes[album.externalID] { return index }
        var index = Index()
        for file in files(of: album) {
            index.folderOf[file.fileID] = file.folderPath
            index.idsByFolder[file.folderPath, default: []].append(file.fileID)
            index.counts[file.folderPath, default: Index.Count()].total += 1
            if file.localFileName != nil || unsaved[file.fileID] != nil {
                index.local.insert(file.fileID)
                index.counts[file.folderPath, default: Index.Count()].local += 1
            }
        }
        indexes[album.externalID] = index
        return index
    }

    /// An album's file records changed outside this class (check for
    /// changes, disconnect): rebuild its index on next use.
    func filesChanged(albumID: String) {
        indexes[albumID] = nil
        revision += 1
    }

    // MARK: Batching

    /// Downloads finished since the last save, recorded on their
    /// `DropboxFile`s in one go. Saving after every file blocked the main
    /// thread and made every list showing albums reload.
    private var unsaved: [String: DownloadQuality] = [:]
    private var saveScheduled = false
    private var refreshScheduled = false

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saveDownloaded()
        }
    }

    private func saveDownloaded() {
        saveScheduled = false
        guard let context, !unsaved.isEmpty else { return }
        let batch = unsaved
        unsaved = [:]
        let ids = Array(batch.keys)
        let records = (try? context.fetch(FetchDescriptor<DropboxFile>(
            predicate: #Predicate { ids.contains($0.fileID) }))) ?? []
        for file in records where file.localFileName == nil {
            // Removed again before this save (online only).
            let url = OfflineStore.localURL(for: file.fileID)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            file.localFileName = url.lastPathComponent
            file.localQualityRaw = batch[file.fileID]?.rawValue
            file.localSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        try? context.save()
    }

    /// Status icons refresh a few times a second at most while downloading.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            refreshScheduled = false
            revision += 1
        }
    }

    // MARK: Actions

    /// Keep an album or folder (and everything below it) offline, using the
    /// default quality from Settings. Folders download one after another.
    func download(_ album: ConnectedAlbum, folder: String? = nil) {
        album.offlineFolders = Array(Set(album.offlineFolders).union(folderPaths(of: album, under: folder)))
        album.offlineQualityRaw = album.offlineQualityRaw ?? Self.defaultQuality.rawValue
        album.downloadPaused = false
        try? context?.save()
        revision += 1
        enqueueMissing(album)
    }

    func pause(_ album: ConnectedAlbum) {
        album.downloadPaused = true
        try? context?.save()
        waiting[album.externalID] = nil
        outstanding[album.externalID]?.values.forEach { $0() }
        outstanding[album.externalID] = nil
        revision += 1
    }

    func resume(_ album: ConnectedAlbum) {
        album.downloadPaused = false
        try? context?.save()
        revision += 1
        enqueueMissing(album)
    }

    /// Make an album or folder online only again. Deletes only the app's
    /// own copies (kept if another album still holds them offline); Dropbox
    /// files are never touched and ratings are kept. Callers must make sure
    /// no changes are pending first.
    func removeDownloads(_ album: ConnectedAlbum, folder: String? = nil) {
        saveDownloaded()
        let remove = folderPaths(of: album, under: folder)
        album.offlineFolders = album.offlineFolders.filter { !remove.contains($0) }
        if folder == nil { album.offlineFolders = [] }
        // Stop queued/running downloads for those folders.
        let leaving = Set(files(of: album).filter { remove.contains($0.folderPath) }.map(\.fileID))
        waiting[album.externalID]?.removeAll { leaving.contains($0) }
        for id in leaving { outstanding[album.externalID]?[id]?(); outstanding[album.externalID]?[id] = nil }
        for file in files(of: album) where remove.contains(file.folderPath) {
            if let context { OfflineStore.removeLocalCopyIfUnused(file.fileID, leaving: album.externalID, context: context) }
            file.localFileName = nil
            file.localQualityRaw = nil
            file.localSize = 0
        }
        if album.offlineFolders.isEmpty {
            album.offlineQualityRaw = nil
            album.downloadPaused = false
        }
        try? context?.save()
        indexes[album.externalID] = nil
        revision += 1
        ImageLoader.shared.forgetAll()
    }

    /// After "check for changes": new subfolders of an offline folder are
    /// kept offline too, then just the new files are fetched.
    func downloadNewFiles(_ album: ConnectedAlbum) {
        guard !album.offlineFolders.isEmpty else { return }
        var wanted = Set(album.offlineFolders)
        // Shallowest first, so new nested folders chain from new parents.
        for path in folderPaths(of: album, under: nil).sorted(by: { $0.count < $1.count })
        where !wanted.contains(path) {
            if let parent = FolderScope.parent(of: path), wanted.contains(parent) { wanted.insert(path) }
        }
        album.offlineFolders = Array(wanted)
        try? context?.save()
        revision += 1
        if !album.downloadPaused { enqueueMissing(album) }
    }

    // MARK: Queueing

    /// Files waiting to start, per album. At most `maxConcurrent` requests
    /// run at once (Dropbox rate-limits bursts of thumbnail requests).
    private var waiting: [String: [String]] = [:]
    private var attempts: [String: Int] = [:]
    /// Failed files waiting to be queued again.
    private var retrying: [String: Int] = [:]
    private static let maxConcurrent = 6
    private static let maxAttempts = 3

    private var runningCount: Int { outstanding.values.reduce(0) { $0 + $1.count } }

    private func enqueueMissing(_ album: ConnectedAlbum) {
        let albumID = album.externalID
        let wanted = Set(album.offlineFolders)
        // Folder by folder (album order: top level, then folders A–Z).
        let order = AlbumSessionViewModel.dropboxItems(albumID: albumID, context: context!).map(\.id)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let candidates = files(of: album).filter { wanted.contains($0.folderPath) }
        let onDisk = OfflineStore.localFileNames()
        // A file can already be on disk via another album: just record it.
        for file in candidates where file.localFileName == nil {
            let name = OfflineStore.fileName(for: file.fileID)
            if onDisk.contains(name) {
                file.localFileName = name
                indexes[albumID]?.markLocal(file.fileID)
            }
        }
        let missing = candidates.filter { !onDisk.contains(OfflineStore.fileName(for: $0.fileID)) }
            .sorted { (rank[$0.fileID] ?? .max) < (rank[$1.fileID] ?? .max) }
        revision += 1
        guard DropboxClientsManager.authorizedBackgroundClient != nil else {
            log.error("No background client; pausing \(albumID, privacy: .public)")
            album.downloadPaused = true
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
    /// New requests wait only while Simulate Offline is on. Real network
    /// loss is handled by the background session, which waits and resumes.
    private func pump() {
        guard Connectivity.shared.mayTryNetwork,
              let client = DropboxClientsManager.authorizedBackgroundClient else { return }
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
                                    temp: temp, error: error.map { "\($0)" },
                                    thumbnailFailed: error.map(ThumbnailCache.isUnrenderable) ?? false)
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
            if error == nil { Connectivity.shared.markReachable() }
            // Success — or a duplicate request for a file another one saved.
            // Mark it downloaded in every album that contains it (saved in
            // batches; the indexes show it right away).
            if unsaved[fileID] == nil { unsaved[fileID] = quality }
            for id in indexes.keys { indexes[id]?.markLocal(fileID) }
            scheduleSave()
            scheduleRefresh()
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
                // Usually a rate limit: retry after a pause, not straight away.
                let delay = Double(attempts[fileID, default: 0]) * 5
                retrying[albumID, default: 0] += 1
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    retrying[albumID, default: 1] -= 1
                    if isActive(albumID) { waiting[albumID, default: []].append(fileID) }
                    pump()
                    if let album = self.album(albumID) { finishIfComplete(album) }
                }
                return
            }
        }
        finishIfComplete(album)
    }

    /// Nothing running or waiting: if anything is still missing (failures),
    /// pause so a tap retries just those files.
    private func finishIfComplete(_ album: ConnectedAlbum) {
        let albumID = album.externalID
        guard !album.downloadPaused, (retrying[albumID] ?? 0) == 0,
              outstanding[albumID]?.isEmpty ?? true,
              waiting[albumID]?.isEmpty ?? true else { return }
        let wanted = Set(album.offlineFolders)
        let onDisk = OfflineStore.localFileNames()
        let allLocal = files(of: album).filter { wanted.contains($0.folderPath) }
            .allSatisfy { onDisk.contains(OfflineStore.fileName(for: $0.fileID)) }
        if !allLocal { album.downloadPaused = true }
        saveDownloaded()
        try? context?.save()
        revision += 1
    }

    private func isActive(_ albumID: String) -> Bool {
        guard let album = album(albumID) else { return false }
        return !album.downloadPaused && !album.offlineFolders.isEmpty
    }

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
        let raw = PhotoSourceKind.dropbox.rawValue
        var descriptor = FetchDescriptor<ConnectedAlbum>(
            predicate: #Predicate { $0.sourceRaw == raw && $0.externalID == albumID })
        descriptor.fetchLimit = 1
        return (try? context?.fetch(descriptor))?.first
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
