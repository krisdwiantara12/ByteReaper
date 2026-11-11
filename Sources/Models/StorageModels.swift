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
    case similar = "Mirip"

    var id: String { rawValue }
}

/// File extension groups for the Files/Downloads scanner.
enum FileCategoryFilter: String, CaseIterable, Identifiable {
    case all = "Semua"
    case video = "Video"
    case image = "Foto"
    case archive = "Arsip/IPA"
    case document = "Dokumen"

    var id: String { rawValue }

    func matches(extension ext: String) -> Bool {
        let lower = ext.lowercased()
        switch self {
        case .all:
            return true
        case .video:
            return ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(lower)
        case .image:
            return ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "raw", "dng"].contains(lower)
        case .archive:
            return ["zip", "rar", "7z", "tar", "gz", "ipa", "dmg"].contains(lower)
        case .document:
            return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv", "json"].contains(lower)
        }
    }
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
    let isLocallyAvailable: Bool

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

/// Group of visually similar photos detected offline using Apple Vision feature prints.
struct SimilarPhotoGroup: Identifiable, Hashable {
    let id: String
    let averageSimilarityPercent: Int
    /// Sorted oldest-first so index 0 is suggested to keep and index 1... can be removed.
    let items: [MediaAssetItem]

    var reclaimableBytes: Int64 {
        guard items.count > 1 else { return 0 }
        return items.dropFirst().reduce(0) { $0 + $1.byteSize }
    }
}

/// Export presets for shrinking huge MOV/4K videos directly inside ByteReaper.
enum VideoCompressionPreset: String, CaseIterable, Identifiable {
    case hevc1080p = "HEVC 1080p (Hemat)"
    case mp41080p = "MP4 H.264 1080p"

    var id: String { rawValue }
}

/// Result summary returned after compressing a video and saving the smaller copy to Photos.
struct VideoCompressionResult: Equatable {
    let originalBytes: Int64
    let compressedBytes: Int64
    let savedLocalIdentifier: String

    var savedBytes: Int64 {
        max(0, originalBytes - compressedBytes)
    }
}

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
