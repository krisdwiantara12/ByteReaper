import CryptoKit
import Foundation

/// Recursively scans user-granted folders (Files, Downloads, On My iPhone, iCloud Drive)
/// sorted from largest file to smallest, finds byte-identical duplicates via streaming SHA-256,
/// and performs direct file deletion.
@MainActor
final class FileFolderScannerService: ObservableObject {
    @Published private(set) var bookmarks: [BookmarkedFolder] = []
    @Published private(set) var activeFolderName: String?
    @Published private(set) var phase: ScanPhase<[ScannedFileItem]> = .idle
    @Published private(set) var duplicatePhase: ScanPhase<[FileDuplicateGroup]> = .idle
    @Published private(set) var sessionReclaimedBytes: Int64 = 0

    private let defaultsKey = "bytereaper.folderBookmarks.v1"
    private var activeSecurityToken: SecurityScopeToken?
    private var activeFolderURL: URL?
    private var activeScanTask: Task<Void, Never>?
    private var activeDuplicateTask: Task<Void, Never>?

    init() {
        loadBookmarks()
    }

    /// Saves a security-scoped folder bookmark picked via UIDocumentPickerViewController and scans it.
    func addAndScanFolder(url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer {
            if granted { url.stopAccessingSecurityScopedResource() }
        }

        if let data = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            let name = url.lastPathComponent.isEmpty ? "Folder Terpilih" : url.lastPathComponent
            if !bookmarks.contains(where: { $0.displayName == name }) {
                bookmarks.insert(BookmarkedFolder(id: UUID(), displayName: name, bookmarkData: data), at: 0)
                persistBookmarks()
            }
        }

