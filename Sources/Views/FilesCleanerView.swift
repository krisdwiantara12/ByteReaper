import QuickLook
import SwiftUI

/// Scans user-selected Files / Downloads / On My iPhone / iCloud folders recursively,
/// ranks files from largest to smallest, filters by file category, opens QuickLook previews,
/// and deletes files directly with clear single-item or batch confirmation.
struct FilesCleanerView: View {
    @ObservedObject var scanner: FileFolderScannerService
    @Binding var selectedFileIds: Set<String>
    let onSingleDelete: (ScannedFileItem) -> Void

    @State private var showFolderPicker = false
    @State private var previewURL: URL?
    @State private var searchText = ""
    @State private var activeCategory: FileCategoryFilter = .all
    @State private var pendingSingleDelete: ScannedFileItem?

    private var filteredFiles: [ScannedFileItem] {
        guard case .loaded(let files) = scanner.phase else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return files.filter { file in
            guard activeCategory.matches(extension: file.fileExtension) else { return false }
            if query.isEmpty { return true }
            return file.name.lowercased().contains(query) || file.relativePath.lowercased().contains(query)
        }
    }

    private var totalFilteredBytes: Int64 {
        filteredFiles.reduce(0) { $0 + $1.byteSize }
    }

    private var maxBytes: Int64 {
        filteredFiles.first?.byteSize ?? 1
    }

