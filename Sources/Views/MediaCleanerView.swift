import Photos
import SwiftUI

/// Scans PhotoKit assets, ranks them strictly from largest byte size to smallest,
/// supports category filtering, Local-only toggle, preview & video compression,
/// SHA-256 duplicates, Vision similar photos, and batch delete.
struct MediaCleanerView: View {
    @ObservedObject var scanner: PhotoScannerService
    @Binding var selectedIds: Set<String>
    let onSingleDelete: (MediaAssetItem) -> Void
    let onVideoCompressed: () -> Void

    @State private var activeFilter: MediaCategoryFilter = .allLargest
    @State private var localOnly: Bool = false
    @State private var searchText: String = ""
    @State private var previewItem: MediaAssetItem?

    private var filteredItems: [MediaAssetItem] {
        guard case .loaded(let allItems) = scanner.phase else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let categoryFiltered = allItems.filter { item in
            if localOnly && !item.isLocallyAvailable {
                return false
            }
            switch activeFilter {
            case .allLargest:
                return true
            case .videos:
                return item.isVideo
            case .screenshots:
                return item.isScreenshot
            case .liveAndBurst:
                return item.isLivePhoto || item.isBurst
            case .duplicates, .similar:
                return false
            }
        }

        if query.isEmpty {
            return categoryFiltered
        }
        return categoryFiltered.filter { $0.filename.lowercased().contains(query) }
    }

    private var maxBytesInFilter: Int64 {
        filteredItems.first?.byteSize ?? 1
    }

    var body: some View {
        VStack(spacing: 12) {
            filterStrip

            if let bgStatus = scanner.backgroundPhotoScanStatus {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(CyberTheme.cyberCyan)
                        .scaleEffect(0.85)
                    Text(bgStatus)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(CyberTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(CyberTheme.cyberCyan.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }

            switch scanner.phase {
            case .idle:
                idleStateCard
            case .permissionDenied:
                permissionDeniedCard
            case .scanning(let processed, let total, let statusText):
                scanningStateCard(processed: processed, total: total, statusText: statusText)
            case .error(let message):
                errorStateCard(message: message)
            case .loaded(let allItems):
                if allItems.isEmpty {
                    emptyStateCard(title: "Galeri Foto Kosong", detail: "Tidak ditemukan foto atau video yang tersimpan di perpustakaan foto.")
                } else if activeFilter == .duplicates {
                    duplicatesSection
                } else if activeFilter == .similar {
                    similarSection
                } else {
                    loadedMediaList
                }
            }
        }
        .sheet(item: $previewItem) { item in
            MediaPreviewSheet(
                item: item,
                scanner: scanner,
                onDelete: { onSingleDelete(item) },
                onCompressedAndSaved: onVideoCompressed
            )
        }
        .onChange(of: activeFilter) { newValue in
            if newValue == .duplicates {
                scanner.findDuplicatesIfNeeded()
            } else if newValue == .similar {
                scanner.findSimilarPhotosIfNeeded()
            }
        }
    }

    // MARK: - Subviews

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaCategoryFilter.allCases) { filter in
                    let isSelected = activeFilter == filter
                    Button {
                        HapticFeedback.selection()
                        withAnimation(.easeInOut(duration: 0.16)) {
                            activeFilter = filter
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline.weight(isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? CyberTheme.cyanInk : CyberTheme.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(
                                isSelected ? CyberTheme.cyberCyan : CyberTheme.elevatedSurface,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isSelected ? CyberTheme.cyberCyan : CyberTheme.hairlineBorder, lineWidth: 1)
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var loadedMediaList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(CyberTheme.textSecondary)
                    TextField("Cari nama file...", text: $searchText)
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
                    HapticFeedback.selection()
                    localOnly.toggle()
                } label: {
                    Text("Lokal")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(localOnly ? CyberTheme.cyanInk : CyberTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(
                            localOnly ? CyberTheme.cyberCyan : CyberTheme.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(localOnly ? CyberTheme.cyberCyan : CyberTheme.hairlineBorder, lineWidth: 1)
                        )
                }
                .accessibilityLabel("Filter hanya file lokal di memori iPhone")

                Button {
                    toggleSelectTopTen()
                } label: {
                    Text(selectedIds.isEmpty ? "Top 10" : "Reset")
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

            if filteredItems.isEmpty {
                emptyStateCard(
                    title: "Tidak Ada Hasil",
                    detail: "Tidak ada media yang cocok dengan filter '\(activeFilter.rawValue)' saat ini."
                )
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filteredItems) { item in
                        MediaAssetRow(
                            item: item,
                            maxBytes: maxBytesInFilter,
                            isSelected: selectedIds.contains(item.id),
                            scanner: scanner,
                            onPreview: { previewItem = item },
                            onToggleSelect: { toggleSelection(for: item.id) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 110)
            }
        }
    }

    @ViewBuilder
    private var duplicatesSection: some View {
        switch scanner.duplicatePhase {
        case .idle:
            scanningStateCard(processed: 0, total: 0, statusText: "Menyiapkan pengecekan duplikat...")
                .onAppear { scanner.findDuplicatesIfNeeded() }
        case .scanning(let processed, let total, let statusText):
            scanningStateCard(processed: processed, total: total, statusText: statusText)
        case .permissionDenied:
            permissionDeniedCard
        case .error(let msg):
            errorStateCard(message: msg)
        case .loaded(let groups):
            if groups.isEmpty {
                emptyStateCard(
                    title: "Tidak Ada Duplikat Identik",
                    detail: "Semua file dengan ukuran sama memiliki hash SHA-256 yang berbeda."
                )
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Text("\(groups.count) grup duplikat terverifikasi")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CyberTheme.textSecondary)
                        Spacer()
                        Button {
                            selectAllDuplicateCopies(in: groups.map(\.items))
                        } label: {
                            Text("Pilih Semua Salinan")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CyberTheme.cyberCyan)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                                )
                        }
                    }
                    .padding(.horizontal, 16)

                    LazyVStack(spacing: 12) {
                        ForEach(groups) { group in
                            ClusterGroupCard(
                                headerTitle: "\(group.items.count) salinan identik",
                                savingsText: "Hemat \(ByteFormatter.string(from: group.reclaimableBytes))",
                                secondaryTag: "SALINAN",
                                items: group.items,
                                selectedIds: $selectedIds,
                                onPreview: { previewItem = $0 }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 110)
                }
            }
        }
    }

    @ViewBuilder
    private var similarSection: some View {
        switch scanner.similarPhase {
        case .idle:
            scanningStateCard(processed: 0, total: 0, statusText: "Menyiapkan analisis Vision untuk foto mirip...")
                .onAppear { scanner.findSimilarPhotosIfNeeded() }
        case .scanning(let processed, let total, let statusText):
            scanningStateCard(processed: processed, total: total, statusText: statusText)
        case .permissionDenied:
            permissionDeniedCard
        case .error(let msg):
            errorStateCard(message: msg)
        case .loaded(let groups):
            if groups.isEmpty {
                emptyStateCard(
                    title: "Tidak Ada Foto Mirip",
                    detail: "Tidak ditemukan rangkaian foto lokal yang hampir sama dalam 24 jam berdekatan."
                )
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Text("\(groups.count) grup foto mirip (Vision offline)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CyberTheme.textSecondary)
                        Spacer()
                        Button {
                            selectAllDuplicateCopies(in: groups.map(\.items))
                        } label: {
                            Text("Pilih Semua Salinan")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CyberTheme.cyberCyan)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                                )
                        }
                    }
                    .padding(.horizontal, 16)

                    LazyVStack(spacing: 12) {
                        ForEach(groups) { group in
                            ClusterGroupCard(
                                headerTitle: "\(group.items.count) foto · ~\(group.averageSimilarityPercent)% mirip",
                                savingsText: "Hemat \(ByteFormatter.string(from: group.reclaimableBytes))",
                                secondaryTag: "MIRIP",
                                items: group.items,
                                selectedIds: $selectedIds,
                                onPreview: { previewItem = $0 }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 110)
                }
            }
        }
    }

    private var idleStateCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.largeTitle)
                .foregroundStyle(CyberTheme.cyberCyan)