        scanFolder(url: url, displayName: url.lastPathComponent)
    }

    func scanBookmark(_ bookmark: BookmarkedFolder) {
        var isStale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmark.bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale,
               let refreshed = try? resolvedURL.bookmarkData(
                   options: .minimalBookmark,
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ),
               let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                bookmarks[idx] = BookmarkedFolder(id: bookmark.id, displayName: bookmark.displayName, bookmarkData: refreshed)
                persistBookmarks()
            }
            scanFolder(url: resolvedURL, displayName: bookmark.displayName)
        } catch {
            phase = .error("Akses folder '\(bookmark.displayName)' kedaluwarsa. Pilih ulang folder lewat tombol di atas.")
        }
    }

    func removeBookmark(_ bookmark: BookmarkedFolder) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persistBookmarks()
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

    func rescanActiveFolder() {
        if let activeFolderURL {
            scanFolder(url: activeFolderURL, displayName: activeFolderName ?? activeFolderURL.lastPathComponent)
        } else if let name = activeFolderName,
                  let bookmark = bookmarks.first(where: { $0.displayName == name }) {
            scanBookmark(bookmark)
        }
    }

    func scanFolder(url: URL, displayName: String) {
        activeScanTask?.cancel()
        activeDuplicateTask?.cancel()
        activeSecurityToken = SecurityScopeToken(url: url)
        activeFolderURL = url

        activeFolderName = displayName.isEmpty ? url.lastPathComponent : displayName
        phase = .scanning(processed: 0, total: 0, statusText: "Memindai folder \(activeFolderName ?? "")...")
        duplicatePhase = .idle

        activeScanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await Self.enumerateLargestFiles(in: url) { count in
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.phase = .scanning(
                            processed: count,
                            total: count,
                            statusText: "Menemukan \(count) file..."
                        )
                    }
                }
                guard !Task.isCancelled else { return }
                self.phase = .loaded(items)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .error("Gagal membaca isi folder: \(error.localizedDescription)")
            }
        }
    }

    /// Computes streaming SHA-256 duplicates across scanned files having matching non-zero byte sizes.
    func findDuplicatesIfNeeded() {
        guard case .loaded(let items) = phase else { return }
        if case .loaded = duplicatePhase { return }
        if case .scanning = duplicatePhase { return }

        let sizeBuckets = Dictionary(grouping: items.filter { $0.byteSize > 0 }, by: \.byteSize)
            .values
            .filter { $0.count >= 2 }
        let candidateCount = sizeBuckets.reduce(0) { $0 + $1.count }

        guard candidateCount >= 2 else {
            duplicatePhase = .loaded([])
            return
        }

        duplicatePhase = .scanning(
            processed: 0,
            total: candidateCount,
            statusText: "Memeriksa SHA-256 \(candidateCount) kandidat duplikat..."
        )

        activeDuplicateTask = Task { [weak self] in
            guard let self else { return }
            let groups = await Self.findDuplicateGroups(in: items) { processed, total in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.duplicatePhase = .scanning(
                        processed: processed,
                        total: total,
                        statusText: "Memeriksa file identik (\(processed)/\(total))..."
                    )
                }
            }
            guard !Task.isCancelled else { return }
            self.duplicatePhase = .loaded(groups)
        }
    }

    /// Deletes selected files directly from disk and returns total freed bytes.
    func deleteFiles(ids: Set<String>) -> (freedBytes: Int64, failedCount: Int) {
        guard case .loaded(let currentItems) = phase else { return (0, 0) }
        let targets = currentItems.filter { ids.contains($0.id) }
        var deletedIds = Set<String>()
        var freed: Int64 = 0
        var failed = 0

        for item in targets {
            do {
                try FileManager.default.removeItem(at: item.url)
                deletedIds.insert(item.id)
                freed += item.byteSize
            } catch {
                failed += 1
            }
        }

        sessionReclaimedBytes += freed
        if freed > 0 {
            AllTimeReclaimedStore.add(freed)
        }

        let remaining = currentItems.filter { !deletedIds.contains($0.id) }
        phase = .loaded(remaining)

        if case .loaded(let groups) = duplicatePhase {
            let updatedGroups: [FileDuplicateGroup] = groups.compactMap { group in
                let kept = group.items.filter { !deletedIds.contains($0.id) }
                guard kept.count >= 2 else { return nil }
                return FileDuplicateGroup(
                    id: group.id,
                    sha256: group.sha256,
                    byteSizeEach: group.byteSizeEach,
                    items: kept
                )
            }
            duplicatePhase = .loaded(updatedGroups)
        }

        return (freed, failed)
    }

    /// Pure non-actor helper exposed as internal for direct unit testing in ByteReaperTests.
    nonisolated static func findDuplicateGroups(
        in items: [ScannedFileItem],
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [FileDuplicateGroup] {
        await Task.detached(priority: .utility) {
            let buckets = Dictionary(grouping: items.filter { $0.byteSize > 0 }, by: \.byteSize)
                .values
                .filter { $0.count >= 2 }
                .sorted { ($0.first?.byteSize ?? 0) > ($1.first?.byteSize ?? 0) }

            let candidates = buckets.flatMap { $0 }
            guard !candidates.isEmpty else { return [] }

            var byHash: [String: [ScannedFileItem]] = [:]
            for (index, item) in candidates.enumerated() {
                if Task.isCancelled { return [] }
                if let hash = streamingSHA256(for: item.url) {
                    byHash[hash, default: []].append(item)
                }
                if let onProgress, (index % 5 == 0 || index + 1 == candidates.count) {
                    await onProgress(index + 1, candidates.count)
                    await Task.yield()
                }
            }

            return byHash.compactMap { hash, groupItems in
                guard groupItems.count >= 2 else { return nil }
                let sortedOldestFirst = groupItems.sorted { $0.modifiedDate < $1.modifiedDate }
                let sizeEach = sortedOldestFirst.first?.byteSize ?? 0
                return FileDuplicateGroup(
                    id: hash,
                    sha256: hash,
                    byteSizeEach: sizeEach,
                    items: sortedOldestFirst
                )
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        }.value
    }

    nonisolated private static func streamingSHA256(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let shouldContinue = autoreleasepool { () -> Bool in
                guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else {
                    return false
                }
                hasher.update(data: chunk)
                return true
            }
            if !shouldContinue { break }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Pure non-actor helper exposed as internal for direct unit testing in ByteReaperTests.
    nonisolated static func enumerateLargestFiles(
        in rootURL: URL,
        onProgress: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> [ScannedFileItem] {
        try await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .fileSizeKey,
                .fileAllocatedSizeKey,
                .contentModificationDateKey
            ]

            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            ) else {
                throw NSError(
                    domain: "ByteReaper.FileScanner",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Folder tidak dapat diakses atau bukan direktori yang valid."]
                )
            }

            let basePath = rootURL.standardizedFileURL.path
            var results: [ScannedFileItem] = []

            for case let fileURL as URL in enumerator {
                if Task.isCancelled { return [] }
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else {
                    continue
                }

                let byteSize = Int64(values.fileSize ?? values.fileAllocatedSize ?? 0)
                let modified = values.contentModificationDate ?? Date.distantPast
                let fullPath = fileURL.standardizedFileURL.path
                let relPath: String
                if fullPath.hasPrefix(basePath) {
                    let trimmed = String(fullPath.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    relPath = trimmed.isEmpty ? fileURL.lastPathComponent : trimmed
                } else {
                    relPath = fileURL.lastPathComponent
                }

                results.append(
                    ScannedFileItem(
                        url: fileURL,
                        name: fileURL.lastPathComponent,
                        relativePath: relPath,
                        byteSize: byteSize,
                        modifiedDate: modified
                    )
                )

                if let onProgress, results.count % 100 == 0 {
                    await onProgress(results.count)
                    await Task.yield()
                }
            }

            return results.sorted { $0.byteSize > $1.byteSize }
        }.value
    }

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([BookmarkedFolder].self, from: data) else {
            return
        }
        bookmarks = decoded
    }

    private func persistBookmarks() {
        guard let encoded = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(encoded, forKey: defaultsKey)
    }
}

private final class SecurityScopeToken: @unchecked Sendable {
    private let url: URL
    private let isActive: Bool

    init(url: URL) {
        self.url = url
        self.isActive = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isActive {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
