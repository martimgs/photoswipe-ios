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
/// ("IMG_0001 (4x5 crop).jpg"), next to the uncropped original. An 8:5
/// carousel crop also gets its two 4:5 posts ("… (8x5 crop, 1 of 2).jpg").
/// A saved brightness is applied to those copies; a photo with brightness
/// but no crop gets one copy of the whole photo ("IMG_0001 (edited).jpg").
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
        /// Edited copies saved (on top of `exported`).
        var edited = 0
        /// Originals or edited copies that couldn't be saved.
        var failed = 0
        var filesDone: Int { exported + edited + failed }
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

    /// Downloads each edited Dropbox photo's original, edits it on device and
    /// uploads the copy into `folder`. `result` carries on from the copy pass.
    func uploadDropboxEdits(_ files: [(fileID: String, name: String, edit: SoftEdit)], to folder: String,
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
            try await uploadEdit(of: data, name: file.name, edit: file.edit, to: folder, result: &result)
            progress(result.filesDone)
        }
        return result
    }

    /// Uploads Apple Photos originals into `folder`, one at a time, each
    /// followed by its edited copy when it has a soft edit.
    func uploadAssets(_ assets: [PHAsset], edits: [String: SoftEdit], to folder: String,
                      progress: @escaping (Int) -> Void) async throws -> Result {
        var result = Result()
        for asset in assets {
            let edit = edits[asset.localIdentifier]
            if let (data, name) = await Self.originalData(asset) {
                if try await upload(data, as: name, to: folder) {
                    result.exported += 1
                } else {
                    result.failed += 1
                }
                if let edit {
                    try await uploadEdit(of: data, name: name, edit: edit, to: folder, result: &result)
                }
            } else {
                result.failed += 1 + (edit.map(Self.editFileCount) ?? 0)
            }
            progress(result.filesDone)
        }
        return result
    }

    /// Edited files per soft edit: one, plus two halves for a carousel crop.
    nonisolated static func editFileCount(_ edit: SoftEdit) -> Int {
        edit.crop?.aspect.splitsInTwo == true ? 3 : 1
    }

    private func uploadEdit(of original: Data?, name: String, edit: SoftEdit, to folder: String,
                            result: inout Result) async throws {
        guard let original else { result.failed += Self.editFileCount(edit); return }
        let parts = await Self.editedJPEGs(original, edit: edit)
        for (index, data) in parts.enumerated() {
            // Index 0 is the whole crop; 1 and 2 are a carousel's posts.
            let part = index > 0 ? (index, parts.count - 1) : nil
            if let data, try await upload(data, as: Self.editedName(name, edit.crop, part: part), to: folder) {
                result.edited += 1
            } else {
                result.failed += 1
            }
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

    // MARK: Editing

    /// "IMG_0001.HEIC" → "IMG_0001 (4x5 crop).jpg", or with
    /// `part: (1, 2)` → "IMG_0001 (8x5 crop, 1 of 2).jpg". Without a crop
    /// (brightness only) → "IMG_0001 (edited).jpg".
    static func editedName(_ name: String, _ crop: SoftCrop?, part: (Int, Int)? = nil) -> String {
        let stem = (name as NSString).deletingPathExtension
        let base = stem.isEmpty ? name : stem
        guard let crop else { return "\(base) (edited).jpg" }
        let suffix = part.map { ", \($0.0) of \($0.1)" } ?? ""
        return "\(base) (\(crop.aspect.fileLabel) crop\(suffix)).jpg"
    }

    /// The upright photo at full resolution with the soft edit applied, as
    /// JPEGs: the crop (or the whole photo), then for a carousel its left and
    /// right halves. Keeps the original's metadata except its orientation
    /// (already applied). Nil for a piece that couldn't be made.
    nonisolated static func editedJPEGs(_ data: Data, edit: SoftEdit) async -> [Data?] {
        let pieces = editFileCount(edit)
        return await Task.detached(priority: .userInitiated) { () -> [Data?] in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int
            else { return Array(repeating: nil, count: pieces) }
            let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ] as CFDictionary)
            let upright = edit.brightness == 0 ? decoded : decoded.flatMap { BrightnessCurve.render(edit.brightness, $0) }
            guard let upright else { return Array(repeating: nil, count: pieces) }
            let size = CGSize(width: upright.width, height: upright.height)
            let rect = edit.crop?.pixelRect(in: size) ?? CGRect(origin: .zero, size: size)
            var rects = [rect]
            if edit.crop?.aspect.splitsInTwo == true {
                let half = rect.width / 2
                rects.append(CGRect(x: rect.minX, y: rect.minY, width: half, height: rect.height))
                rects.append(CGRect(x: rect.minX + half, y: rect.minY, width: half, height: rect.height))
            }

            var metadata = props
            metadata[kCGImagePropertyOrientation] = 1
            metadata[kCGImagePropertyPixelWidth] = nil
            metadata[kCGImagePropertyPixelHeight] = nil
            if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                metadata[kCGImagePropertyTIFFDictionary] = tiff
            }
            metadata[kCGImageDestinationLossyCompressionQuality] = 0.92

            return rects.map { piece -> Data? in
                guard let cropped = upright.cropping(to: piece) else { return nil }
                let out = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
                else { return nil }
                CGImageDestinationAddImage(dest, cropped, metadata as CFDictionary)
                return CGImageDestinationFinalize(dest) ? out as Data : nil
            }
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