            Text("Cari Foto & Video Terbesar")
                .font(.headline)
                .foregroundStyle(CyberTheme.textPrimary)

            Text("ByteReaper memindai video terbesar lebih dulu agar langsung tampil cepat, menandai file Lokal vs iCloud, dan mengurutkannya dari ukuran terbesar.")
                .font(.subheadline)
                .foregroundStyle(CyberTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await scanner.requestAuthorizationAndScan() }
            } label: {
                Text("Pindai Galeri Sekarang")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CyberTheme.cyanInk)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .background(CyberTheme.cyberCyan, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(20)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var permissionDeniedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(CyberTheme.crimsonText)

            Text("Izin Galeri Foto Ditolak")
                .font(.headline)
                .foregroundStyle(CyberTheme.textPrimary)

            Text("Berikan izin akses Foto di Pengaturan iPhone agar aplikasi dapat membaca ukuran file dan menghapus media yang Anda pilih.")
                .font(.subheadline)
                .foregroundStyle(CyberTheme.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Buka Pengaturan")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CyberTheme.cyanInk)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 46)
                        .background(CyberTheme.cyberCyan, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button {
                    Task { await scanner.requestAuthorizationAndScan() }
                } label: {
                    Text("Coba Lagi")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CyberTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 46)
                        .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                        )
                }
            }
        }
        .padding(20)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func scanningStateCard(processed: Int, total: Int, statusText: String) -> some View {
        VStack(spacing: 14) {
            if total > 0 {
                ProgressView(value: Double(processed), total: Double(total))
                    .tint(CyberTheme.cyberCyan)
            } else {
                ProgressView()
                    .tint(CyberTheme.cyberCyan)
            }

            Text(statusText)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(CyberTheme.textPrimary)
                .multilineTextAlignment(.center)

            Button {
                scanner.cancelScan()
            } label: {
                Text("Batalkan Pemindaian")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CyberTheme.crimsonText)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                    )
            }
        }
        .padding(20)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func errorStateCard(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(CyberTheme.crimsonText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(CyberTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                scanner.startScan()
            } label: {
                Text("Coba Pindai Ulang")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CyberTheme.cyanInk)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(CyberTheme.cyberCyan, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(20)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func emptyStateCard(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
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
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Selection Helpers

    private func toggleSelection(for id: String) {
        HapticFeedback.selection()
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func toggleSelectTopTen() {
        HapticFeedback.selection()
        if !selectedIds.isEmpty {
            selectedIds.removeAll()
            return
        }
        for item in filteredItems.prefix(10) {
            selectedIds.insert(item.id)
        }
    }

    private func selectAllDuplicateCopies(in groups: [[MediaAssetItem]]) {
        HapticFeedback.selection()
        for groupItems in groups {
            for copy in groupItems.dropFirst() {
                selectedIds.insert(copy.id)
            }
        }
    }
}

// MARK: - Row & Cluster Group Views

private struct MediaAssetRow: View {
    let item: MediaAssetItem
    let maxBytes: Int64
    let isSelected: Bool
    let scanner: PhotoScannerService
    let onPreview: () -> Void
    let onToggleSelect: () -> Void

    @State private var thumbnail: UIImage?

    private var proportion: Double {
        guard maxBytes > 0 else { return 0 }
        return min(1.0, max(0.04, Double(item.byteSize) / Double(maxBytes)))
    }

    private var typeLabel: String {
        if item.isVideo { return "Video · \(ByteFormatter.durationString(item.duration))" }
        if item.isScreenshot { return "Screenshot · \(item.resolutionLabel)" }
        if item.isLivePhoto { return "Live Photo · \(item.resolutionLabel)" }
        return "Foto · \(item.resolutionLabel)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPreview) {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        Group {
                            if let thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle()
                                    .fill(CyberTheme.oledBlack)
                                    .overlay(
                                        Image(systemName: item.isVideo ? "film" : "photo")
                                            .foregroundStyle(CyberTheme.textSecondary)
                                    )
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        if item.isVideo {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.white)
                                .padding(4)
                                .background(CyberTheme.oledBlack.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .padding(3)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.filename)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CyberTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(ByteFormatter.string(from: item.byteSize))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(CyberTheme.cyberCyan)
                        }

                        HStack(spacing: 6) {
                            Text(typeLabel)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(CyberTheme.textSecondary)
                                .lineLimit(1)

                            Spacer()

                            Label(
                                item.isLocallyAvailable ? "Lokal" : "iCloud",
                                systemImage: item.isLocallyAvailable ? "internaldrive" : "icloud"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.isLocallyAvailable ? CyberTheme.acidMint : CyberTheme.textSecondary)
                        }

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

            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? CyberTheme.cyberCyan : CyberTheme.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isSelected ? "Batalkan pilih \(item.filename)" : "Pilih \(item.filename)")
        }
        .padding(10)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? CyberTheme.cyberCyan.opacity(0.75) : CyberTheme.hairlineBorder, lineWidth: 1)
        )
        .task(id: item.id) {
            thumbnail = await scanner.loadThumbnail(for: item.asset, targetSize: CGSize(width: 120, height: 120))
        }
    }
}

