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
    case screenRecordings = "Screen Rec"
    case largePhotos = "Foto >8MB"
    case screenshots = "Screenshot"
    case liveAndBurst = "Live/Burst"
    case duplicates = "Duplikat"
    case similar = "Mirip"
    case blurOrDocuments = "Blur/Dok"

    var id: String { rawValue }
}

/// Age filter applied on top of media library categories.
enum MediaAgeFilter: String, CaseIterable, Identifiable {
    case all = "Semua Waktu"
    case olderThan6Months = "> 6 Bulan"
    case olderThan1Year = "> 1 Tahun"

    var id: String { rawValue }

    func matches(creationDate: Date, referenceDate: Date = Date()) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .all:
            return true
        case .olderThan6Months:
            guard let cutoff = calendar.date(byAdding: .month, value: -6, to: referenceDate) else { return false }
            return creationDate <= cutoff
        case .olderThan1Year:
            guard let cutoff = calendar.date(byAdding: .year, value: -1, to: referenceDate) else { return false }
            return creationDate <= cutoff
        }
    }
}

/// Lightweight metadata for filtering PhotoKit assets by user or smart album.
struct MediaAlbumFilter: Identifiable, Hashable {
    let id: String
    let title: String
    let assetIds: Set<String>
}

/// Mutually exclusive byte breakdown across the scanned media library.
struct StorageBreakdown: Equatable {
    let videoBytes: Int64
    let screenRecordingBytes: Int64
    let screenshotBytes: Int64
    let photoBytes: Int64

    var totalBytes: Int64 {
        videoBytes + screenRecordingBytes + screenshotBytes + photoBytes
    }

    static func compute(from items: [MediaAssetItem]) -> StorageBreakdown {
        var videos: Int64 = 0
        var recordings: Int64 = 0
        var screenshots: Int64 = 0
        var photos: Int64 = 0

        for item in items {
            if item.isVideo && item.isScreenRecording {
                recordings += item.byteSize
            } else if item.isVideo {
                videos += item.byteSize
            } else if item.isScreenshot {
                screenshots += item.byteSize
            } else {
                photos += item.byteSize
            }
        }

        return StorageBreakdown(
            videoBytes: videos,
            screenRecordingBytes: recordings,
            screenshotBytes: screenshots,
            photoBytes: photos
        )
    }
}

/// File extension and heuristic filters for the Files/Downloads scanner.
enum FileCategoryFilter: String, CaseIterable, Identifiable {
    case all = "Semua"
    case video = "Video"
    case image = "Foto"
    case archive = "Arsip/IPA"
    case document = "Dokumen"
    case olderThan30Days = ">30 Hari"
    case empty = "0 KB"
    case duplicates = "Duplikat"

    var id: String { rawValue }

    func matches(extension ext: String) -> Bool {
        let lower = ext.lowercased()
        switch self {
        case .all, .olderThan30Days, .empty, .duplicates:
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

    func matches(item: ScannedFileItem, referenceDate: Date = Date()) -> Bool {
        switch self {
        case .olderThan30Days:
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: referenceDate) else { return false }
            return item.modifiedDate <= cutoff
        case .empty:
            return item.byteSize == 0
        case .all, .video, .image, .archive, .document, .duplicates:
            return matches(extension: item.fileExtension)
        }
    }
}

/// Sort options for scanned files inside Files & Folders.
enum FileSortOrder: String, CaseIterable, Identifiable {
    case largestFirst = "Terbesar"
    case oldestFirst = "Terlama"

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
    let isLocallyAvailable: Bool
    let isScreenRecording: Bool

    init(
        id: String,
        asset: PHAsset,
        mediaType: PHAssetMediaType,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval,
        creationDate: Date,
        byteSize: Int64,
        filename: String,
        isScreenshot: Bool,
        isLivePhoto: Bool,
        isBurst: Bool,
        isLocallyAvailable: Bool,
        isScreenRecording: Bool = false
    ) {
        self.id = id
        self.asset = asset
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.creationDate = creationDate
        self.byteSize = byteSize
        self.filename = filename
        self.isScreenshot = isScreenshot
        self.isLivePhoto = isLivePhoto
        self.isBurst = isBurst
        self.isLocallyAvailable = isLocallyAvailable
        self.isScreenRecording = isScreenRecording
    }

    var mediaTypeRaw: Int { mediaType.rawValue }
    var isVideo: Bool { mediaType == .video }
    var isLargeStaticPhoto: Bool { !isVideo && !isLivePhoto && !isScreenshot && byteSize >= 8_000_000 }

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

/// Classification kind for blurry shots vs receipts/documents/paperwork.
enum ClutterKind: String, Codable, Hashable {
    case blurry = "Blur"
    case document = "Dokumen/Struk"
}

/// Photo flagged offline by CoreImage sharpness or Vision classification heuristics.
struct ClutterMediaItem: Identifiable, Hashable {
    let id: String
    let item: MediaAssetItem
    let kind: ClutterKind
    let detailLabel: String
}

/// Export presets for shrinking huge MOV/4K videos directly inside ByteReaper.
enum VideoCompressionPreset: String, CaseIterable, Identifiable, Codable {
    case hevc1080p = "HEVC 1080p (Hemat)"
    case compact720p = "720p (Ultra Hemat)"
    case mp41080p = "MP4 H.264 1080p"

    var id: String { rawValue }
}

/// Lifecycle state for an item in the persistent batch video compression queue.
enum CompressionJobStatus: String, Codable, Equatable {
    case queued = "Menunggu"
    case compressing = "Mengompres"
    case completed = "Selesai"
    case failed = "Gagal"
    case interrupted = "Dijeda iOS"
}

/// Persisted batch compression job supporting resume after iOS background suspension.
struct CompressionQueueJob: Identifiable, Codable, Equatable {
    let id: String
    let filename: String
    let originalBytes: Int64
    let duration: TimeInterval
    let preset: VideoCompressionPreset
    let stripAudio: Bool
    let deleteOriginalAfterSave: Bool
    var status: CompressionJobStatus
    var progress: Double
    var compressedBytes: Int64?
    var savedLocalIdentifier: String?
    var originalDeleted: Bool = false
    var errorMessage: String?

    var isFinished: Bool {
        status == .completed || status == .failed
    }
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

/// Result summary returned after converting a huge RAW/DNG/PNG photo into HEIC.
struct PhotoConversionResult: Equatable {
    let originalBytes: Int64
    let convertedBytes: Int64
    let savedLocalIdentifier: String

    var savedBytes: Int64 {
        max(0, originalBytes - convertedBytes)
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

/// Byte-identical files inside the scanned folder verified via streaming SHA-256.
struct FileDuplicateGroup: Identifiable, Hashable {
    let id: String
    let sha256: String
    let byteSizeEach: Int64
    /// Sorted oldest modifiedDate first so index 0 is kept as original.
    let items: [ScannedFileItem]

    var reclaimableBytes: Int64 {
        guard items.count > 1 else { return 0 }
        return byteSizeEach * Int64(items.count - 1)
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
