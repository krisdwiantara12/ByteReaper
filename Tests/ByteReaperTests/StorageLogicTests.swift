import AVFoundation
import XCTest
@testable import ByteReaper

private struct TestMediaItem: DuplicateGroupable {
    let id: String
    let byteSize: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let mediaTypeRaw: Int
    let creationDate: Date
}

final class StorageLogicTests: XCTestCase {
    func testFileScannerSortsLargestFirstAndDeletesDirectly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ByteReaperTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sub = root.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let smallURL = root.appendingPathComponent("small.bin")
        let mediumURL = sub.appendingPathComponent("medium.bin")
        let largeURL = root.appendingPathComponent("large.bin")

        try Data(repeating: 0x01, count: 128).write(to: smallURL)
        try Data(repeating: 0x02, count: 4096).write(to: mediumURL)
        try Data(repeating: 0x03, count: 65536).write(to: largeURL)

        let scanned = try await FileFolderScannerService.enumerateLargestFiles(in: root)
        XCTAssertEqual(scanned.map(\.name), ["large.bin", "medium.bin", "small.bin"])
        XCTAssertEqual(scanned.map(\.byteSize), [65536, 4096, 128])
        XCTAssertEqual(scanned[1].relativePath, "Sub/medium.bin")

        try FileManager.default.removeItem(at: largeURL)
        let afterDelete = try await FileFolderScannerService.enumerateLargestFiles(in: root)
        XCTAssertEqual(afterDelete.map(\.name), ["medium.bin", "small.bin"])
    }

    func testDuplicateGrouperSeparatesDistinctHashesAndPreservesOldest() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let oldest = TestMediaItem(
            id: "1",
            byteSize: 5_000_000,
            pixelWidth: 4032,
            pixelHeight: 3024,
            mediaTypeRaw: 1,
            creationDate: baseDate
        )
        let copy = TestMediaItem(
            id: "2",
            byteSize: 5_000_000,
            pixelWidth: 4032,
            pixelHeight: 3024,
            mediaTypeRaw: 1,
            creationDate: baseDate.addingTimeInterval(600)
        )
        let sameSizeDifferentContent = TestMediaItem(
            id: "3",
            byteSize: 5_000_000,
            pixelWidth: 4032,
            pixelHeight: 3024,
            mediaTypeRaw: 1,
            creationDate: baseDate.addingTimeInterval(1200)
        )

        let buckets = DuplicateGrouper.candidateBuckets(from: [copy, oldest, sameSizeDifferentContent])
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].count, 3)

        let groups = DuplicateGrouper.buildGroups(from: [
            (copy, "hashA"),
            (oldest, "hashA"),
            (sameSizeDifferentContent, "hashB")
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.map(\.id), ["1", "2"])
        XCTAssertEqual(groups[0].reclaimableBytes, 5_000_000)
    }

    func testSimilarPhotoClustererGroupsBurstAndRespectsTimeWindow() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // Sorted newest-first as PhotoScannerService feeds it.
        let burst3 = TestMediaItem(id: "b3", byteSize: 3_000_000, pixelWidth: 4032, pixelHeight: 3024, mediaTypeRaw: 1, creationDate: baseDate.addingTimeInterval(20))
        let burst2 = TestMediaItem(id: "b2", byteSize: 2_800_000, pixelWidth: 4032, pixelHeight: 3024, mediaTypeRaw: 1, creationDate: baseDate.addingTimeInterval(10))
        let burst1 = TestMediaItem(id: "b1", byteSize: 2_900_000, pixelWidth: 4032, pixelHeight: 3024, mediaTypeRaw: 1, creationDate: baseDate)
        let oldShot = TestMediaItem(id: "old", byteSize: 4_000_000, pixelWidth: 4032, pixelHeight: 3024, mediaTypeRaw: 1, creationDate: baseDate.addingTimeInterval(-200_000))

        let items = [burst3, burst2, burst1, oldShot]
        let clusters = SimilarPhotoClusterer.cluster(items: items) { i, j in
            let ids = Set([items[i].id, items[j].id])
            if ids.isSubset(of: ["b1", "b2", "b3"]) { return 92 }
            // Even if similarity returned non-nil, oldShot exceeds 24h window so it is skipped.
            return 90
        }

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].items.map(\.id), ["b1", "b2", "b3"])
        XCTAssertEqual(clusters[0].averageSimilarityPercent, 92)
    }

    func testFileCategoryFiltersMatchExpectedExtensions() {
        XCTAssertTrue(FileCategoryFilter.video.matches(extension: "MOV"))
        XCTAssertTrue(FileCategoryFilter.image.matches(extension: "heic"))
        XCTAssertTrue(FileCategoryFilter.archive.matches(extension: "ipa"))
        XCTAssertTrue(FileCategoryFilter.document.matches(extension: "PDF"))
        XCTAssertFalse(FileCategoryFilter.video.matches(extension: "pdf"))
        XCTAssertTrue(FileCategoryFilter.all.matches(extension: "xyz"))
    }

    func testVideoCompressionPresetSelectionFallsBackCleanly() {
        let hevcPicked = VideoCompressionService.preferredExportPreset(
            compatiblePresets: [AVAssetExportPreset1920x1080, AVAssetExportPresetHEVC1920x1080],
            choice: .hevc1080p
        )
        XCTAssertEqual(hevcPicked, AVAssetExportPresetHEVC1920x1080)

        let fallback = VideoCompressionService.preferredExportPreset(
            compatiblePresets: [AVAssetExportPresetMediumQuality],
            choice: .mp41080p
        )
        XCTAssertEqual(fallback, AVAssetExportPresetMediumQuality)
    }

    func testTelemetryReadsNonNegativeStorageAndClearsTmpFile() throws {
        let snapshot = StorageTelemetryService.readDeviceSnapshot()
        XCTAssertGreaterThanOrEqual(snapshot.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(snapshot.usedBytes, 0)

        let probeURL = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).dat")
        try Data(repeating: 0xAA, count: 2048).write(to: probeURL)
        let freed = StorageTelemetryService.clearSelfCaches()
        XCTAssertGreaterThanOrEqual(freed, 2048)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeURL.path))
    }

    func testDurationAndByteFormatting() {
        XCTAssertEqual(ByteFormatter.durationString(65), "01:05")
        XCTAssertEqual(ByteFormatter.durationString(3661), "1:01:01")
        XCTAssertFalse(ByteFormatter.string(from: 1_500_000_000).isEmpty)
    }
}
