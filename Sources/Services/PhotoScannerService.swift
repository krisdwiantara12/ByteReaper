import AVFoundation
import CryptoKit
import Foundation
import Photos
import UIKit
import Vision

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

/// Pure clustering helper that groups visually similar items into connected components.
enum SimilarPhotoClusterer {
    struct ClusterResult<Item: DuplicateGroupable> {
        let id: String
        let averageSimilarityPercent: Int
        let items: [Item]
    }

    /// Builds clusters from a list sorted newest-first using a caller-provided pairwise similarity percentage (0..100).
    /// Only compares items within `maxWindow` indices and `maxTimeGapSeconds` to stay O(N) on large libraries.
    static func cluster<Item: DuplicateGroupable>(
        items: [Item],
        maxWindow: Int = 15,
        maxTimeGapSeconds: TimeInterval = 86_400,
        similarityPercent: (Int, Int) -> Int?
    ) -> [ClusterResult<Item>] {
        let n = items.count
        guard n >= 2 else { return [] }

        var parent = Array(0..<n)
        var scoresByRoot: [Int: [Int]] = [:]

        func find(_ x: Int) -> Int {
            var cur = x
            while parent[cur] != cur {
                parent[cur] = parent[parent[cur]]
                cur = parent[cur]
            }
            return cur
        }

        func union(_ a: Int, _ b: Int, score: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb {
                parent[rb] = ra
                var merged = scoresByRoot[ra] ?? []
                merged.append(contentsOf: scoresByRoot[rb] ?? [])
                merged.append(score)
                scoresByRoot[ra] = merged
                scoresByRoot.removeValue(forKey: rb)
            } else {
                scoresByRoot[ra, default: []].append(score)
            }
        }

        for i in 0..<n {
            let upper = min(n - 1, i + maxWindow)
            guard i + 1 <= upper else { continue }
            for j in (i + 1)...upper {
                if abs(items[i].creationDate.timeIntervalSince(items[j].creationDate)) > maxTimeGapSeconds {
                    continue
                }
                if let score = similarityPercent(i, j) {
                    union(i, j, score: score)
                }
            }
        }

        var buckets: [Int: [Item]] = [:]
        for i in 0..<n {
            buckets[find(i), default: []].append(items[i])
        }

        return buckets.compactMap { root, groupItems in
            guard groupItems.count >= 2 else { return nil }
            let sortedOldestFirst = groupItems.sorted { $0.creationDate < $1.creationDate }
            let scores = scoresByRoot[root] ?? []
            let avg = scores.isEmpty ? 85 : scores.reduce(0, +) / scores.count
            return ClusterResult(
                id: sortedOldestFirst.first?.id ?? UUID().uuidString,
                averageSimilarityPercent: avg,
                items: sortedOldestFirst
            )
        }
        .sorted {
            let reclaimA = $0.items.dropFirst().reduce(Int64(0)) { $0 + $1.byteSize }
            let reclaimB = $1.items.dropFirst().reduce(Int64(0)) { $0 + $1.byteSize }
            return reclaimA > reclaimB
        }
    }
}

