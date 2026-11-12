import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Converts huge static photos (48MP ProRAW, DNG, large PNG/JPEG) into smaller HEIC files
/// while preserving original EXIF orientation, creation date, and location.
enum PhotoConversionService {
    static func convertToHEICAndSave(
        item: MediaAssetItem,
        quality: Double = 0.85
    ) async throws -> PhotoConversionResult {
        guard !item.isVideo && !item.isLivePhoto else {
            throw conversionError("Hanya foto statis yang dapat dikonversi ke HEIC.")
        }

        guard let sourceData = await fetchFullImageData(for: item.asset) else {
            throw conversionError("Data foto asli tidak tersedia secara lokal atau gagal diunduh.")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bytereaper-heic-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let encodeSuccess = autoreleasepool { () -> Bool in
            guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
                  let destination = CGImageDestinationCreateWithURL(
                      outputURL as CFURL,
                      UTType.heic.identifier as CFString,
                      1,
                      nil
                  ) else {
                return false
            }

            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: min(0.95, max(0.5, quality))
            ]
            CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
            return CGImageDestinationFinalize(destination)
        }

        guard encodeSuccess else {
            throw conversionError("Gagal mengodekan foto ke format HEIC.")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let convertedSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard convertedSize > 0 else {
            throw conversionError("File HEIC hasil konversi kosong.")
        }

        if item.byteSize > 0 && convertedSize >= item.byteSize {
            throw conversionError("Foto ini sudah hemat; ukuran HEIC tidak lebih kecil dari file asli.")
        }

        let savedIdBox = LockedPhotoIdBox()
        let creationDate = item.asset.creationDate
        let location = item.asset.location

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = creationDate
            request.location = location
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: outputURL, options: options)
            if let placeholder = request.placeholderForCreatedAsset {
                savedIdBox.set(placeholder.localIdentifier)
            }
        }

        return PhotoConversionResult(
            originalBytes: item.byteSize,
            convertedBytes: convertedSize,
            savedLocalIdentifier: savedIdBox.get()
        )
    }

    private static func fetchFullImageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func conversionError(_ message: String) -> NSError {
        NSError(
            domain: "ByteReaper.PhotoConversion",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func deleteOriginalAssets(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}

private final class LockedPhotoIdBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func set(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

