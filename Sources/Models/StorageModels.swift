import Foundation
import Photos

/// Snapshot of real device storage telemetry reported by the iOS filesystem.
struct DeviceStorageSnapshot: Equatable {
    let totalBytes: Int64
    let availableImportantBytes: Int64
    let availableStrictBytes: Int64

    /// Bytes currently occupied on disk excluding system-purgeable space.
    var usedBytes: Int64 {
        max(0, totalBytes - availableImportantBytes)
    }

    /// Space iOS marks as reclaimable caches/assets when storage pressure rises.
    var purgeableEstimateBytes: Int64 {
        max(0, availableImportantBytes - availableStrictBytes)
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }

    static let empty = DeviceStorageSnapshot(totalBytes: 0, availableImportantBytes: 0, availableStrictBytes: 0)
}

/// Explicit UI phase so every view handles Idle, Loading, Empty, Permission Denied, and Error states.
enum ScanPhase<Value> {
    case idle
    case permissionDenied
    case scanning(processed: Int, total: Int, statusText: String)
    case loaded(Value)
    case error(String)
}

/// Filter tabs for the PhotoKit largest-media scanner.
enum MediaCategoryFilter: String, CaseIterable, Identifiable {
    case allLargest = "Terbesar"
    case videos = "Video"
    case screenshots = "Screenshot"
    case liveAndBurst = "Live/Burst"
    case duplicates = "Duplikat"

    var id: String { rawValue }
}

/// Protocol enabling duplicate grouping and testing without instantiating PhotoKit objects.
protocol DuplicateGroupable: Identifiable, Hashable where ID == String {
    var byteSize: Int64 { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    var mediaTypeRaw: Int { get }
    var creationDate: Date { get }
}

/// Ranked photo or video asset with exact byte count measured from PHAssetResource.
struct MediaAssetItem: DuplicateGroupable {
    let id: String
    let asset: PHAsset
    let mediaType: PHAssetMediaType
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let creationDate: Date
    let byteSize: Int64
    let filename: String
    let isScreenshot: Bool
    let isLivePhoto: Bool
    let isBurst: Bool

    var mediaTypeRaw: Int { mediaType.rawValue }
    var isVideo: Bool { mediaType == .video }

    var resolutionLabel: String {
        "\(pixelWidth)x\(pixelHeight)"
    }

    static func == (lhs: MediaAssetItem, rhs: MediaAssetItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Group of media assets verified to be byte-identical duplicates via SHA-256.
struct DuplicateGroupGeneric<Item: DuplicateGroupable>: Identifiable, Hashable {
    let id: String
    let sha256: String
    let byteSizeEach: Int64
    /// Sorted oldest-first so index 0 is kept as original and index 1... are suggested for cleanup.
    let items: [Item]

    var reclaimableBytes: Int64 {
        guard items.count > 1 else { return 0 }
        return byteSizeEach * Int64(items.count - 1)
    }
}

typealias DuplicateGroup = DuplicateGroupGeneric<MediaAssetItem>

/// File discovered inside a user-selected Files/On My iPhone/iCloud Drive folder.
struct ScannedFileItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let relativePath: String
    let byteSize: Int64
    let modifiedDate: Date
    let fileExtension: String

    init(url: URL, name: String, relativePath: String, byteSize: Int64, modifiedDate: Date) {
        self.id = url.path
        self.url = url
        self.name = name
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.modifiedDate = modifiedDate
        self.fileExtension = url.pathExtension.lowercased()
    }
}

/// Security-scoped folder bookmark saved in UserDefaults for fast re-scanning.
struct BookmarkedFolder: Identifiable, Codable, Equatable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
}

/// Honest iOS Sandbox manual cleanup step for third-party app caches.
struct AppCleanupChecklistItem: Identifiable, Codable, Equatable {
    let id: String
    let appName: String
    let steps: String
    var isCompleted: Bool
}

