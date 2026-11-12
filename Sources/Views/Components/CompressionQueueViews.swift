import SwiftUI

/// Modal sheet letting the user configure batch video compression and choose
/// immediate foreground processing vs. deferred charging-time background execution.
struct BatchCompressionSheet: View {
    let videos: [MediaAssetItem]
    @ObservedObject var queue: CompressionQueueService
    let onStartForeground: () -> Void
    let onScheduledBackground: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preset: VideoCompressionPreset = .hevc1080p
    @State private var stripAudio = false
    @State private var autoDeleteOriginal = true
    @State private var isSubmitting = false

    private var totalBytes: Int64 {
        videos.reduce(0) { $0 + $1.byteSize }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CyberTheme.oledBlack.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryCard
                        presetCard
                        optionsCard
                        actionButtons
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Kompres Antrean Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Batal") { dismiss() }
                        .foregroundStyle(CyberTheme.cyberCyan)
                        .disabled(isSubmitting)
                }
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.title2)
                .foregroundStyle(CyberTheme.cyberCyan)
                .frame(width: 44, height: 44)
                .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(videos.count) video dipilih")
                    .font(.headline)
                    .foregroundStyle(CyberTheme.textPrimary)
                Text("Ukuran total asli: \(ByteFormatter.string(from: totalBytes))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(CyberTheme.cyberCyan)
            }
            Spacer()
        }
        .padding(14)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preset Resolusi & Codec")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(CyberTheme.textPrimary)

            ForEach(VideoCompressionPreset.allCases) { option in
                let isSelected = preset == option
                Button {
                    HapticFeedback.selection()
                    preset = option
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CyberTheme.textPrimary)
                            Text(presetDescription(option))
                                .font(.caption2)
                                .foregroundStyle(CyberTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? CyberTheme.cyberCyan : CyberTheme.textSecondary)
                    }
                    .padding(12)
                    .frame(minHeight: 50)
                    .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? CyberTheme.cyberCyan : CyberTheme.hairlineBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $stripAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bisukan Track Audio")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CyberTheme.textPrimary)
                    Text("Menghapus audio pada semua video di antrean ini agar makin hemat.")
                        .font(.caption2)
                        .foregroundStyle(CyberTheme.textSecondary)
                }
            }
            .tint(CyberTheme.cyberCyan)

            Rectangle()
                .fill(CyberTheme.hairlineBorder)
                .frame(height: 1)

            Toggle(isOn: $autoDeleteOriginal) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hapus Video Asli Otomatis (Mode Layar Aktif)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CyberTheme.textPrimary)
                    Text("Konfirmasi sekali di akhir antrean. Pada mode Charging Latar Belakang, asli dihapus 1 ketuk setelah proses selesai.")
                        .font(.caption2)
                        .foregroundStyle(CyberTheme.textSecondary)
                }
            }
            .tint(CyberTheme.cyberCyan)
        }
        .padding(14)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                queue.enqueue(
                    items: videos,
                    preset: preset,
                    stripAudio: stripAudio,
                    deleteOriginalAfterSave: autoDeleteOriginal
                )
                dismiss()
                onStartForeground()
            } label: {
                Label("Jalankan Sekarang (Layar Aktif)", systemImage: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CyberTheme.cyanInk)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .background(CyberTheme.cyberCyan, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button {
                isSubmitting = true
                queue.enqueue(
                    items: videos,
                    preset: preset,
                    stripAudio: stripAudio,
                    deleteOriginalAfterSave: false
                )
                Task {
                    await queue.scheduleChargingBackgroundProcessing()
                    isSubmitting = false
                    dismiss()
                    onScheduledBackground()
                }
            } label: {
                Label("Jadwalkan Saat Charging (Latar Belakang)", systemImage: "battery.100.bolt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CyberTheme.cyberCyan)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(CyberTheme.cyberCyan.opacity(0.65), lineWidth: 1)
                    )
            }
            .disabled(isSubmitting)

            Text("Mode Charging menggunakan iOS BGProcessingTask: tidak menguras baterai, berjalan otomatis saat iPhone dicas dan layar terkunci.")
                .font(.caption2)
                .foregroundStyle(CyberTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
    }

    private func presetDescription(_ preset: VideoCompressionPreset) -> String {
        switch preset {
        case .hevc1080p:
            return "Kualitas sangat tajam, ukuran hemat hingga ~60% sampai 80%."
        case .compact720p:
            return "Resolusi 720p paling kecil dan cepat, ideal untuk klip WA/arsip."
        case .mp41080p:
            return "Kompatibel di semua TV, Android, dan komputer lama."
        }
    }
}

/// Compact inline card showing live or paused batch video compression status and 1-tap original cleanup.
struct CompressionQueueBannerCard: View {
    @ObservedObject var queue: CompressionQueueService
    let onResumeForeground: () -> Void
    let onDeleteCompletedOriginals: () -> Void

    @State private var isExpanded = false

    private var completedCount: Int {
        queue.jobs.filter { $0.status == .completed }.count
    }

    private var activeJob: CompressionQueueJob? {
        queue.jobs.first { $0.status == .compressing }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if queue.isProcessing {
                    ProgressView().tint(CyberTheme.cyberCyan)
                } else {
                    Image(systemName: queue.isBackgroundScheduled ? "battery.100.bolt" : "film.stack")
                        .font(.headline)
                        .foregroundStyle(queue.interruptedCount > 0 ? CyberTheme.crimsonText : CyberTheme.cyberCyan)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CyberTheme.textPrimary)
                    if let message = queue.statusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(CyberTheme.textSecondary)
                            .lineLimit(2)
                    } else if let activeJob {
                        Text("\(activeJob.filename) · \(Int((activeJob.progress * 100).rounded()))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(CyberTheme.cyberCyan)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CyberTheme.textSecondary)
                        .frame(width: 36, height: 36)
                }
            }

            if let activeJob {
                ProgressView(value: activeJob.progress, total: 1.0)
                    .tint(CyberTheme.cyberCyan)
            }

            HStack(spacing: 8) {
                if !queue.completedPendingDeletionJobs.isEmpty && !queue.isProcessing {
                    Button(action: onDeleteCompletedOriginals) {
                        Label(
                            "Hapus \(queue.completedPendingDeletionJobs.count) Asli (-\(ByteFormatter.string(from: queue.potentialSavedBytesPendingDeletion)))",
                            systemImage: "trash"
                        )
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(CyberTheme.crimsonButtonFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                if !queue.isProcessing && queue.hasActiveOrPendingWork {
                    Button(action: onResumeForeground) {
                        Text("Lanjutkan Sekarang")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CyberTheme.cyanInk)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 40)
                            .background(CyberTheme.cyberCyan, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Button {
                        Task { await queue.scheduleChargingBackgroundProcessing() }
                    } label: {
                        Text("Saat Charging")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CyberTheme.cyberCyan)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 40)
                            .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                            )
                    }
                }

                Spacer()

                if queue.isProcessing || queue.hasActiveOrPendingWork {
                    Button("Batalkan") {
                        queue.cancelAllPending()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CyberTheme.crimsonText)
                    .frame(minHeight: 40)
                } else {
                    Button("Tutup") {
                        queue.clearFinishedJobs()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CyberTheme.textSecondary)
                    .frame(minHeight: 40)
                }
            }

            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(queue.jobs) { job in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.filename)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(CyberTheme.textPrimary)
                                    .lineLimit(1)
                                Text(job.errorMessage ?? "\(job.status.rawValue) · \(ByteFormatter.string(from: job.originalBytes))")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(job.status == .failed || job.status == .interrupted ? CyberTheme.crimsonText : CyberTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let compressed = job.compressedBytes {
                                Text(ByteFormatter.string(from: compressed))
                                    .font(.caption2.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(CyberTheme.acidMint)
                            }
                        }
                        .padding(8)
                        .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(14)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CyberTheme.cyberCyan.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var headerTitle: String {
        if queue.isProcessing {
            return "Mengompres Video (\(completedCount)/\(queue.jobs.count))"
        }
        if queue.isBackgroundScheduled {
            return "Terjadwal Saat Charging (\(queue.pendingCount) video)"
        }
        if queue.interruptedCount > 0 {
            return "Antrean Dijeda (\(queue.interruptedCount) video menunggu)"
        }
        return "Antrean Kompresi (\(completedCount)/\(queue.jobs.count) selesai)"
    }
}
