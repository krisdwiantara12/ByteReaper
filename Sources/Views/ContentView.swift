import SwiftUI

private enum CleanerTab: String, CaseIterable, Identifiable {
    case media = "Media"
    case files = "Files"
    case guide = "Panduan"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .media: return "photo.on.rectangle"
        case .files: return "folder"
        case .guide: return "checklist"
        }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Root coordinator pinning StorageHUDCard at top, tracking scroll offset for compact mode,
/// and switching the Floating Glass Dock (Glass Surface #2 of 2) into a contextual Batch Delete Bar.
struct ContentView: View {
    @StateObject private var photoScanner = PhotoScannerService()
    @StateObject private var fileScanner = FileFolderScannerService()

    @State private var activeTab: CleanerTab = .media
    @State private var storageSnapshot: DeviceStorageSnapshot = StorageTelemetryService.readDeviceSnapshot()
    @State private var extraReclaimedBytes: Int64 = 0
    @State private var isCompactHUD: Bool = false

    @State private var selectedMediaIds: Set<String> = []
    @State private var selectedFileIds: Set<String> = []

    @State private var showBatchDeleteConfirm = false
    @State private var statusBanner: String?
    @State private var errorAlertMessage: String?

    private var totalReclaimedBytes: Int64 {
        photoScanner.sessionReclaimedBytes + fileScanner.sessionReclaimedBytes + extraReclaimedBytes
    }

    private var isScanningActive: Bool {
        switch activeTab {
        case .media:
            if case .scanning = photoScanner.phase { return true }
            if case .scanning = photoScanner.duplicatePhase { return true }
            if case .scanning = photoScanner.similarPhase { return true }
            return photoScanner.backgroundPhotoScanStatus != nil
        case .files:
            if case .scanning = fileScanner.phase { return true }
            return false
        case .guide:
            return false
        }
    }

    private var selectedMediaBytes: Int64 {
        guard case .loaded(let items) = photoScanner.phase else { return 0 }
        return items
            .filter { selectedMediaIds.contains($0.id) }
            .reduce(0) { $0 + $1.byteSize }
    }

    private var selectedFileBytes: Int64 {
        guard case .loaded(let items) = fileScanner.phase else { return 0 }
        return items
            .filter { selectedFileIds.contains($0.id) }
            .reduce(0) { $0 + $1.byteSize }
    }

    private var activeSelectionCount: Int {
        switch activeTab {
        case .media: return selectedMediaIds.count
        case .files: return selectedFileIds.count
        case .guide: return 0
        }
    }

