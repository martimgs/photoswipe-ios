import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import SwiftData
import SwiftyDropbox

/// Exports photos into a Dropbox folder. Dropbox photos are copied on the
/// server (nothing downloaded, originals untouched); Apple Photos are
/// uploaded. Existing files are never overwritten: name clashes get
/// Dropbox's automatic " (1)" renaming.
///
/// Photos with a soft crop get a second file, the cropped version
/// ("IMG_0001 (4x5 crop).jpg"), next to the uncropped original.
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
                return "Pickory needs permission to save files in Dropbox. Enable files.content.write in the Dropbox app console, then sign out and sign in again in Settings."
            case .failed(let message): return message
            }
        }
    }

    struct Result {
        /// Originals saved.
        var exported = 0
        /// Cropped copies saved (on top of `exported`).
        var crops = 0
        /// Originals or cropped copies that couldn't be saved.
        var failed = 0
        var filesDone: Int { exported + crops + failed }
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
            progress(result.filesDone)
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

    /// Downloads each cropped Dropbox photo's original, crops it on device and
    /// uploads the copy into `folder`. `result` carries on from the copy pass.
    func uploadDropboxCrops(_ files: [(fileID: String, name: String, crop: SoftCrop)], to folder: String,
                            adding result: Result, progress: @escaping (Int) -> Void) async throws -> Result {
        var result = result
        for file in files {
            let data: Data?
            do {
                data = try await client.files.download(path: file.fileID).response().1
            } catch let error as CallError<Files.DownloadError> {
                if case .authError = error { throw Self.map(error) }
                data = nil
            }
            try await uploadCrop(of: data, name: file.name, crop: file.crop, to: folder, result: &result)
            progress(result.filesDone)
        }
        return result
    }

    /// Uploads Apple Photos originals into `folder`, one at a time, each
    /// followed by its cropped copy when it has a soft crop.
    func uploadAssets(_ assets: [PHAsset], crops: [String: SoftCrop], to folder: String,
                      progress: @escaping (Int) -> Void) async throws -> Result {
        var result = Result()
        for asset in assets {
            let crop = crops[asset.localIdentifier]
            if let (data, name) = await Self.originalData(asset) {
                if try await upload(data, as: name, to: folder) {
                    result.exported += 1
                } else {
                    result.failed += 1
                }
                if let crop {
                    try await uploadCrop(of: data, name: name, crop: crop, to: folder, result: &result)
                }
            } else {
                result.failed += crop == nil ? 1 : 2
            }
            progress(result.filesDone)
        }
        return result
    }

    private func uploadCrop(of original: Data?, name: String, crop: SoftCrop, to folder: String,
                            result: inout Result) async throws {
        if let original, let data = await Self.croppedJPEG(original, crop: crop),
           try await upload(data, as: Self.croppedName(name, crop), to: folder) {
            result.crops += 1
        } else {
            result.failed += 1
        }
    }

    /// False if the upload failed for this file only; throws when the whole
    /// export can't continue (signed out, missing permission).
    private func upload(_ data: Data, as name: String, to folder: String) async throws -> Bool {
        do {
            _ = try await client.files.upload(path: folder + "/" + name, mode: .add,
                                              autorename: true, input: data).response()
            return true
        } catch let error as CallError<Files.UploadError> {
            if case .authError = error { throw Self.map(error) }
            return false
        }
    }

    // MARK: Cropping

    /// "IMG_0001.HEIC" → "IMG_0001 (4x5 crop).jpg"
    static func croppedName(_ name: String, _ crop: SoftCrop) -> String {
        let stem = (name as NSString).deletingPathExtension
        return "\(stem.isEmpty ? name : stem) (\(crop.aspect.fileLabel) crop).jpg"
    }

    /// The upright photo at full resolution, cut to the soft crop, as a JPEG.
    /// Keeps the original's metadata except its orientation (already applied).
    nonisolated static func croppedJPEG(_ data: Data, crop: SoftCrop) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ] as CFDictionary)
            guard let upright else { return nil }
            let size = CGSize(width: upright.width, height: upright.height)
            guard let cropped = upright.cropping(to: crop.pixelRect(in: size)) else { return nil }

            var metadata = props
            metadata[kCGImagePropertyOrientation] = 1
            metadata[kCGImagePropertyPixelWidth] = nil
            metadata[kCGImagePropertyPixelHeight] = nil
            if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                metadata[kCGImagePropertyTIFFDictionary] = tiff
            }
            metadata[kCGImageDestinationLossyCompressionQuality] = 0.92

            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(dest, cropped, metadata as CFDictionary)
            return CGImageDestinationFinalize(dest) ? out as Data : nil
        }.value
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
