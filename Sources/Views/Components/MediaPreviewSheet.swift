import AVFoundation
import AVKit
import Photos
import SwiftUI

/// Full-resolution photo viewer and video player sheet with direct single-item deletion
/// and on-device HEVC/MP4 video compression for shrinking large MOV/4K files.
struct MediaPreviewSheet: View {
    let item: MediaAssetItem
    let scanner: PhotoScannerService
    let onDelete: () -> Void
    let onCompressedAndSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var confirmDelete = false

    @State private var selectedPreset: VideoCompressionPreset = .hevc1080p
    @State private var isCompressing = false
    @State private var compressionProgress: Double = 0
    @State private var compressionResult: VideoCompressionResult?
    @State private var compressionError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                CyberTheme.oledBlack.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        previewCanvas
                        metadataPanel
                        if item.isVideo {
                            compressionPanel
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(item.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                        .foregroundStyle(CyberTheme.cyberCyan)
                        .disabled(isCompressing)
                }
            }
            .confirmationDialog(
                "Pindahkan file \(ByteFormatter.string(from: item.byteSize)) ini ke album Baru Dihapus?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Hapus Media Asli", role: .destructive) {
                    dismiss()
                    onDelete()
                }
                Button("Batal", role: .cancel) {}
            }
        }
        .task(id: item.id) {
            isLoading = true
            if item.isVideo {
                if let playerItem = await scanner.loadPlayerItem(for: item.asset) {
                    player = AVPlayer(playerItem: playerItem)
                }
            } else {
                fullImage = await scanner.loadFullImage(for: item.asset)
            }
            isLoading = false
        }
    }

    private var previewCanvas: some View {
        Group {
            if isLoading {
                ProgressView("Memuat pratinjau...")
                    .tint(CyberTheme.cyberCyan)
                    .foregroundStyle(CyberTheme.textSecondary)
            } else if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if let fullImage {
                Image(uiImage: fullImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(CyberTheme.textSecondary)
                    Text("Pratinjau tidak tersedia secara lokal (tersimpan di iCloud).")
                        .font(.footnote)
                        .foregroundStyle(CyberTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ByteFormatter.string(from: item.byteSize))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(CyberTheme.cyberCyan)

                    Text("\(item.resolutionLabel)\(item.isVideo ? " · \(ByteFormatter.durationString(item.duration))" : "") · \(item.isLocallyAvailable ? "Lokal" : "iCloud")")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(CyberTheme.textSecondary)
                }

                Spacer()

                Button {
                    confirmDelete = true
                } label: {
                    Label("Hapus", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(CyberTheme.crimsonButtonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isCompressing)
            }

            Text(item.creationDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(CyberTheme.textSecondary)
        }
        .padding(14)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }

    private var compressionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Kompres Video (Hemat Storage)", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(CyberTheme.textPrimary)

            Text("Ekspor salinan beresolusi 1080p dan simpan ke Galeri dengan tanggal asli, lalu hapus video raksasa aslinya.")
                .font(.caption)
                .foregroundStyle(CyberTheme.textSecondary)

            HStack(spacing: 8) {
                ForEach(VideoCompressionPreset.allCases) { preset in
                    let isSelected = selectedPreset == preset
                    Button {
                        selectedPreset = preset
                    } label: {
                        Text(preset.rawValue)
                            .font(.caption.weight(isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? CyberTheme.cyanInk : CyberTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .background(
                                isSelected ? CyberTheme.cyberCyan : CyberTheme.oledBlack,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(isSelected ? CyberTheme.cyberCyan : CyberTheme.hairlineBorder, lineWidth: 1)
                            )
                    }
                    .disabled(isCompressing)
                }
            }

            if isCompressing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: compressionProgress, total: 1.0)
                        .tint(CyberTheme.cyberCyan)
                    Text("Mengompresi video... \(Int((compressionProgress * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(CyberTheme.textSecondary)
                }
            } else if let result = compressionResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Berhasil disimpan ke Galeri: \(ByteFormatter.string(from: result.compressedBytes)) (hemat \(ByteFormatter.string(from: result.savedBytes))).")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(CyberTheme.acidMint)

                    Button {
                        confirmDelete = true
                    } label: {
                        Label("Hapus Video Asli (\(ByteFormatter.string(from: item.byteSize)))", systemImage: "trash")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                            .background(CyberTheme.crimsonButtonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            } else {
                if let compressionError {
                    Text(compressionError)
                        .font(.caption)
                        .foregroundStyle(CyberTheme.crimsonText)
                }

                Button {
                    startCompression()
                } label: {
                    Text("Kompres & Simpan Salinan")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CyberTheme.cyanInk)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 46)
                        .background(CyberTheme.cyberCyan, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }

    private func startCompression() {
        isCompressing = true
        compressionError = nil
        compressionProgress = 0.02

        Task {
            do {
                let result = try await VideoCompressionService.compressAndSave(
                    item: item,
                    preset: selectedPreset
                ) { progress in
                    await MainActor.run {
                        self.compressionProgress = progress
                    }
                }
                await MainActor.run {
                    self.isCompressing = false
                    self.compressionResult = result
                    HapticFeedback.success()
                    onCompressedAndSaved()
                }
            } catch {
                await MainActor.run {
                    self.isCompressing = false
                    self.compressionError = error.localizedDescription
                    HapticFeedback.warning()
                }
            }
        }
    }
}
