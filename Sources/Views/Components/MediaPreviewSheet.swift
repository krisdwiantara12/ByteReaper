import AVFoundation
import AVKit
import Photos
import SwiftUI

/// Full-resolution photo viewer and video player sheet with direct single-item deletion,
/// on-device HEVC/MP4/720p video compression (with optional audio removal),
/// and ProRAW/large-photo to HEIC conversion.
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
    @State private var stripAudio = false
    @State private var isCompressing = false
    @State private var compressionProgress: Double = 0
    @State private var compressionResult: VideoCompressionResult?
    @State private var compressionError: String?

    @State private var isConvertingPhoto = false
    @State private var photoConversionResult: PhotoConversionResult?
    @State private var photoConversionError: String?

    @State private var activeTask: Task<Void, Never>?

    private var isBusy: Bool {
        isCompressing || isConvertingPhoto
    }

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
                        } else if item.isLargeStaticPhoto {
                            photoConversionPanel
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
                        .disabled(isBusy)
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
        .onDisappear {
            player?.pause()
            activeTask?.cancel()
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
                .disabled(isBusy)
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

            Text("Ekspor salinan hemat ke Galeri dengan tanggal & lokasi asli, lalu hapus video raksasa aslinya.")
                .font(.caption)
                .foregroundStyle(CyberTheme.textSecondary)

            HStack(spacing: 8) {
                ForEach(VideoCompressionPreset.allCases) { preset in
                    let isSelected = selectedPreset == preset
                    Button {
                        selectedPreset = preset
                    } label: {
                        Text(preset.rawValue)
                            .font(.caption2.weight(isSelected ? .bold : .medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .foregroundStyle(isSelected ? CyberTheme.cyanInk : CyberTheme.textSecondary)
                            .padding(.horizontal, 6)
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

            Toggle(isOn: $stripAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bisukan / Hapus Track Audio")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CyberTheme.textPrimary)
                    Text("Cocok untuk screen recording atau video rekaman bising.")
                        .font(.caption2)
                        .foregroundStyle(CyberTheme.textSecondary)
                }
            }
            .tint(CyberTheme.cyberCyan)
            .disabled(isCompressing)

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

    private var photoConversionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Konversi Foto Besar / ProRAW ke HEIC", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(CyberTheme.textPrimary)

            Text("Ubah file foto jumbo (\(ByteFormatter.string(from: item.byteSize))) ke format HEIC modern 85% dengan tanggal & GPS asli, biasanya 70% hingga 85% lebih kecil.")
                .font(.caption)
                .foregroundStyle(CyberTheme.textSecondary)

            if isConvertingPhoto {
                ProgressView("Mengonversi foto ke HEIC...")
                    .tint(CyberTheme.cyberCyan)
                    .foregroundStyle(CyberTheme.textSecondary)
            } else if let result = photoConversionResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tersimpan sebagai HEIC: \(ByteFormatter.string(from: result.convertedBytes)) (hemat \(ByteFormatter.string(from: result.savedBytes))).")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(CyberTheme.acidMint)

                    Button {
                        confirmDelete = true
                    } label: {
                        Label("Hapus Foto Asli (\(ByteFormatter.string(from: item.byteSize)))", systemImage: "trash")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                            .background(CyberTheme.crimsonButtonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            } else {
                if let photoConversionError {
                    Text(photoConversionError)
                        .font(.caption)
                        .foregroundStyle(CyberTheme.crimsonText)
                }

                Button {
                    startPhotoConversion()
                } label: {
                    Text("Konversi ke HEIC Hemat")
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

        activeTask = Task {
            do {
                let result = try await VideoCompressionService.compressAndSave(
                    item: item,
                    preset: selectedPreset,
                    stripAudio: stripAudio
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

    private func startPhotoConversion() {
        isConvertingPhoto = true
        photoConversionError = nil

        activeTask = Task {
            do {
                let result = try await PhotoConversionService.convertToHEICAndSave(item: item)
                await MainActor.run {
                    self.isConvertingPhoto = false
                    self.photoConversionResult = result
                    HapticFeedback.success()
                    onCompressedAndSaved()
                }
            } catch {
                await MainActor.run {
                    self.isConvertingPhoto = false
                    self.photoConversionError = error.localizedDescription
                    HapticFeedback.warning()
                }
            }
        }
    }
}
