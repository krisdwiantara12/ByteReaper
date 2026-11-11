import AVFoundation
import CryptoKit
import Foundation
import Photos
import UIKit

/// Pure grouping helpers for identifying candidate and SHA-256 verified duplicate media.
enum DuplicateGrouper {
    private struct CandidateKey: Hashable {
        let byteSize: Int64
        let pixelWidth: Int
        let pixelHeight: Int
        let mediaTypeRaw: Int
    }

    /// Buckets items sharing identical byte size, dimensions, and media type.
    static func candidateBuckets<Item: DuplicateGroupable>(from items: [Item]) -> [[Item]] {
        var buckets: [CandidateKey: [Item]] = [:]
        for item in items where item.byteSize > 0 {
            let key = CandidateKey(
                byteSize: item.byteSize,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                mediaTypeRaw: item.mediaTypeRaw
            )
            buckets[key, default: []].append(item)
        }
        return buckets.values
            .filter { $0.count >= 2 }
            .sorted { ($0.first?.byteSize ?? 0) > ($1.first?.byteSize ?? 0) }
    }

    /// Groups items that share an identical SHA-256 digest, sorted by largest reclaimable savings first.
    static func buildGroups<Item: DuplicateGroupable>(
        from hashedItems: [(Item, String)]
    ) -> [DuplicateGroupGeneric<Item>] {
        var byHash: [String: [Item]] = [:]
        for (item, sha256) in hashedItems {
            byHash[sha256, default: []].append(item)
        }

        return byHash.compactMap { hash, groupItems in
            guard groupItems.count >= 2 else { return nil }
            let sortedOldestFirst = groupItems.sorted { $0.creationDate < $1.creationDate }
            let sizeEach = sortedOldestFirst.first?.byteSize ?? 0
            return DuplicateGroupGeneric(
                id: hash,
                sha256: hash,
                byteSizeEach: sizeEach,
                items: sortedOldestFirst
            )
        }
        .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }
}

