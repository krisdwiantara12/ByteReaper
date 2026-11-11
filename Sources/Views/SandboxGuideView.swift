import SwiftUI

/// Honest iOS Sandbox utility tab: cleans ByteReaper's own sandbox cache directly,
/// explains iOS sandbox limits transparently, and provides an interactive per-app cleanup checklist.
struct SandboxGuideView: View {
    let onSelfCacheCleaned: (Int64) -> Void

    @State private var selfCacheBytes: Int64 = StorageTelemetryService.measureSelfCacheBytes()
    @State private var lastCleanupMessage: String?
    @State private var checklist: [AppCleanupChecklistItem] = Self.loadChecklist()

    private static let checklistDefaultsKey = "bytereaper.cleanupChecklist.v1"

    var body: some View {
        VStack(spacing: 12) {
            selfCacheCard
            sandboxTransparencyCard
            guidedChecklistCard
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 110)
        .onAppear {
            selfCacheBytes = StorageTelemetryService.measureSelfCacheBytes()
        }
    }

    private var selfCacheCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cache Internal Aplikasi Ini", systemImage: "internaldrive")
                    .font(.headline)
                    .foregroundStyle(CyberTheme.textPrimary)
                Spacer()
                Text(ByteFormatter.string(from: selfCacheBytes))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(CyberTheme.cyberCyan)
            }

            Text("Menghapus thumbnail sementara dan berkas tmp yang dibuat ByteReaper selama proses pemindaian.")
                .font(.caption)
                .foregroundStyle(CyberTheme.textSecondary)

            if let lastCleanupMessage {
                Text(lastCleanupMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CyberTheme.acidMint)
            }

            Button {
                let freed = StorageTelemetryService.clearSelfCaches()
                selfCacheBytes = StorageTelemetryService.measureSelfCacheBytes()
                lastCleanupMessage = freed > 0
                    ? "Berhasil menghapus \(ByteFormatter.string(from: freed)) cache internal."
                    : "Cache internal sudah bersih."
                onSelfCacheCleaned(freed)
            } label: {
                Text("Bersihkan Cache ByteReaper")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CyberTheme.cyanInk)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
                    .background(CyberTheme.cyberCyan, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }

    private var sandboxTransparencyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Batasan Keamanan Sandbox iOS", systemImage: "lock.shield")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(CyberTheme.crimsonText)

            Text("Di iOS standar (tanpa Jailbreak atau TrollStore), Apple mengisolasi setiap aplikasi. Aplikasi pihak ketiga tidak diizinkan membaca atau menghapus folder cache milik WhatsApp, TikTok, Instagram, atau app lain secara langsung.")
                .font(.caption)
                .foregroundStyle(CyberTheme.textSecondary)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Buka Pengaturan iPhone", systemImage: "gearshape")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CyberTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                    )
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }

    private var guidedChecklistCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Checklist Pembersihan Cache App")
                    .font(.headline)
                    .foregroundStyle(CyberTheme.textPrimary)
                Spacer()
                if checklist.contains(where: \.isCompleted) {
                    Button("Reset") {
                        for idx in checklist.indices {
                            checklist[idx].isCompleted = false
                        }
                        Self.saveChecklist(checklist)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CyberTheme.cyberCyan)
                    .frame(minWidth: 44, minHeight: 36)
                }
            }

            ForEach($checklist) { $entry in
                Button {
                    entry.isCompleted.toggle()
                    Self.saveChecklist(checklist)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.isCompleted ? "checkmark.square.fill" : "square")
                            .font(.title3)
                            .foregroundStyle(entry.isCompleted ? CyberTheme.acidMint : CyberTheme.cyberCyan)
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.appName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(entry.isCompleted ? CyberTheme.textSecondary : CyberTheme.textPrimary)
                                .strikethrough(entry.isCompleted)
                            Text(entry.steps)
                                .font(.caption)
                                .foregroundStyle(CyberTheme.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(minHeight: 44)
                    .background(CyberTheme.oledBlack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
        )
    }

    // MARK: - Persistence

    private static let defaultChecklist: [AppCleanupChecklistItem] = [
        AppCleanupChecklistItem(
            id: "photos-recently-deleted",
            appName: "1. Kosongkan Album Baru Dihapus (Foto)",
            steps: "Setelah hapus foto/video di tab Media, buka app Foto -> Utilitas -> Baru Dihapus -> Pilih -> Hapus Semua agar kapasitas langsung kembali.",
            isCompleted: false
        ),
        AppCleanupChecklistItem(
            id: "whatsapp-storage",
            appName: "2. WhatsApp (Kelola Penyimpanan)",
            steps: "Buka WhatsApp -> Pengaturan -> Penyimpanan dan Data -> Kelola Penyimpanan -> hapus video diteruskan atau file > 5 MB.",
            isCompleted: false
        ),
        AppCleanupChecklistItem(
            id: "ios-offload-apps",
            appName: "3. Keluarkan App Jarang Dipakai (Offload)",
            steps: "Pengaturan iPhone -> Umum -> Penyimpanan iPhone -> aktifkan 'Keluarkan App Tidak Dipakai' atau hapus app besar beserta cache-nya.",
            isCompleted: false
        ),
        AppCleanupChecklistItem(
            id: "safari-cache",
            appName: "4. Bersihkan Cache Browser Safari",
            steps: "Pengaturan iPhone -> Safari -> Bersihkan Riwayat dan Data Situs Web untuk membuang cache web menumpuk.",
            isCompleted: false
        )
    ]

    private static func loadChecklist() -> [AppCleanupChecklistItem] {
        guard let data = UserDefaults.standard.data(forKey: checklistDefaultsKey),
              let decoded = try? JSONDecoder().decode([AppCleanupChecklistItem].self, from: data),
              !decoded.isEmpty else {
            return defaultChecklist
        }
        return decoded
    }

    private static func saveChecklist(_ items: [AppCleanupChecklistItem]) {
        guard let encoded = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(encoded, forKey: checklistDefaultsKey)
    }
}

