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

    func testFileDuplicateDetectorGroupsIdenticalContentAndSkipsZeroByteFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ByteReaperFileDup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let empty1 = root.appendingPathComponent("empty1.txt")
        let empty2 = root.appendingPathComponent("empty2.txt")
        let origURL = root.appendingPathComponent("orig.dat")
        let copyURL = root.appendingPathComponent("copy.dat")
        let diffURL = root.appendingPathComponent("diff.dat")

        try Data().write(to: empty1)
        try Data().write(to: empty2)
        try Data([1, 2, 3, 4, 5, 6, 7, 8]).write(to: origURL)
        try Data([1, 2, 3, 4, 5, 6, 7, 8]).write(to: copyURL)
        try Data([9, 9, 9, 9, 9, 9, 9, 9]).write(to: diffURL)

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let items = [
            ScannedFileItem(url: empty1, name: "empty1.txt", relativePath: "empty1.txt", byteSize: 0, modifiedDate: now),
            ScannedFileItem(url: empty2, name: "empty2.txt", relativePath: "empty2.txt", byteSize: 0, modifiedDate: now),
            ScannedFileItem(url: copyURL, name: "copy.dat", relativePath: "copy.dat", byteSize: 8, modifiedDate: now.addingTimeInterval(120)),
            ScannedFileItem(url: origURL, name: "orig.dat", relativePath: "orig.dat", byteSize: 8, modifiedDate: now),
            ScannedFileItem(url: diffURL, name: "diff.dat", relativePath: "diff.dat", byteSize: 8, modifiedDate: now.addingTimeInterval(60))
        ]

        let groups = await FileFolderScannerService.findDuplicateGroups(in: items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.map(\.name), ["orig.dat", "copy.dat"])
        XCTAssertEqual(groups[0].reclaimableBytes, 8)
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

        let burst3 = TestMediaItem(id: "b3", byteSize: 3_000_000, pixelWidth: 4032, pixelHeight: 3024, mediaTypeRaw: 1, creationDate: baseDate.addingTimeInterval(20))
        let burst2 = TestMediaItem(id: "b2", byteSize: 2_800_000, pixelWidth: 4032, pixelHeight: 3024, mediaTypeRaw: 1, creationDate: baseDate.addingTimeInterval(10))
        let burst1 = TestMediaItem(id: "b1", byteSize: 2_900_000, pixelWidth: 4032, pixelHeight: 3024, mediaTypeRaw: 1, creationDate: baseDate)
        let oldShot = TestMediaItem(id: "old", byteSize: 4_000_000, pixelWidth: 4032, pixelHeight: 3024, mediaTypeRaw: 1, creationDate: baseDate.addingTimeInterval(-200_000))

        let items = [burst3, burst2, burst1, oldShot]
        let clusters = SimilarPhotoClusterer.cluster(items: items) { i, j in
            let ids = Set([items[i].id, items[j].id])
            if ids.isSubset(of: ["b1", "b2", "b3"]) { return 92 }
            return 90
        }

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].items.map(\.id), ["b1", "b2", "b3"])
        XCTAssertEqual(clusters[0].averageSimilarityPercent, 92)
    }

    func testFileCategoryFiltersAndAgeFiltersMatchExpectedLogic() {
        XCTAssertTrue(FileCategoryFilter.video.matches(extension: "MOV"))
        XCTAssertTrue(FileCategoryFilter.image.matches(extension: "heic"))
        XCTAssertTrue(FileCategoryFilter.archive.matches(extension: "ipa"))
        XCTAssertTrue(FileCategoryFilter.document.matches(extension: "PDF"))
        XCTAssertFalse(FileCategoryFilter.video.matches(extension: "pdf"))
        XCTAssertTrue(FileCategoryFilter.all.matches(extension: "xyz"))

        let ref = Date(timeIntervalSince1970: 1_750_000_000)
        let oldFile = ScannedFileItem(
            url: URL(fileURLWithPath: "/tmp/old.zip"),
            name: "old.zip",
            relativePath: "old.zip",
            byteSize: 0,
            modifiedDate: ref.addingTimeInterval(-45 * 86_400)
        )
        let recentFile = ScannedFileItem(
            url: URL(fileURLWithPath: "/tmp/recent.zip"),
            name: "recent.zip",
            relativePath: "recent.zip",
            byteSize: 1024,
            modifiedDate: ref.addingTimeInterval(-5 * 86_400)
        )

        XCTAssertTrue(FileCategoryFilter.empty.matches(item: oldFile, referenceDate: ref))
        XCTAssertFalse(FileCategoryFilter.empty.matches(item: recentFile, referenceDate: ref))
        XCTAssertTrue(FileCategoryFilter.olderThan30Days.matches(item: oldFile, referenceDate: ref))
        XCTAssertFalse(FileCategoryFilter.olderThan30Days.matches(item: recentFile, referenceDate: ref))

        XCTAssertTrue(MediaAgeFilter.olderThan6Months.matches(creationDate: ref.addingTimeInterval(-200 * 86_400), referenceDate: ref))
        XCTAssertFalse(MediaAgeFilter.olderThan6Months.matches(creationDate: ref.addingTimeInterval(-30 * 86_400), referenceDate: ref))
        XCTAssertTrue(MediaAgeFilter.olderThan1Year.matches(creationDate: ref.addingTimeInterval(-400 * 86_400), referenceDate: ref))
    }

    func testLaplacianBlurDetectorDistinguishesBlurryFromSharp() {
        let size = 16
        let flat = [UInt8](repeating: 120, count: size * size)
        let blurVariance = LaplacianBlurDetector.computeVariance(pixels: flat, width: size, height: size)
        XCTAssertLessThan(blurVariance, LaplacianBlurDetector.blurVarianceThreshold)

        var checkerboard = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                checkerboard[y * size + x] = ((x + y) % 2 == 0) ? 240 : 20
            }
        }
        let sharpVariance = LaplacianBlurDetector.computeVariance(pixels: checkerboard, width: size, height: size)
        XCTAssertGreaterThan(sharpVariance, LaplacianBlurDetector.blurVarianceThreshold)
    }

    func testVideoCompressionPresetSelectionCovers720pAndFallbacks() {
        let hevcPicked = VideoCompressionService.preferredExportPreset(
            compatiblePresets: [AVAssetExportPreset1920x1080, AVAssetExportPresetHEVC1920x1080],
            choice: .hevc1080p
        )
        XCTAssertEqual(hevcPicked, AVAssetExportPresetHEVC1920x1080)

        let compactPicked = VideoCompressionService.preferredExportPreset(
            compatiblePresets: [AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality],
            choice: .compact720p
        )
        XCTAssertEqual(compactPicked, AVAssetExportPreset1280x720)

        let fallback = VideoCompressionService.preferredExportPreset(
            compatiblePresets: [AVAssetExportPresetMediumQuality],
            choice: .mp41080p
        )
        XCTAssertEqual(fallback, AVAssetExportPresetMediumQuality)
    }

    func testAllTimeReclaimedStoreAndStorageBreakdownMath() {
        let suiteName = "ByteReaperTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AllTimeReclaimedStore.totalBytes(defaults: defaults), 0)
        XCTAssertEqual(AllTimeReclaimedStore.add(500_000, defaults: defaults), 500_000)
        XCTAssertEqual(AllTimeReclaimedStore.add(-100, defaults: defaults), 500_000)
        XCTAssertEqual(AllTimeReclaimedStore.add(250_000, defaults: defaults), 750_000)
        AllTimeReclaimedStore.reset(defaults: defaults)
        XCTAssertEqual(AllTimeReclaimedStore.totalBytes(defaults: defaults), 0)

        let breakdown = StorageBreakdown(
            videoBytes: 4_000_000_000,
            screenRecordingBytes: 1_500_000_000,
            screenshotBytes: 300_000_000,
            photoBytes: 2_200_000_000
        )
        XCTAssertEqual(breakdown.totalBytes, 8_000_000_000)
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
