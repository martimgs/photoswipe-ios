import Foundation
import SwiftData
import SwiftyDropbox
import UIKit
import os

/// Writes queued Dropbox ratings as file tags: "stars0"…"stars5", plus
/// "rejected". Tags are metadata only — file contents are never changed.
///
/// The local database is the source of truth. Each queue entry holds the
/// newest wanted state for one photo; failures stay queued and are retried.
@MainActor
final class DropboxSyncEngine: ObservableObject {
    static let shared = DropboxSyncEngine()

    /// Tags this app owns. Any other tags on a file are left alone.
    static let managedTags: Set<String> = Set((0...5).map { "stars\($0)" } + ["rejected"])

    static func tags(rating: Int, rejected: Bool) -> Set<String> {
        var tags: Set<String> = ["stars\(Stars.clamp(rating))"]
        if rejected { tags.insert("rejected") }
        return tags
    }

    @Published private(set) var isSyncing = false
    /// Total entries waiting, across all albums.
    @Published private(set) var pendingCount = 0
    /// Entries waiting per album (`ConnectedAlbum.externalID`).
    @Published private(set) var pendingCountByAlbum: [String: Int] = [:]
    /// Dropbox file IDs with a change waiting, for per-photo indicators.
    @Published private(set) var pendingFileIDs: Set<String> = []
    /// Entries per album whose last sync attempt failed.
    @Published private(set) var failedCountByAlbum: [String: Int] = [:]
    /// File IDs whose last sync attempt failed.
    @Published private(set) var failedFileIDs: Set<String> = []
    /// Set if Dropbox refuses tags for this account; syncing stops.
    @Published private(set) var tagsUnavailableReason: String?
    @Published private(set) var lastError: String?

    private var container: ModelContainer?
    private var observers: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?
    private var retryTimer: Timer?

    private let log = Logger(subsystem: "PhotoSwipe", category: "DropboxSync")

    private init() {}

    private var client: DropboxClient? { DropboxClientsManager.authorizedClient }
    private var context: ModelContext? { container?.mainContext }

