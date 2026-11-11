import Foundation

/// Recursively scans user-granted folders (Files, Downloads, On My iPhone, iCloud Drive)
/// sorted from largest file to smallest, and performs direct file deletion.
@MainActor
final class FileFolderScannerService: ObservableObject {
    @Published private(set) var bookmarks: [BookmarkedFolder] = []
    @Published private(set) var activeFolderName: String?
    @Published private(set) var phase: ScanPhase<[ScannedFileItem]> = .idle
    @Published private(set) var sessionReclaimedBytes: Int64 = 0

    private let defaultsKey = "bytereaper.folderBookmarks.v1"
    private var activeSecurityToken: SecurityScopeToken?
    private var activeFolderURL: URL?
    private var activeScanTask: Task<Void, Never>?

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
        if case .scanning = phase {
            phase = .idle
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
        activeSecurityToken = SecurityScopeToken(url: url)
        activeFolderURL = url

        activeFolderName = displayName.isEmpty ? url.lastPathComponent : displayName
        phase = .scanning(processed: 0, total: 0, statusText: "Memindai folder \(activeFolderName ?? "")...")

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
        let remaining = currentItems.filter { !deletedIds.contains($0.id) }
        phase = .loaded(remaining)
        return (freed, failed)
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