/// Scans the iOS Photo Library via PhotoKit, measures exact asset resource sizes,
/// hashes candidate duplicates with SHA-256, and executes real batch deletion.
@MainActor
final class PhotoScannerService: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var phase: ScanPhase<[MediaAssetItem]> = .idle
    @Published private(set) var duplicatePhase: ScanPhase<[DuplicateGroup]> = .idle
    @Published private(set) var sessionReclaimedBytes: Int64 = 0

    private let imageManager = PHCachingImageManager()
    private var activeScanTask: Task<Void, Never>?
    private var activeDuplicateTask: Task<Void, Never>?

    func refreshAuthorization() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorizationAndScan() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        switch status {
        case .authorized, .limited:
            startScan()
        case .denied, .restricted:
            phase = .permissionDenied
        case .notDetermined:
            phase = .idle
        @unknown default:
            phase = .permissionDenied
        }
    }

    func cancelScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        activeDuplicateTask?.cancel()
        activeDuplicateTask = nil
        if case .scanning = phase {
            phase = .idle
        }
        if case .scanning = duplicatePhase {
            duplicatePhase = .idle
        }
    }

    func startScan() {
        activeScanTask?.cancel()
        activeDuplicateTask?.cancel()

        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = currentStatus
        guard currentStatus == .authorized || currentStatus == .limited else {
            phase = .permissionDenied
            return
        }

        phase = .scanning(processed: 0, total: 0, statusText: "Mengambil daftar foto dan video...")
        duplicatePhase = .idle

        activeScanTask = Task { [weak self] in
            guard let self else { return }
            let scanned = await Self.fetchAllAssetsSortedBySize { processed, total in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.phase = .scanning(
                        processed: processed,
                        total: total,
                        statusText: "Menghitung ukuran file (\(processed)/\(total))..."
                    )
                }
            }

            guard !Task.isCancelled else { return }
            self.phase = .loaded(scanned)
        }
    }

    /// Computes verified SHA-256 duplicate groups on demand from the already-scanned items.
    func findDuplicatesIfNeeded() {
        guard case .loaded(let items) = phase else { return }
        if case .loaded = duplicatePhase { return }
        if case .scanning = duplicatePhase { return }

        let buckets = DuplicateGrouper.candidateBuckets(from: items)
        let candidates = buckets.flatMap { $0 }
        guard !candidates.isEmpty else {
            duplicatePhase = .loaded([])
            return
        }

        duplicatePhase = .scanning(processed: 0, total: candidates.count, statusText: "Verifikasi hash SHA-256 kandidat duplikat...")

        activeDuplicateTask = Task { [weak self] in
            guard let self else { return }
            var hashed: [(MediaAssetItem, String)] = []
            hashed.reserveCapacity(candidates.count)

            for (index, item) in candidates.enumerated() {
                if Task.isCancelled { return }
                if let digest = await Self.sha256ForPrimaryResource(of: item.asset) {
                    hashed.append((item, digest))
                }
                if index % 5 == 0 || index + 1 == candidates.count {
                    self.duplicatePhase = .scanning(
                        processed: index + 1,
                        total: candidates.count,
                        statusText: "Verifikasi file identik (\(index + 1)/\(candidates.count))..."
                    )
                }
            }

            guard !Task.isCancelled else { return }
            let groups = DuplicateGrouper.buildGroups(from: hashed)
            self.duplicatePhase = .loaded(groups)
        }
    }

    /// Executes native PhotoKit deletion (moves selected items to Recently Deleted on iOS).
    func deleteAssets(ids: Set<String>) async throws -> Int64 {
        guard case .loaded(let items) = phase else { return 0 }
        let targets = items.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return 0 }

        let phAssets = targets.map(\.asset)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(phAssets as NSArray)
        }

        let freedBytes = targets.reduce(Int64(0)) { $0 + $1.byteSize }
        sessionReclaimedBytes += freedBytes

        let remaining = items.filter { !ids.contains($0.id) }
        phase = .loaded(remaining)

        if case .loaded(let existingGroups) = duplicatePhase {
            let updatedGroups: [DuplicateGroup] = existingGroups.compactMap { group in
                let kept = group.items.filter { !ids.contains($0.id) }
                guard kept.count >= 2 else { return nil }
                return DuplicateGroup(
                    id: group.id,
                    sha256: group.sha256,
                    byteSizeEach: group.byteSizeEach,
                    items: kept
                )
            }
            duplicatePhase = .loaded(updatedGroups)
        }

        return freedBytes
    }

    /// Loads a square thumbnail for list rows without blocking scrolling.
    func loadThumbnail(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await requestImageOnce(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            deliveryMode: .opportunistic,
            resizeMode: .fast
        )
    }

    /// Loads full-resolution preview image for inspection before deletion.
    func loadFullImage(for asset: PHAsset) async -> UIImage? {
        await requestImageOnce(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            deliveryMode: .highQualityFormat,
            resizeMode: .none
        )
    }

    private func requestImageOnce(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        resizeMode: PHImageRequestOptionsResizeMode
    ) async -> UIImage? {
        let gate = ResumeOnceGate()
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.resizeMode = resizeMode
            options.isNetworkAccessAllowed = true

            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if (!isDegraded || hasError || isCancelled) && gate.tryClaim() {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Loads an AVPlayerItem so large videos can be watched inside the preview sheet before deleting.
    func loadPlayerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true

            imageManager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - Private Background Enumeration

    private static func fetchAllAssetsSortedBySize(
        onProgress: @escaping @Sendable (Int, Int) async -> Void
    ) async -> [MediaAssetItem] {
        await Task.detached(priority: .userInitiated) {
            let fetchOptions = PHFetchOptions()
            fetchOptions.includeHiddenAssets = false
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let result = PHAsset.fetchAssets(with: fetchOptions)
            let total = result.count
            var collected: [MediaAssetItem] = []
            collected.reserveCapacity(total)

            let fileSizeSelector = NSSelectorFromString("fileSize")

            for index in 0..<total {
                if Task.isCancelled { return [] }
                let asset = result.object(at: index)
                let resources = PHAssetResource.assetResources(for: asset)

                var totalBytes: Int64 = 0
                var primaryName = "Media"
                for (rIdx, resource) in resources.enumerated() {
                    if rIdx == 0 && !resource.originalFilename.isEmpty {
                        primaryName = resource.originalFilename
                    }
                    if resource.responds(to: fileSizeSelector),
                       let number = resource.value(forKey: "fileSize") as? NSNumber {
                        totalBytes += number.int64Value
                    }
                }

                let item = MediaAssetItem(
                    id: asset.localIdentifier,
                    asset: asset,
                    mediaType: asset.mediaType,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    duration: asset.duration,
                    creationDate: asset.creationDate ?? Date.distantPast,
                    byteSize: totalBytes,
                    filename: primaryName,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                    isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                    isBurst: asset.representsBurst
                )
                collected.append(item)

                if index % 80 == 0 || index + 1 == total {
                    await onProgress(index + 1, total)
                    await Task.yield()
                }
            }

            return collected.sorted { $0.byteSize > $1.byteSize }
        }.value
    }

    private static func sha256ForPrimaryResource(of asset: PHAsset) async -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let primary = resources.first else { return nil }

        let streamHasher = LockedSHA256()
        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false

            PHAssetResourceManager.default().requestData(
                for: primary,
                options: options,
                dataReceivedHandler: { chunk in
                    streamHasher.update(chunk)
                },
                completionHandler: { error in
                    if error != nil {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: streamHasher.finalizeHex())
                }
            )
        }
    }
}

private final class LockedSHA256: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256()

    func update(_ data: Data) {
        lock.lock()
        hasher.update(data: data)
        lock.unlock()
    }

    func finalizeHex() -> String {
        lock.lock()
        let digest = hasher.finalize()
        lock.unlock()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class ResumeOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
