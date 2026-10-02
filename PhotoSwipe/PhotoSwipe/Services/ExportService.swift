import Foundation
import Photos
import SwiftData
import SwiftyDropbox

/// Exports photos into a Dropbox folder. Dropbox photos are copied on the
/// server (nothing downloaded, originals untouched); Apple Photos are
/// uploaded. Existing files are never overwritten: name clashes get
/// Dropbox's automatic " (1)" renaming.
@MainActor
final class ExportService {
    static let shared = ExportService()

    enum ExportError: LocalizedError {
        case signedOut
        case missingPermission
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .signedOut: return "Sign in to Dropbox in Settings first."
            case .missingPermission:
                return "PhotoSwipe needs permission to save files in Dropbox. Enable files.content.write in the Dropbox app console, then sign out and sign in again in Settings."
            case .failed(let message): return message
            }
        }
    }

    struct Result {
        var exported = 0
        var failed = 0
    }

    private var client: DropboxClient {
        get throws {
            guard let client = DropboxClientsManager.authorizedClient else { throw ExportError.signedOut }
            return client
        }
    }

    // MARK: Folders

    /// Creates `name` inside `parent` and returns the new folder's path.
    func createFolder(named name: String, in parent: String) async throws -> String {
        let path = (parent.isEmpty ? "" : parent) + "/" + name
        do {
            let result = try await client.files.createFolderV2(path: path, autorename: true).response()
            return result.metadata.pathDisplay ?? result.metadata.pathLower ?? path
        } catch let error as CallError<Files.CreateFolderError> {
            throw Self.map(error)
        }
    }

    // MARK: Export

    /// Copies Dropbox files (by ID) into `folder`, up to 1,000 per batch.
    func copyDropboxFiles(_ files: [(fileID: String, name: String)], to folder: String,
                          progress: @escaping (Int) -> Void) async throws -> Result {
        var result = Result()
        for start in stride(from: 0, to: files.count, by: 1000) {
            let batch = files[start..<min(start + 1000, files.count)]
            let entries = batch.map { Files.RelocationPath(fromPath: $0.fileID, toPath: folder + "/" + $0.name) }
            let launch: Files.RelocationBatchV2Launch
            do {
                launch = try await client.files.copyBatchV2(entries: entries, autorename: true).response()
            } catch {
                throw Self.map(any: error)
            }
            let outcome: Files.RelocationBatchV2Result
            switch launch {
            case .complete(let done):
                outcome = done
            case .asyncJobId(let jobID):
                outcome = try await poll(jobID)
            }
            for entry in outcome.entries {
                if case .success = entry { result.exported += 1 } else { result.failed += 1 }
            }
            progress(result.exported + result.failed)
        }
        return result
    }

    private func poll(_ jobID: String) async throws -> Files.RelocationBatchV2Result {
        while true {
            try await Task.sleep(for: .seconds(1))
            let status: Files.RelocationBatchV2JobStatus
            do {
                status = try await client.files.copyBatchCheckV2(asyncJobId: jobID).response()
            } catch let error as CallError<Async.PollError> {
                throw Self.map(error)
            }
            switch status {
            case .inProgress: continue
            case .complete(let result): return result
            }
        }
    }

    /// Uploads Apple Photos originals into `folder`, one at a time.
    func uploadAssets(_ assets: [PHAsset], to folder: String,
                      progress: @escaping (Int) -> Void) async throws -> Result {
        var result = Result()
        for (index, asset) in assets.enumerated() {
            if let (data, name) = await Self.originalData(asset) {
                do {
                    _ = try await client.files.upload(path: folder + "/" + name, mode: .add,
                                                      autorename: true, input: data).response()
                    result.exported += 1
                } catch let error as CallError<Files.UploadError> {
                    if case .authError = error { throw Self.map(error) }
                    result.failed += 1
                }
            } else {
                result.failed += 1
            }
            progress(index + 1)
        }
        return result
    }

    /// The photo's current version (with edits) and its original file name.
    private static func originalData(_ asset: PHAsset) async -> (Data, String)? {
        let name = PHAssetResource.assetResources(for: asset).first?.filename ?? "\(asset.localIdentifier).jpg"
        return await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                cont.resume(returning: data.map { ($0, name) })
            }
        }
    }

    // MARK: Errors

    /// For routes whose error type is Void: detect a missing scope from the description.
    private static func map(any error: Error) -> ExportError {
        let text = String(describing: error)
        if text.contains("missingScope") || text.contains("missing_scope") { return .missingPermission }
        return .failed(text)
    }

    private static func map<E>(_ error: CallError<E>) -> ExportError {
        if case .authError(let auth, _, _, _) = error, case .missingScope = auth {
            return .missingPermission
        }
        return .failed(String(describing: error))
    }
}
