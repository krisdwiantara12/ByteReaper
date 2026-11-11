import AVFoundation
import Foundation
import Photos

/// Compresses large iOS videos (MOV / 4K / ProRes) into smaller MP4/HEVC copies
/// and saves the compressed version to the Photo Library with original date/location preserved.
enum VideoCompressionService {
    /// Picks the best compatible AVAssetExportSession preset for the chosen target profile.
    static func preferredExportPreset(
        compatiblePresets: [String],
        choice: VideoCompressionPreset
    ) -> String {
        let candidates: [String]
        switch choice {
        case .hevc1080p:
            candidates = [
                AVAssetExportPresetHEVC1920x1080,
                AVAssetExportPreset1920x1080,
                AVAssetExportPresetHEVCHighestQuality,
                AVAssetExportPresetMediumQuality
            ]
        case .mp41080p:
            candidates = [
                AVAssetExportPreset1920x1080,
                AVAssetExportPreset1280x720,
                AVAssetExportPresetMediumQuality
            ]
        }

        for preset in candidates where compatiblePresets.contains(preset) {
            return preset
        }
        return AVAssetExportPresetMediumQuality
    }

    /// Exports a compressed copy of `item.asset` and saves it into PhotoKit, reporting live progress (0...1).
    static func compressAndSave(
        item: MediaAssetItem,
        preset choice: VideoCompressionPreset,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> VideoCompressionResult {
        guard item.isVideo else {
            throw compressionError("Hanya file video yang dapat dikompresi.")
        }

        await onProgress(0.05)
        guard let avAsset = await fetchAVAsset(for: item.asset) else {
            throw compressionError("Video tidak tersedia secara lokal atau gagal diunduh dari iCloud.")
        }

        let compatible = AVAssetExportSession.exportPresets(compatibleWith: avAsset)
        let chosenPreset = preferredExportPreset(compatiblePresets: compatible, choice: choice)

        guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: chosenPreset) else {
            throw compressionError("Perangkat tidak mendukung preset kompresi untuk video ini.")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bytereaper-compressed-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = exportSession.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        exportSession.shouldOptimizeForNetworkUse = true

        let holder = ExportSessionBox(session: exportSession)
        let progressTask = Task {
            while !Task.isCancelled {
                let p = Double(holder.session.progress)
                await onProgress(min(0.95, max(0.08, p)))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        defer { progressTask.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            holder.session.exportAsynchronously {
                switch holder.session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    let err = holder.session.error ?? compressionError("Ekspor video gagal.")
                    continuation.resume(throwing: err)
                case .cancelled:
                    let err = holder.session.error ?? compressionError("Kompresi video dibatalkan.")
                    continuation.resume(throwing: err)
                default:
                    continuation.resume(throwing: compressionError("Status ekspor video tidak dikenal."))
                }
            }
        }

        progressTask.cancel()
        await onProgress(0.97)

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let compressedSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let savedIdBox = LockedStringBox()
        let creationDate = item.asset.creationDate
        let location = item.asset.location

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = creationDate
            request.location = location
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.shouldMoveFile = false
            request.addResource(with: .video, fileURL: outputURL, options: resourceOptions)
            if let placeholder = request.placeholderForCreatedAsset {
                savedIdBox.set(placeholder.localIdentifier)
            }
        }

        await onProgress(1.0)
        return VideoCompressionResult(
            originalBytes: item.byteSize,
            compressedBytes: compressedSize,
            savedLocalIdentifier: savedIdBox.get()
        )
    }

    private static func fetchAVAsset(for phAsset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    private static func compressionError(_ message: String) -> NSError {
        NSError(
            domain: "ByteReaper.VideoCompression",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(session: AVAssetExportSession) {
        self.session = session
    }
}

private final class LockedStringBox: @unchecked Sendable {
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
