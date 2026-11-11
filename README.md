# ByteReaper (iOS Storage Cleaner)

Aplikasi utilitas pembersih storage iOS (target minimum iOS 16.0, cocok untuk iPhone 14 Pro Max pada iOS terbaru) dengan antarmuka **Dark OLED Cyberpunk + iOS Glass**.

## Fitur Utama (Berfungsi Penuh di Sandbox iOS Normal)
1. **Telemetri Storage Real-Time (`StorageTelemetryService`)**: Menampilkan kapasitas total, ruang terpakai, ruang tersedia, perkiraan cache sistem yang dapat dibebaskan iOS, dan total byte yang berhasil dibersihkan pada sesi aktif.
2. **Scanner Galeri Terbesar (`PhotoScannerService`)**:
   - Memindai seluruh foto, video (4K / MOV), screenshot, dan Live Photo via `PhotoKit`, menghitung ukuran file sebenarnya dari `PHAssetResource`, dan mengurutkan dari ukuran **terbesar ke terkecil**.
   - Pratinjau foto resolusi penuh dan pemutar video (`AVKit`) sebelum menghapus.
   - Pencari **Duplikat Identik (SHA-256)** via `CryptoKit` yang menjaga salinan tertua (`ASLI`) dan menandai salinan tambahan untuk dihapus massal.
   - Hapus langsung satuan maupun batch (dipindahkan iOS ke album *Baru Dihapus*).
3. **Scanner Folder Files (`FileFolderScannerService`)**:
   - Memilih folder apa pun di aplikasi **Files**, **Downloads**, **On My iPhone**, atau **iCloud Drive** via `UIDocumentPickerViewController`.
   - Memindai rekursif dan mengurutkan dari file terbesar ke terkecil, mendukung pratinjau `QuickLook`, dan **hapus permanen langsung**.
4. **Pembersih Cache Internal + Panduan Sandbox Jujur (`SandboxGuideView`)**:
   - Membersihkan cache sementara & folder `tmp/` milik aplikasi ini secara langsung.
   - Menyediakan tombol cepat ke Pengaturan iPhone dan checklist interaktif untuk menghapus cache aplikasi pihak ketiga (WhatsApp, Safari, Offload App, mengosongkan *Baru Dihapus*) karena iOS standar mengisolasi cache antar aplikasi.

## Cara Menghasilkan File `.ipa` dari PC Windows (Gratis Tanpa Mac)
Karena kompilasi biner `arm64` Mach-O untuk iOS membutuhkan Xcode (`macOS`), proyek ini dilengkapi **GitHub Actions workflow** (`.github/workflows/build-ipa.yml`):

1. Buka folder `ByteReaper` lewat **GitHub Desktop** (buat repository baru di GitHub, bisa Private maupun Public), lalu **Commit** dan **Push** ke branch `main`.
2. Buka repository Anda di browser GitHub -> tab **Actions** -> workflow **Build Unsigned iOS IPA** akan otomatis berjalan di runner `macos-latest` (menjalankan `xcodegen generate`, `xcodebuild test`, lalu `xcodebuild archive`).
3. Setelah status workflow hijau, buka hasil run tersebut dan unduh artifact **`ByteReaper-unsigned-ipa`** (berisi `ByteReaper-unsigned.ipa`).
4. Hubungkan iPhone 14 Pro Max ke PC Windows, buka **Sideloadly**, drag-and-drop `ByteReaper-unsigned.ipa`, masukkan Apple ID Anda, dan klik **Start** untuk install ke iPhone.

## Cara Build Manual di Mac (Xcode)
```bash
brew install xcodegen
xcodegen generate
open ByteReaper.xcodeproj
```

## Catatan Aset Placeholder
Nama tampilan `ByteReaper` dan ikon placeholder geometris (`Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`) dapat diganti kapan saja sesuai preferensi Anda.

