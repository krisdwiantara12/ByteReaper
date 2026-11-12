# ByteReaper (iOS Storage Cleaner)

Aplikasi utilitas pembersih storage iOS (target minimum iOS 16.0, cocok untuk iPhone 14 Pro Max pada iOS terbaru) dengan antarmuka **Dark OLED Cyberpunk + iOS Glass**.

## Fitur Utama v1.3 (Berfungsi Penuh di Sandbox iOS Normal)
1. **Telemetri Storage Real-Time (`StorageTelemetryService`, `AllTimeReclaimedStore` & Pinned Compact HUD)**:
   - Menampilkan kapasitas total, ruang terpakai, ruang tersedia, perkiraan cache sistem yang dapat dibebaskan iOS, total ruang dihemat per sesi, serta akumulasi penghematan sepanjang waktu.
2. **Scanner Galeri Terbesar 2-Tahap, Bitrate Mbps & Smart Sweep (`PhotoScannerService`, `SmartSweepSummary`)**:
   - Memindai **video terbesar lebih dulu** lalu foto di latar belakang, plus bar proporsi ukuran nyata (`Video`, `Screen Rec`, `Screenshot`, `Foto`) dan kartu **Peluang Cepat Bersih** untuk lompatan 1-tap ke target besar (`Video >100MB`, `Screen Rec`, `Foto >8MB`, `Screenshot >30H`).
   - Menampilkan badge bitrate video (`Mbps`) dan mode urut **Terbesar**, **Bitrate Tinggi**, atau **Terlama**.
   - Memisahkan **Screen Recording** (`smartAlbumScreenRecordings`) dan **Foto Jumbo > 8 MB** (`ProRAW` / `DNG` / PNG besar).
   - Filter **Lokal Saja**, filter **Umur Media** (`> 30 Hari`, `> 6 Bulan`, `> 1 Tahun`), dan filter **Album** bawaan.
   - Pencari **Duplikat Identik (SHA-256)**, **Foto Mirip** offline (`Vision` feature prints), dan detektor **Foto Blur / Dokumen & Struk** offline (CPU Laplacian variance + `VNClassifyImageRequest`).
3. **Antrean Kompresi Video Batch, Estimator Ukuran, Thermal Guard & Mode Latar Belakang (`VideoCompressionService` & `CompressionQueueService`)**:
   - Preset **HEVC 1080p**, **720p Ultra Hemat**, dan **MP4 H.264 1080p** beserta **estimasi ukuran hasil**, opsi **Bisukan Audio** (`AVMutableComposition`), dan **Hapus Asli Otomatis**.
   - Mendukung eksekusi langsung di layar aktif, guard otomatis terhadap kondisi panas kritis (`thermalState == .critical`) dan Low Power Mode, resume antrean otomatis bila dijeda iOS (`-11847`), notifikasi lokal, serta penjadwalan **Saat Charging di Latar Belakang** via iOS `BGProcessingTaskRequest` (`requiresExternalPower = true`).
4. **Konverter Batch & Satuan Foto ProRAW/PNG -> HEIC (`PhotoConversionService` & `BatchPhotoConversionSheet`)**:
   - Pilih beberapa foto statis sekaligus lalu ketuk **HEIC** (`85% Seimbang` / `72% Ultra Hemat`) dengan metadata tanggal, orientasi, dan GPS tetap utuh (`CGImageDestinationAddImageFromSource`) serta pembersihan foto asli 1-tap.
5. **Scanner Folder Files Upgrade (`FileFolderScannerService`)**:
   - Mendukung filter **`>30 Hari`**, **`0KB/Sampah`** (file 0 byte, `.tmp`, `.part`, `.crdownload`, `.bak`, `.log`, `.cache`, dan sisa `._*` macOS), dan **`Duplikat` (streaming SHA-256 64 KB buffer)**, tombol urutkan **`Terbesar` / `Terlama`**, pratinjau `QuickLook`, serta hapus satuan/batch.
6. **Pembersih Cache Internal + Pengingat Mingguan + Pintasan App Foto (`SandboxGuideView` & `ContentView`)**:
   - Pembersih cache `Caches/` & `tmp/` milik ByteReaper, toggle **Pengingat Bersih-Bersih Mingguan** via `UNUserNotificationCenter`, tombol cepat **Buka App Foto** setelah menghapus media, dan panduan jujur batasan Sandbox iOS.

## Cara Menghasilkan File `.ipa` dari PC Windows (Gratis Tanpa Mac)
Karena kompilasi biner `arm64` Mach-O untuk iOS membutuhkan Xcode (`macOS`), proyek ini dilengkapi **GitHub Actions workflow** (`.github/workflows/build-ipa.yml`):

1. Buka folder `ByteReaper` lewat **GitHub Desktop**, lalu **Commit** dan klik **Push origin** ke branch `main`.
2. Buka repository Anda di browser GitHub -> tab **Actions** -> workflow **Build Unsigned iOS IPA** akan otomatis berjalan di runner `macos-latest` (`xcodegen generate`, `xcodebuild test`, `xcodebuild archive`).
3. Setelah status workflow hijau, buka hasil run tersebut dan unduh artifact **`ByteReaper-unsigned-ipa`** (berisi `ByteReaper-unsigned.ipa`).
4. Hubungkan iPhone 14 Pro Max ke PC Windows, buka **Sideloadly**, drag-and-drop `ByteReaper-unsigned.ipa`, masukkan Apple ID Anda, dan klik **Start** untuk install ke iPhone (menggunakan 1 App ID saja sehingga aman dari batas gratis Sideloadly).

## Cara Build Manual di Mac (Xcode)
```bash
brew install xcodegen
xcodegen generate
open ByteReaper.xcodeproj
```

## Catatan Aset Placeholder
Nama tampilan `ByteReaper` dan ikon placeholder geometris (`Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`) dapat diganti kapan saja sesuai preferensi Anda.
