import Foundation
import UserNotifications

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

/// Persists cumulative bytes reclaimed across app sessions.
enum AllTimeReclaimedStore {
    static let storageKey = "ByteReaper.AllTimeReclaimedBytes.v1"

    static func totalBytes(defaults: UserDefaults = .standard) -> Int64 {
        let value = defaults.object(forKey: storageKey) as? NSNumber
        return max(0, value?.int64Value ?? 0)
    }

    @discardableResult
    static func add(_ bytes: Int64, defaults: UserDefaults = .standard) -> Int64 {
        guard bytes > 0 else { return totalBytes(defaults: defaults) }
        let updated = totalBytes(defaults: defaults) + bytes
        defaults.set(NSNumber(value: updated), forKey: storageKey)
        return updated
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// Manages local notifications for compression completion and optional weekly cleanup reminders.
enum NotificationReminderService {
    static let weeklyEnabledKey = "ByteReaper.WeeklyReminderEnabled.v1"
    static let weeklyIdentifier = "com.kris.storage.bytereaper.weeklyReminder"

    static func isWeeklyReminderEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: weeklyEnabledKey)
    }

    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    @discardableResult
    static func setWeeklyReminder(enabled: Bool, defaults: UserDefaults = .standard) async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [weeklyIdentifier])

        guard enabled else {
            defaults.set(false, forKey: weeklyEnabledKey)
            return true
        }

        let granted = await requestAuthorizationIfNeeded()
        guard granted else {
            defaults.set(false, forKey: weeklyEnabledKey)
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = "Saatnya Cek Storage iPhone"
        content.body = "Cek video 4K baru, screenshot lama, dan file duplikat di ByteReaper."
        content.sound = .default

        var components = DateComponents()
        components.weekday = 1 // Sunday 10:00 AM local time
        components.hour = 10
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: weeklyIdentifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
            defaults.set(true, forKey: weeklyEnabledKey)
            return true
        } catch {
            defaults.set(false, forKey: weeklyEnabledKey)
            return false
        }
    }

    static func sendCompressionNotification(
        title: String,
        body: String,
        identifier: String = "com.kris.storage.bytereaper.compression"
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
        guard allowed else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }
}


