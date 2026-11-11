import AVFoundation
import AVKit
import Photos
import SwiftUI

/// Full-resolution photo viewer and video player sheet for inspecting large media before deletion.
struct MediaPreviewSheet: View {
    let item: MediaAssetItem
    let scanner: PhotoScannerService
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ZStack {
                CyberTheme.oledBlack.ignoresSafeArea()

                VStack(spacing: 16) {
                    Group {
                        if isLoading {
                            ProgressView("Memuat pratinjau...")
                                .tint(CyberTheme.cyberCyan)
                                .foregroundStyle(CyberTheme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    metadataPanel
                }
                .padding(16)
            }
            .navigationTitle(item.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                        .foregroundStyle(CyberTheme.cyberCyan)
                }
            }
            .confirmationDialog(
                "Pindahkan file \(ByteFormatter.string(from: item.byteSize)) ini ke album Baru Dihapus?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Hapus Media", role: .destructive) {
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

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ByteFormatter.string(from: item.byteSize))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(CyberTheme.cyberCyan)

                    Text("\(item.resolutionLabel)\(item.isVideo ? " · \(ByteFormatter.durationString(item.duration))" : "")")
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
}