    private var activeSelectionBytes: Int64 {
        switch activeTab {
        case .media: return selectedMediaBytes
        case .files: return selectedFileBytes
        case .guide: return 0
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CyberTheme.oledBlack.ignoresSafeArea()

            VStack(spacing: 10) {
                StorageHUDCard(
                    snapshot: storageSnapshot,
                    reclaimedBytes: totalReclaimedBytes,
                    isScanning: isScanningActive,
                    isCompact: isCompactHUD,
                    onRefresh: handleHUDAction
                )
                .padding(.horizontal, 16)
                .padding(.top, 6)

                ScrollView {
                    VStack(spacing: 14) {
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("mainScroll")).minY)
                        }
                        .frame(height: 0)

                        if let statusBanner {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(CyberTheme.acidMint)
                                Text(statusBanner)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(CyberTheme.textPrimary)
                                Spacer()
                                Button {
                                    self.statusBanner = nil
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption)
                                        .foregroundStyle(CyberTheme.textSecondary)
                                        .frame(width: 32, height: 32)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(CyberTheme.acidMint.opacity(0.4), lineWidth: 1)
                            )
                            .padding(.horizontal, 16)
                        }

                        switch activeTab {
                        case .media:
                            MediaCleanerView(
                                scanner: photoScanner,
                                selectedIds: $selectedMediaIds,
                                onSingleDelete: { item in
                                    Task { await executeMediaDeletion(ids: [item.id]) }
                                },
                                onVideoCompressed: {
                                    storageSnapshot = StorageTelemetryService.readDeviceSnapshot()
                                    statusBanner = "Salinan video terkompresi berhasil disimpan ke Galeri."
                                }
                            )
                        case .files:
                            FilesCleanerView(
                                scanner: fileScanner,
                                selectedFileIds: $selectedFileIds,
                                onSingleDelete: { file in
                                    executeFileDeletion(ids: [file.id])
                                }
                            )
                        case .guide:
                            SandboxGuideView { freed in
                                extraReclaimedBytes += freed
                                storageSnapshot = StorageTelemetryService.readDeviceSnapshot()
                                if freed > 0 {
                                    HapticFeedback.success()
                                }
                            }
                        }
                    }
                }
                .coordinateSpace(name: "mainScroll")
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(ScrollOffsetKey.self) { minY in
                    // Hysteresis prevents compact/expanded oscillation while scrolling near the threshold.
                    if minY < -48 && !isCompactHUD {
                        isCompactHUD = true
                    } else if minY > -10 && isCompactHUD {
                        isCompactHUD = false
                    }
                }
            }

            floatingGlassDock
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .confirmationDialog(
            activeTab == .media
                ? "Pindahkan \(activeSelectionCount) media (\(ByteFormatter.string(from: activeSelectionBytes))) ke album Baru Dihapus?"
                : "Hapus permanen \(activeSelectionCount) file (\(ByteFormatter.string(from: activeSelectionBytes)))?",
            isPresented: $showBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(activeTab == .media ? "Hapus ke Baru Dihapus" : "Hapus Permanen", role: .destructive) {
                if activeTab == .media {
                    let ids = selectedMediaIds
                    Task { await executeMediaDeletion(ids: ids) }
                } else if activeTab == .files {
                    executeFileDeletion(ids: selectedFileIds)
                }
            }
            Button("Batal", role: .cancel) {}
        }
        .alert("Gagal Menghapus", isPresented: Binding(
            get: { errorAlertMessage != nil },
            set: { if !$0 { errorAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorAlertMessage = nil }
        } message: {
            Text(errorAlertMessage ?? "")
        }
    }

    // MARK: - Glass Surface #2 of 2

    private var floatingGlassDock: some View {
        Group {
            if activeSelectionCount > 0 {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(activeSelectionCount) item terpilih")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(CyberTheme.textPrimary)
                        Text(ByteFormatter.string(from: activeSelectionBytes))
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(CyberTheme.cyberCyan)
                    }

                    Spacer()

                    Button {
                        clearCurrentSelection()
                    } label: {
                        Text("Batal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CyberTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                    }

                    Button {
                        showBatchDeleteConfirm = true
                    } label: {
                        Label("Hapus", systemImage: "trash")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(CyberTheme.crimsonButtonFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .cyberGlass(cornerRadius: 24, accentGlow: true)
            } else {
                HStack(spacing: 6) {
                    ForEach(CleanerTab.allCases) { tab in
                        let isSelected = activeTab == tab
                        Button {
                            HapticFeedback.selection()
                            withAnimation(.easeInOut(duration: 0.16)) {
                                activeTab = tab
                                isCompactHUD = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.iconName)
                                    .font(.subheadline.weight(.semibold))
                                Text(tab.rawValue)
                                    .font(.subheadline.weight(isSelected ? .bold : .medium))
                            }
                            .foregroundStyle(isSelected ? CyberTheme.cyanInk : CyberTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                            .background(
                                isSelected ? CyberTheme.cyberCyan : Color.clear,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                    }
                }
                .padding(6)
                .cyberGlass(cornerRadius: 24, accentGlow: false)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: activeSelectionCount > 0)
    }

    // MARK: - Actions

    private func handleHUDAction() {
        storageSnapshot = StorageTelemetryService.readDeviceSnapshot()
        if isScanningActive {
            if activeTab == .media {
                photoScanner.cancelScan()
            } else if activeTab == .files {
                fileScanner.cancelScan()
            }
            return
        }

        if activeTab == .media {
            Task { await photoScanner.requestAuthorizationAndScan() }
        } else if activeTab == .files {
            fileScanner.rescanActiveFolder()
        }
    }

    private func clearCurrentSelection() {
        HapticFeedback.selection()
        if activeTab == .media {
            selectedMediaIds.removeAll()
        } else if activeTab == .files {
            selectedFileIds.removeAll()
        }
    }

    private func executeMediaDeletion(ids: Set<String>) async {
        do {
            let freed = try await photoScanner.deleteAssets(ids: ids)
            selectedMediaIds.subtract(ids)
            storageSnapshot = StorageTelemetryService.readDeviceSnapshot()
            if freed > 0 {
                HapticFeedback.success()
                statusBanner = "\(ByteFormatter.string(from: freed)) dipindahkan ke Baru Dihapus (Foto)."
            }
        } catch {
            HapticFeedback.warning()
            errorAlertMessage = "Penghapusan dibatalkan atau gagal: \(error.localizedDescription)"
        }
    }

    private func executeFileDeletion(ids: Set<String>) {
        let outcome = fileScanner.deleteFiles(ids: ids)
        selectedFileIds.subtract(ids)
        storageSnapshot = StorageTelemetryService.readDeviceSnapshot()
        if outcome.freedBytes > 0 {
            HapticFeedback.success()
            statusBanner = "Berhasil menghapus permanen \(ByteFormatter.string(from: outcome.freedBytes))."
        }
        if outcome.failedCount > 0 {
            HapticFeedback.warning()
            errorAlertMessage = "\(outcome.failedCount) file tidak dapat dihapus karena izin folder atau file terkunci."
        }
    }
}