/// Scans the iOS Photo Library via PhotoKit in two phases (fast videos first, then photos),
/// detects local vs iCloud availability, verifies exact SHA-256 duplicates and Vision similar shots,
/// and performs direct PhotoKit batch deletion.
@MainActor
final class PhotoScannerService: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var phase: ScanPhase<[MediaAssetItem]> = .idle
    @Published private(set) var backgroundPhotoScanStatus: String?
    @Published private(set) var duplicatePhase: ScanPhase<[DuplicateGroup]> = .idle
    @Published private(set) var similarPhase: ScanPhase<[SimilarPhotoGroup]> = .idle
    @Published private(set) var sessionReclaimedBytes: Int64 = 0

    private let imageManager = PHCachingImageManager()
    private var activeScanTask: Task<Void, Never>?
    private var activeDuplicateTask: Task<Void, Never>?
    private var activeSimilarTask: Task<Void, Never>?

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
        activeSimilarTask?.cancel()
        activeSimilarTask = nil
        backgroundPhotoScanStatus = nil

        if case .scanning = phase {
            phase = .idle
        }
        if case .scanning = duplicatePhase {
            duplicatePhase = .idle
        }
        if case .scanning = similarPhase {
            similarPhase = .idle
        }
    }

    func startScan() {
        activeScanTask?.cancel()
        activeDuplicateTask?.cancel()
        activeSimilarTask?.cancel()

        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = currentStatus
        guard currentStatus == .authorized || currentStatus == .limited else {
            phase = .permissionDenied
            return
        }

        phase = .scanning(processed: 0, total: 0, statusText: "Memindai video terbesar terlebih dahulu...")
        backgroundPhotoScanStatus = nil
        duplicatePhase = .idle
        similarPhase = .idle

        activeScanTask = Task { [weak self] in
            guard let self else { return }

            // Phase 1: Videos first so multi-GB MOV/4K files appear almost instantly.
            let videos = await Self.fetchAssets(mediaType: .video) { processed, total in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.phase = .scanning(
                        processed: processed,
                        total: total,
                        statusText: "Memindai video (\(processed)/\(total))..."
                    )
                }
            }

            guard !Task.isCancelled else { return }

            if !videos.isEmpty {
                self.phase = .loaded(videos.sorted { $0.byteSize > $1.byteSize })
                self.backgroundPhotoScanStatus = "Memindai foto di latar belakang..."
            } else {
                self.phase = .scanning(processed: 0, total: 0, statusText: "Memindai galeri foto...")
            }

            // Phase 2: Photos in background, then merge and re-sort descending.
            let photos = await Self.fetchAssets(mediaType: .image) { processed, total in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if !videos.isEmpty {
                        self.backgroundPhotoScanStatus = "Memindai foto (\(processed)/\(total))..."
                    } else {
                        self.phase = .scanning(
                            processed: processed,
                            total: total,
                            statusText: "Menghitung ukuran foto (\(processed)/\(total))..."
                        )
                    }
                }
            }

            guard !Task.isCancelled else { return }
            self.backgroundPhotoScanStatus = nil

            let merged: [MediaAssetItem]
            if case .loaded(let currentItems) = self.phase, !videos.isEmpty {
                // Preserve any deletions the user already executed during Phase 2.
                let survivingVideoIds = Set(currentItems.filter(\.isVideo).map(\.id))
                let survivingVideos = videos.filter { survivingVideoIds.contains($0.id) }
                merged = (survivingVideos + photos).sorted { $0.byteSize > $1.byteSize }
            } else {
                merged = (videos + photos).sorted { $0.byteSize > $1.byteSize }
            }

            self.phase = .loaded(merged)
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

    /// Detects visually similar local photos offline using Apple Vision feature prints.
    func findSimilarPhotosIfNeeded() {
        guard case .loaded(let items) = phase else { return }
        if case .loaded = similarPhase { return }
        if case .scanning = similarPhase { return }

        let localPhotos = items
            .filter { !$0.isVideo && $0.isLocallyAvailable }
            .sorted { $0.creationDate > $1.creationDate }
            .prefix(800)

        let candidates = Array(localPhotos)
        guard candidates.count >= 2 else {
            similarPhase = .loaded([])
            return
        }

        similarPhase = .scanning(
            processed: 0,
            total: candidates.count,
            statusText: "Menganalisis kemiripan visual (\(candidates.count) foto lokal)..."
        )

        activeSimilarTask = Task { [weak self] in
            guard let self else { return }
            var features: [VNFeaturePrintObservation?] = Array(repeating: nil, count: candidates.count)

            for (idx, item) in candidates.enumerated() {
                if Task.isCancelled { return }
                if let thumb = await self.loadVisionThumbnail(for: item.asset),
                   let cgImage = thumb.cgImage {
                    features[idx] = await Task.detached(priority: .utility) {
                        Self.extractFeaturePrint(from: cgImage)
                    }.value
                }
                if idx % 15 == 0 || idx + 1 == candidates.count {
                    self.similarPhase = .scanning(
                        processed: idx + 1,
                        total: candidates.count,
                        statusText: "Menganalisis kemiripan foto (\(idx + 1)/\(candidates.count))..."
                    )
                }
            }

            guard !Task.isCancelled else { return }

            let rawClusters = SimilarPhotoClusterer.cluster(items: candidates) { i, j in
                guard let fpA = features[i], let fpB = features[j] else { return nil }
                return Self.similarityPercentBetween(fpA, fpB)
            }

            let mapped = rawClusters.map { cluster in
                SimilarPhotoGroup(
                    id: cluster.id,
                    averageSimilarityPercent: cluster.averageSimilarityPercent,
                    items: cluster.items
                )
            }
            self.similarPhase = .loaded(mapped)
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

        if case .loaded(let existingSimilar) = similarPhase {
            let updatedSimilar: [SimilarPhotoGroup] = existingSimilar.compactMap { group in
                let kept = group.items.filter { !ids.contains($0.id) }
                guard kept.count >= 2 else { return nil }
                return SimilarPhotoGroup(
                    id: group.id,
                    averageSimilarityPercent: group.averageSimilarityPercent,
                    items: kept
                )
            }
            similarPhase = .loaded(updatedSimilar)
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
            resizeMode: .fast,
            allowNetwork: true
        )
    }

    /// Loads full-resolution preview image for inspection before deletion.
    func loadFullImage(for asset: PHAsset) async -> UIImage? {
        await requestImageOnce(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            deliveryMode: .highQualityFormat,
            resizeMode: .none,
            allowNetwork: true
        )
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

    private func loadVisionThumbnail(for asset: PHAsset) async -> UIImage? {
        await requestImageOnce(
            for: asset,
            targetSize: CGSize(width: 256, height: 256),
            contentMode: .aspectFit,
            deliveryMode: .highQualityFormat,
            resizeMode: .fast,
            allowNetwork: false
        )
    }

    private func requestImageOnce(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        resizeMode: PHImageRequestOptionsResizeMode,
        allowNetwork: Bool
    ) async -> UIImage? {
        let gate = ResumeOnceGate()
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.resizeMode = resizeMode
            options.isNetworkAccessAllowed = allowNetwork

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

    // MARK: - Private Background Enumeration & Vision Helpers

    private static func fetchAssets(
        mediaType: PHAssetMediaType,
        onProgress: @escaping @Sendable (Int, Int) async -> Void
    ) async -> [MediaAssetItem] {
        await Task.detached(priority: .userInitiated) {
            let fetchOptions = PHFetchOptions()
            fetchOptions.includeHiddenAssets = false
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let result = PHAsset.fetchAssets(with: mediaType, options: fetchOptions)
            let total = result.count
            var collected: [MediaAssetItem] = []
            collected.reserveCapacity(total)

            let fileSizeSelector = NSSelectorFromString("fileSize")
            let locallyAvailableSelector = NSSelectorFromString("locallyAvailable")

            for index in 0..<total {
                if Task.isCancelled { return [] }
                let asset = result.object(at: index)
                let resources = PHAssetResource.assetResources(for: asset)

                var totalBytes: Int64 = 0
                var primaryName = "Media"
                var isLocal = true

                for (rIdx, resource) in resources.enumerated() {
                    if rIdx == 0 {
                        if !resource.originalFilename.isEmpty {
                            primaryName = resource.originalFilename
                        }
                        if resource.responds(to: locallyAvailableSelector),
                           let localNum = resource.value(forKey: "locallyAvailable") as? NSNumber {
                            isLocal = localNum.boolValue
                        }
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
                    isBurst: asset.representsBurst,
                    isLocallyAvailable: isLocal
                )
                collected.append(item)

                if index % 80 == 0 || index + 1 == total {
                    await onProgress(index + 1, total)
                    await Task.yield()
                }
            }

            return collected
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

    nonisolated private static func extractFeaturePrint(from cgImage: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        if #unavailable(iOS 17.0) {
            request.revision = VNGenerateImageFeaturePrintRequestRevision1
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }

    nonisolated private static func similarityPercentBetween(
        _ a: VNFeaturePrintObservation,
        _ b: VNFeaturePrintObservation
    ) -> Int? {
        var distance: Float = 0
        do {
            try a.computeDistance(&distance, to: b)
        } catch {
            return nil
        }

        if #available(iOS 17.0, *) {
            // Revision 2 uses unit-normalized vectors (distance range 0...2).
            guard distance <= 0.52 else { return nil }
            let cosine = max(0.0, min(1.0, 1.0 - (Double(distance) * Double(distance)) / 2.0))
            return max(50, min(99, Int((cosine * 100.0).rounded())))
        } else {
            guard distance <= 8.5 else { return nil }
            let normalized = max(0.0, min(1.0, 1.0 - Double(distance) / 20.0))
            return max(50, min(99, Int((normalized * 100.0).rounded())))
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