    /// Call once at launch.
    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        refreshCount()
        let center = NotificationCenter.default
        for name in [SyncQueue.didEnqueue, Connectivity.becameOnline, UIApplication.willEnterForegroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync() }
            })
        }
        // Retry failed entries periodically while anything is pending.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingCount > 0 else { return }
                self.scheduleSync()
            }
        }
        scheduleSync()
    }

    /// Changes to surface to the user for an album. While online, changes
    /// sync within seconds, so they only count when they can't sync: the
    /// device is offline, syncing is blocked, or an attempt failed.
    func unsyncedCount(albumID: String, isOnline: Bool) -> Int {
        let pending = pendingCountByAlbum[albumID] ?? 0
        guard pending > 0 else { return 0 }
        if !isOnline || tagsUnavailableReason != nil || !DropboxAuth.shared.isSignedIn { return pending }
        return failedCountByAlbum[albumID] ?? 0
    }

    /// Same rule per photo: true when this photo's change can't sync right now.
    func isUnsynced(fileID: String, isOnline: Bool) -> Bool {
        guard pendingFileIDs.contains(fileID) else { return false }
        if !isOnline || tagsUnavailableReason != nil || !DropboxAuth.shared.isSignedIn { return true }
        return failedFileIDs.contains(fileID)
    }

    func pendingCount(albumID: String) -> Int {
        guard let context else { return 0 }
        return SyncQueue(context: context).pendingCount(albumID: albumID)
    }

    /// Coalesces bursts of changes (fast swiping) into one sync pass.
    func scheduleSync(after delay: Duration = .seconds(1)) {
        refreshCount()
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    /// Process the whole queue now (oldest change first).
    func syncNow() async {
        refreshCount()
        guard !isSyncing, tagsUnavailableReason == nil, let context, let client,
              Connectivity.shared.isOnline else { return }
        isSyncing = true
        defer {
            isSyncing = false
            refreshCount()
        }

        for entry in SyncQueue(context: context).all() {
            guard Connectivity.shared.isOnline else { break }
            let snapshotChangedAt = entry.changedAt
            let wanted = Self.tags(rating: entry.rating, rejected: entry.isRejected)
            do {
                try await write(wanted, fileID: entry.fileID, client: client)
                // Only drop the entry if no newer change arrived meanwhile.
                if entry.changedAt == snapshotChangedAt {
                    context.delete(entry)
                }
                lastError = nil
            } catch let error as SyncError {
                switch error {
                case .fileGone:
                    // File no longer exists in Dropbox; nothing to tag.
                    context.delete(entry)
                case .tagsUnavailable(let reason):
                    tagsUnavailableReason = reason
                    try? context.save()
                    return
                case .failed(let message):
                    log.error("Sync failed for \(entry.fileID, privacy: .public): \(message, privacy: .public)")
                    entry.attempts += 1
                    entry.lastError = message
                    lastError = message
                }
            } catch {
                entry.attempts += 1
                entry.lastError = error.localizedDescription
                lastError = error.localizedDescription
            }
            try? context.save()
            refreshCount()
        }
    }

    private func refreshCount() {
        guard let context else { return }
        let all = (try? context.fetch(FetchDescriptor<SyncQueueEntry>())) ?? []
        pendingCount = all.count
        pendingCountByAlbum = Dictionary(grouping: all, by: \.albumID).mapValues(\.count)
        pendingFileIDs = Set(all.map(\.fileID))
        let failed = all.filter { $0.attempts > 0 }
        failedCountByAlbum = Dictionary(grouping: failed, by: \.albumID).mapValues(\.count)
        failedFileIDs = Set(failed.map(\.fileID))
    }

    // MARK: Dropbox calls

    enum SyncError: Error {
        case fileGone
        case tagsUnavailable(String)
        case failed(String)
    }

    /// Makes the file's managed tags equal `wanted`. Tag routes need a real
    /// path, so the current path is looked up from the file ID first — the
    /// rating follows the file through renames and moves.
    private func write(_ wanted: Set<String>, fileID: String, client: DropboxClient) async throws {
        let path: String
        do {
            let metadata = try await client.files.getMetadata(path: fileID).response()
            guard let lower = metadata.pathLower, metadata is Files.FileMetadata else { throw SyncError.fileGone }
            path = lower
        } catch let error as CallError<Files.GetMetadataError> {
            if case .routeError(let boxed, _, _, _) = error, case .path(.notFound) = boxed.unboxed {
                throw SyncError.fileGone
            }
            throw SyncError.failed(Self.describe(error))
        }

        let current: Set<String>
        do {
            let result = try await client.files.tagsGet(paths: [path]).response()
            current = Set(result.pathsToTags.first?.tags.compactMap { tag -> String? in
                if case .userGeneratedTag(let t) = tag { return t.tagText }
                return nil
            } ?? [])
        } catch let error as CallError<Files.BaseTagError> {
            throw Self.classify(error)
        }

        for tag in current.intersection(Self.managedTags).subtracting(wanted) {
            do {
                _ = try await client.files.tagsRemove(path: path, tagText: tag).response()
            } catch let error as CallError<Files.RemoveTagError> {
                if case .routeError(let boxed, _, _, _) = error, case .tagNotPresent = boxed.unboxed { continue }
                throw Self.classify(error)
            }
        }
        for tag in wanted.subtracting(current) {
            do {
                _ = try await client.files.tagsAdd(path: path, tagText: tag).response()
            } catch let error as CallError<Files.AddTagError> {
                throw Self.classify(error)
            }
        }
        log.info("Synced \(fileID, privacy: .public): \(current.sorted(), privacy: .public) -> \(wanted.sorted(), privacy: .public)")
        #if DEBUG
        // Read back to confirm Dropbox stored what we wrote.
        if let check = try? await client.files.tagsGet(paths: [path]).response() {
            let stored = check.pathsToTags.first?.tags.compactMap { tag -> String? in
                if case .userGeneratedTag(let t) = tag { return t.tagText }
                return nil
            } ?? []
            log.info("Read back \(fileID, privacy: .public): \(stored.sorted(), privacy: .public)")
        }
        #endif
    }

    /// Distinguishes "tags aren't available for this account/app" (stop and
    /// tell the user) from ordinary failures (retry later).
    private static func classify<E>(_ error: CallError<E>) -> SyncError {
        let text = describe(error)
        switch error {
        case .authError(let auth, _, _, _):
            if case .missingScope = auth {
                return .tagsUnavailable("The app is missing the files.metadata.write permission. Enable it in the Dropbox app console, then sign out and in again.")
            }
            return .failed(text)
        case .accessError:
            return .tagsUnavailable(text)
        case .badInputError:
            return .tagsUnavailable(text)
        case .routeError(_, _, let summary, _) where summary?.contains("feature") == true:
            return .tagsUnavailable(text)
        default:
            return .failed(text)
        }
    }

    private static func describe<E>(_ error: CallError<E>) -> String {
        String(describing: error)
    }

    // MARK: Importing existing tags

    /// Reads existing stars/rejected tags for newly found files and uses them
    /// as the starting rating — but only for photos with no local state, since
    /// local changes always win.
    func importTags(for files: [(fileID: String, pathLower: String)], context: ModelContext) async {
        guard let client, !files.isEmpty, tagsUnavailableReason == nil else { return }
        let store = PhotoStateStore(context: context)
        let fresh = files.filter { store.state(source: .dropbox, photoID: $0.fileID) == nil }
        for batch in stride(from: 0, to: fresh.count, by: 50).map({ Array(fresh[$0..<min($0 + 50, fresh.count)]) }) {
            guard let result = try? await client.files.tagsGet(paths: batch.map(\.pathLower)).response() else { return }
            let byPath = Dictionary(batch.map { ($0.pathLower, $0.fileID) }, uniquingKeysWith: { a, _ in a })
            for entry in result.pathsToTags {
                guard let fileID = byPath[entry.path.lowercased()] else { continue }
                let texts = Set(entry.tags.compactMap { tag -> String? in
                    if case .userGeneratedTag(let t) = tag { return t.tagText }
                    return nil
                })
                let stars = (0...5).last { texts.contains("stars\($0)") }
                let rejected = texts.contains("rejected")
                guard stars != nil || rejected else { continue }
                store.update(source: .dropbox, photoID: fileID) {
                    $0.rating = stars ?? 0
                    $0.isRejected = rejected
                    // changedAt stays nil: imported, not a local change.
                }
            }
        }
    }
}