private struct ClusterGroupCard: View {
    let headerTitle: String
    let savingsText: String
    let secondaryTag: String
    let items: [MediaAssetItem]
    @Binding var selectedIds: Set<String>
    let onPreview: (MediaAssetItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(headerTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CyberTheme.textPrimary)
                Spacer()
                Text(savingsText)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(CyberTheme.acidMint)
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Button {
                        onPreview(item)
                    } label: {
                        HStack(spacing: 10) {
                            Text(index == 0 ? "ASLI" : secondaryTag)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(index == 0 ? CyberTheme.mintInk : CyberTheme.textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    index == 0 ? CyberTheme.acidMint : CyberTheme.oledBlack,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.filename)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(CyberTheme.textPrimary)
                                    .lineLimit(1)
                                Text(item.creationDate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(CyberTheme.textSecondary)
                            }
                            Spacer()
                            Text(ByteFormatter.string(from: item.byteSize))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(CyberTheme.cyberCyan)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        HapticFeedback.selection()
                        if selectedIds.contains(item.id) {
                            selectedIds.remove(item.id)
                        } else {
                            selectedIds.insert(item.id)
                        }
                    } label: {
                        Image(systemName: selectedIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedIds.contains(item.id) ? CyberTheme.cyberCyan : CyberTheme.textSecondary)
                            .frame(width: 44, height: 44)
                    }
                }
            }
        }
        .padding(12)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }
}
