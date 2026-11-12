import AVFoundation
import Foundation
import Photos

/// Failure categories for video export so interrupted background runs can resume cleanly.
enum VideoExportFailure: LocalizedError {
    case interrupted(String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .interrupted(let message), .failed(let message):
            return message
        case .cancelled:
            return "Kompresi video dibatalkan."
        }
    }
}

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
        case .compact720p:
            candidates = [
                AVAssetExportPreset1280x720,
                AVAssetExportPreset960x540,
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

    /// Estimates compressed byte size from video duration and preset target bitrate, clamped to original bytes.
    static func estimatedCompressedBytes(
        originalBytes: Int64,
        duration: TimeInterval,
        preset: VideoCompressionPreset
    ) -> Int64 {
        guard originalBytes > 0, duration >= 0.5 else { return originalBytes }
        let targetMegabitsPerSecond: Double
        switch preset {
        case .hevc1080p:
            targetMegabitsPerSecond = 6.5
        case .compact720p:
            targetMegabitsPerSecond = 3.0
        case .mp41080p:
            targetMegabitsPerSecond = 9.0
        }
        let estimated = Int64((duration * targetMegabitsPerSecond * 1_000_000.0) / 8.0)
        return max(1, min(originalBytes, estimated))
    }

    /// Exports a compressed copy of `item.asset` and saves it into PhotoKit, reporting live progress (0...1).
    static func compressAndSave(
        item: MediaAssetItem,
        preset choice: VideoCompressionPreset,
        stripAudio: Bool = false,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> VideoCompressionResult {
        guard item.isVideo else {
            throw VideoExportFailure.failed("Hanya file video yang dapat dikompresi.")
        }

        await onProgress(0.05)
        guard let sourceAsset = await fetchAVAsset(for: item.asset) else {
            throw VideoExportFailure.failed("Video tidak tersedia secara lokal atau gagal diunduh dari iCloud.")
        }

        let exportAsset: AVAsset
        if stripAudio {
            exportAsset = try await makeVideoOnlyAsset(from: sourceAsset)
        } else {
            exportAsset = sourceAsset
        }

        let compatible = AVAssetExportSession.exportPresets(compatibleWith: exportAsset)
        let chosenPreset = preferredExportPreset(compatiblePresets: compatible, choice: choice)

        guard let exportSession = AVAssetExportSession(asset: exportAsset, presetName: chosenPreset) else {
            throw VideoExportFailure.failed("Perangkat tidak mendukung preset kompresi untuk video ini.")
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
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        defer { progressTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                holder.session.exportAsynchronously {
                    switch holder.session.status {
                    case .completed:
                        continuation.resume()
                    case .failed:
                        if let err = holder.session.error as NSError? {
                            if err.domain == AVFoundationErrorDomain,
                               err.code == AVError.Code.operationInterrupted.rawValue || err.code == -11847 {
                                continuation.resume(throwing: VideoExportFailure.interrupted(
                                    "Kompresi dijeda iOS karena aplikasi masuk latar belakang."
                                ))
                            } else {
                                continuation.resume(throwing: VideoExportFailure.failed(err.localizedDescription))
                            }
                        } else {
                            continuation.resume(throwing: VideoExportFailure.failed("Ekspor video gagal."))
                        }
                    case .cancelled:
                        continuation.resume(throwing: VideoExportFailure.cancelled)
                    default:
                        continuation.resume(throwing: VideoExportFailure.failed("Status ekspor video tidak dikenal."))
                    }
                }
            }
        } onCancel: {
            holder.cancelIfActive()
        }

        progressTask.cancel()
        await onProgress(0.97)

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let compressedSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard compressedSize > 0 else {
            throw VideoExportFailure.failed("File hasil kompresi kosong.")
        }

        if !stripAudio && item.byteSize > 0 && compressedSize >= item.byteSize {
            throw VideoExportFailure.failed("Video ini sudah efisien; ukuran hasil ekspor tidak lebih kecil.")
        }

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

    private static func makeVideoOnlyAsset(from source: AVAsset) async throws -> AVAsset {
        let videoTracks = try await source.loadTracks(withMediaType: .video)
        guard let firstTrack = videoTracks.first else {
            throw VideoExportFailure.failed("Track video tidak ditemukan untuk mode tanpa audio.")
        }

        let timeRange = try await firstTrack.load(.timeRange)
        let transform = try await firstTrack.load(.preferredTransform)

        let composition = AVMutableComposition()
        guard let mutableTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoExportFailure.failed("Gagal menyiapkan komposisi video tanpa audio.")
        }

        try mutableTrack.insertTimeRange(timeRange, of: firstTrack, at: .zero)
        mutableTrack.preferredTransform = transform
        return composition
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
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    private let lock = NSLock()

    init(session: AVAssetExportSession) {
        self.session = session
    }

    func cancelIfActive() {
        lock.lock()
        let status = session.status
        lock.unlock()
        if status == .exporting || status == .waiting {
            session.cancelExport()
        }
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
