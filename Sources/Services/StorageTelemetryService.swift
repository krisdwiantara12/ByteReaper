import Foundation

/// Reads real iOS volume telemetry and measures/clears this app's own sandbox cache directories.
enum StorageTelemetryService {
    /// Reads current device capacity, used space, and system-purgeable estimate from the home volume.
    static func readDeviceSnapshot() -> DeviceStorageSnapshot {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try homeURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let important = values.volumeAvailableCapacityForImportantUsage ?? 0
            let strict = Int64(values.volumeAvailableCapacity ?? 0)
            return DeviceStorageSnapshot(
                totalBytes: total,
                availableImportantBytes: important,
                availableStrictBytes: strict
            )
        } catch {
            return .empty
        }
    }

    /// Computes total bytes currently stored in this app's own Caches and tmp folders.
    static func measureSelfCacheBytes(fileManager: FileManager = .default) -> Int64 {
        let urls = selfCacheDirectories(fileManager: fileManager)
        var total: Int64 = 0
        for dir in urls {
            total += directorySize(at: dir, fileManager: fileManager)
        }
        return total
    }

    /// Deletes files inside this app's own Caches and tmp directories and returns bytes freed.
    @discardableResult
    static func clearSelfCaches(fileManager: FileManager = .default) -> Int64 {
        let before = measureSelfCacheBytes(fileManager: fileManager)
        for dir in selfCacheDirectories(fileManager: fileManager) {
            guard let children = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            for child in children {
                try? fileManager.removeItem(at: child)
            }
        }
        let after = measureSelfCacheBytes(fileManager: fileManager)
        return max(0, before - after)
    }

    private static func selfCacheDirectories(fileManager: FileManager) -> [URL] {
        var dirs: [URL] = []
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            dirs.append(caches)
        }
        dirs.append(fileManager.temporaryDirectory)
        return dirs
    }

    private static func directorySize(at directory: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var sum: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            sum += Int64(values.fileSize ?? 0)
        }
        return sum
    }
}