    var body: some View {
        VStack(spacing: 12) {
            headerControls

            if !scanner.bookmarks.isEmpty {
                bookmarkChips
            }

            switch scanner.phase {
            case .idle, .permissionDenied:
                idleFolderCard
            case .scanning(_, _, let statusText):
                scanningCard(statusText: statusText)
            case .error(let msg):
                errorCard(message: msg)
            case .loaded(let items):
                if items.isEmpty {
                    emptyCard(title: "Folder Kosong", detail: "Tidak ditemukan file reguler di folder '\(scanner.activeFolderName ?? "")'.")
                } else {
                    loadedFileList
                }
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerSheet { url in
                selectedFileIds.removeAll()
                scanner.addAndScanFolder(url: url)
            }
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(
            pendingSingleDelete.map { "Hapus permanen '\($0.name)' (\(ByteFormatter.string(from: $0.byteSize)))?" } ?? "",
            isPresented: Binding(
                get: { pendingSingleDelete != nil },
                set: { if !$0 { pendingSingleDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Hapus Permanen", role: .destructive) {
                if let target = pendingSingleDelete {
                    pendingSingleDelete = nil
                    onSingleDelete(target)
                }
            }
            Button("Batal", role: .cancel) {
                pendingSingleDelete = nil
            }
        }
    }

    private var headerControls: some View {
        HStack(spacing: 10) {
            Button {
                showFolderPicker = true
            } label: {
                Label("Pilih Folder (Files / Downloads)", systemImage: "folder.badge.plus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CyberTheme.cyanInk)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
                    .background(CyberTheme.cyberCyan, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
    }

    private var bookmarkChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(scanner.bookmarks) { bookmark in
                    let isActive = scanner.activeFolderName == bookmark.displayName
                    HStack(spacing: 4) {
                        Button {
                            HapticFeedback.selection()
                            selectedFileIds.removeAll()
                            scanner.scanBookmark(bookmark)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                Text(bookmark.displayName)
                                    .lineLimit(1)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isActive ? CyberTheme.cyberCyan : CyberTheme.textPrimary)
                            .padding(.leading, 12)
                            .frame(minHeight: 44)
                        }

                        Button {
                            scanner.removeBookmark(bookmark)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(CyberTheme.textSecondary)
                                .frame(width: 32, height: 44)
                        }
                        .accessibilityLabel("Hapus bookmark \(bookmark.displayName)")
                    }
                    .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isActive ? CyberTheme.cyberCyan : CyberTheme.hairlineBorder, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var loadedFileList: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FileCategoryFilter.allCases) { category in
                        let isSelected = activeCategory == category
                        Button {
                            HapticFeedback.selection()
                            activeCategory = category
                        } label: {
                            Text(category.rawValue)
                                .font(.caption.weight(isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? CyberTheme.cyanInk : CyberTheme.textSecondary)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(
                                    isSelected ? CyberTheme.cyberCyan : CyberTheme.elevatedSurface,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(isSelected ? CyberTheme.cyberCyan : CyberTheme.hairlineBorder, lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(CyberTheme.textSecondary)
                    TextField("Cari file atau path...", text: $searchText)
                        .font(.subheadline)
                        .foregroundStyle(CyberTheme.textPrimary)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                )

                Button {
                    toggleSelectTopTen()
                } label: {
                    Text(selectedFileIds.isEmpty ? "Top 10" : "Reset")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CyberTheme.cyberCyan)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 16)

            HStack {
                Text("\(filteredFiles.count) file · Total \(ByteFormatter.string(from: totalFilteredBytes))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(CyberTheme.textSecondary)
                Spacer()
                if let folderName = scanner.activeFolderName {
                    Text(folderName)
                        .font(.caption)
                        .foregroundStyle(CyberTheme.cyberCyan)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)

            if filteredFiles.isEmpty {
                emptyCard(title: "Tidak Ada File Cocok", detail: "Ubah filter kategori atau kata kunci pencarian Anda.")
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filteredFiles) { file in
                        FileRowView(
                            file: file,
                            maxBytes: maxBytes,
                            isSelected: selectedFileIds.contains(file.id),
                            onPreview: { previewURL = file.url },
                            onToggleSelect: {
                                HapticFeedback.selection()
                                if selectedFileIds.contains(file.id) {
                                    selectedFileIds.remove(file.id)
                                } else {
                                    selectedFileIds.insert(file.id)
                                }
                            },
                            onRequestDelete: { pendingSingleDelete = file }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 110)
            }
        }
    }

    private var idleFolderCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(CyberTheme.cyberCyan)
            Text("Scan Folder di Aplikasi Files")
                .font(.headline)
                .foregroundStyle(CyberTheme.textPrimary)
            Text("Pilih folder Downloads, On My iPhone, atau folder ekspor app lain lewat pemilih Files di atas untuk melihat file terbesar dan menghapusnya langsung.")
                .font(.subheadline)
                .foregroundStyle(CyberTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func scanningCard(statusText: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(CyberTheme.cyberCyan)
            Text(statusText)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(CyberTheme.textPrimary)
            Button {
                scanner.cancelScan()
            } label: {
                Text("Batalkan")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CyberTheme.crimsonText)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                    )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(CyberTheme.crimsonText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(CyberTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showFolderPicker = true
            } label: {
                Text("Pilih Ulang Folder")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CyberTheme.cyanInk)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(CyberTheme.cyberCyan, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func emptyCard(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.title)
                .foregroundStyle(CyberTheme.acidMint)
            Text(title)
                .font(.headline)
                .foregroundStyle(CyberTheme.textPrimary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(CyberTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func toggleSelectTopTen() {
        HapticFeedback.selection()
        if !selectedFileIds.isEmpty {
            selectedFileIds.removeAll()
            return
        }
        for file in filteredFiles.prefix(10) {
            selectedFileIds.insert(file.id)
        }
    }
}

private struct FileRowView: View {
    let file: ScannedFileItem
    let maxBytes: Int64
    let isSelected: Bool
    let onPreview: () -> Void
    let onToggleSelect: () -> Void
    let onRequestDelete: () -> Void

    private var proportion: Double {
        guard maxBytes > 0 else { return 0 }
        return min(1.0, max(0.04, Double(file.byteSize) / Double(maxBytes)))
    }

    private var iconName: String {
        if FileCategoryFilter.video.matches(extension: file.fileExtension) { return "film" }
        if FileCategoryFilter.image.matches(extension: file.fileExtension) { return "photo" }
        if FileCategoryFilter.archive.matches(extension: file.fileExtension) { return "archivebox" }
        if FileCategoryFilter.document.matches(extension: file.fileExtension) { return "doc.text" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPreview) {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.title3)
                        .foregroundStyle(CyberTheme.cyberCyan)
                        .frame(width: 44, height: 44)
                        .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(file.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CyberTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(ByteFormatter.string(from: file.byteSize))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(CyberTheme.cyberCyan)
                        }

                        Text(file.relativePath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(CyberTheme.textSecondary)
                            .lineLimit(1)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(CyberTheme.oledBlack)
                                Capsule()
                                    .fill(isSelected ? CyberTheme.crimsonText : CyberTheme.cyberCyan.opacity(0.7))
                                    .frame(width: geo.size.width * proportion)
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
            .buttonStyle(.plain)

            Button(action: onRequestDelete) {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(CyberTheme.crimsonText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Hapus \(file.name)")

            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? CyberTheme.cyberCyan : CyberTheme.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isSelected ? "Batalkan pilih \(file.name)" : "Pilih \(file.name)")
        }
        .padding(10)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? CyberTheme.cyberCyan.opacity(0.75) : CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }
}
