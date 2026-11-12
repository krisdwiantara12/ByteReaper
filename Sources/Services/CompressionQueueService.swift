import BackgroundTasks
import Foundation
import Photos
import UIKit

/// Manages foreground batch video compression, short background grace continuation,
/// and deferred BGProcessingTask execution while charging and idle.
@MainActor
final class CompressionQueueService: ObservableObject {
    static let backgroundTaskIdentifier = "com.kris.storage.bytereaper.compress"
    static let shared = CompressionQueueService()

    private static let persistenceKey = "ByteReaper.CompressionQueue.v1"

    @Published private(set) var jobs: [CompressionQueueJob] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var isBackgroundScheduled = false
    @Published private(set) var statusMessage: String?

    private var activeTask: Task<Void, Never>?
    private var uiBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        jobs = Self.loadPersistedJobs()
    }

    var pendingCount: Int {
        jobs.filter { !$0.isFinished }.count
    }

    var interruptedCount: Int {
        jobs.filter { $0.status == .interrupted }.count
    }

    var completedPendingDeletionJobs: [CompressionQueueJob] {
        jobs.filter { $0.status == .completed && !$0.originalDeleted }
    }

    var potentialSavedBytesPendingDeletion: Int64 {
        completedPendingDeletionJobs.reduce(0) { partial, job in
            let compressed = job.compressedBytes ?? job.originalBytes
            return partial + max(0, job.originalBytes - compressed)
        }
    }

    var hasActiveOrPendingWork: Bool {
        jobs.contains { !$0.isFinished }
    }

    func enqueue(
        items: [MediaAssetItem],
        preset: VideoCompressionPreset,
        stripAudio: Bool,
        deleteOriginalAfterSave: Bool
    ) {
        let videoItems = items.filter { $0.isVideo }
        guard !videoItems.isEmpty else { return }

        let activeIds = Set(jobs.filter { !$0.isFinished }.map(\.id))
        var appended = false

        for item in videoItems where !activeIds.contains(item.id) {
            let job = CompressionQueueJob(
                id: item.id,
                filename: item.filename,
                originalBytes: item.byteSize,
                duration: item.duration,
                preset: preset,
                stripAudio: stripAudio,
                deleteOriginalAfterSave: deleteOriginalAfterSave,
                status: .queued,
                progress: 0,
                compressedBytes: nil,
                savedLocalIdentifier: nil,
                originalDeleted: false,
                errorMessage: nil
            )
            jobs.append(job)
            appended = true
        }

        if appended {
            statusMessage = nil
            persistJobs()
        }
    }

    func clearFinishedJobs() {
        jobs.removeAll { $0.isFinished }
        statusMessage = nil
        persistJobs()
    }

    func cancelAllPending() {
        activeTask?.cancel()
        activeTask = nil
        isProcessing = false
        isBackgroundScheduled = false
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        jobs.removeAll { !$0.isFinished }
        statusMessage = "Antrean tertunda dibatalkan."
        persistJobs()
    }

    /// Runs the batch queue immediately in foreground with a short iOS background grace period.
    func startForegroundQueue(
        onOriginalsDeleted: @escaping @MainActor ([String], Int64) -> Void
    ) {
        guard !isProcessing else { return }
        preparePendingJobsForRun()
        guard hasActiveOrPendingWork else { return }

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runForegroundBatch(onOriginalsDeleted: onOriginalsDeleted)
        }
    }

    /// Defers pending jobs to iOS BGProcessingTask so compression runs only when charging and idle.
    func scheduleChargingBackgroundProcessing() async {
        preparePendingJobsForRun()
        guard hasActiveOrPendingWork else {
            statusMessage = "Tidak ada video di antrean."
            return
        }

        _ = await NotificationReminderService.requestAuthorizationIfNeeded()
        submitBackgroundProcessingRequest(updateMessageOnSuccess: true)
    }

    /// Prompts PhotoKit once to delete original videos that finished compression in background or foreground.
    func deleteCompletedOriginals() async -> (deletedIds: [String], netSavedBytes: Int64, error: String?) {
        let targets = completedPendingDeletionJobs
        guard !targets.isEmpty else { return ([], 0, nil) }

        let targetIds = targets.map(\.id)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: targetIds, options: nil)
        var assetsToDelete: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assetsToDelete.append(asset)
        }

        guard !assetsToDelete.isEmpty else {
            markOriginalsDeleted(for: Set(targetIds))
            return ([], 0, nil)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assetsToDelete as NSFastEnumeration)
            }
            let deletedIds = assetsToDelete.map(\.localIdentifier)
            let deletedSet = Set(deletedIds)
            let netSaved = targets
                .filter { deletedSet.contains($0.id) }
                .reduce(Int64(0)) { partial, job in
                    let compressed = job.compressedBytes ?? job.originalBytes
                    return partial + max(0, job.originalBytes - compressed)
                }

            markOriginalsDeleted(for: deletedSet)
            if netSaved > 0 {
                AllTimeReclaimedStore.add(netSaved)
            }
            return (deletedIds, netSaved, nil)
        } catch {
            return ([], 0, "Penghapusan video asli dibatalkan atau ditolak oleh iOS.")
        }
    }

    /// Called by BGTaskScheduler handler registered in AppDelegate before app launch completes.
    nonisolated func handleBackgroundProcessingTask(_ task: BGProcessingTask) {
        let worker = Task { @MainActor [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            let completedCleanly = await self.runBackgroundBatch()
            task.setTaskCompleted(success: completedCleanly)
        }

        task.expirationHandler = {
            worker.cancel()
        }
    }

    // MARK: - Execution Loops

    private func runForegroundBatch(
        onOriginalsDeleted: @escaping @MainActor ([String], Int64) -> Void
    ) async {
        isProcessing = true
        isBackgroundScheduled = false
        statusMessage = "Mengompres antrean video..."

        UIApplication.shared.isIdleTimerDisabled = true
        beginGraceBackgroundTask()

        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            endGraceBackgroundTask()
            isProcessing = false
            activeTask = nil
        }

        var finishedCount = 0
        var interruptedBySystem = false

        while let index = nextQueuedJobIndex() {
            if Task.isCancelled { break }

            let job = jobs[index]
            let outcome = await processSingleJob(at: index, originalJob: job)
            switch outcome {
            case .completed:
                finishedCount += 1
            case .interrupted:
                interruptedBySystem = true
            case .failed, .cancelled:
                break
            }

            if interruptedBySystem || Task.isCancelled {
                break
            }
        }

        if interruptedBySystem {
            statusMessage = "Sebagian video dijeda iOS saat layar mati/pindah app. Ketuk Lanjutkan atau jadwalkan saat charging."
            await NotificationReminderService.sendCompressionNotification(
                title: "Kompresi Video Dijeda iOS",
                body: "Buka ByteReaper untuk melanjutkan antrean atau jadwalkan saat dicas."
            )
            return
        }

        if !Task.isCancelled && finishedCount > 0 {
            let autoDeleteIds = Set(
                jobs.filter { $0.status == .completed && !$0.originalDeleted && $0.deleteOriginalAfterSave }
                    .map(\.id)
            )
            if !autoDeleteIds.isEmpty {
                let deletion = await deleteOriginalsMatching(autoDeleteIds)
                if !deletion.deletedIds.isEmpty {
                    onOriginalsDeleted(deletion.deletedIds, deletion.netSavedBytes)
                    statusMessage = "Selesai: \(finishedCount) video dikompres, \(ByteFormatter.format(deletion.netSavedBytes)) dihemat."
                } else {
                    statusMessage = "Selesai kompres \(finishedCount) video. Video asli tetap disimpan sesuai pilihan."
                }
            } else {
                statusMessage = "Selesai kompres \(finishedCount) video. Ketuk Hapus File Asli untuk klaim ruang."
            }

            if UIApplication.shared.applicationState != .active {
                await NotificationReminderService.sendCompressionNotification(
                    title: "Kompresi Antrean Selesai",
                    body: "\(finishedCount) video berhasil dikompres dan disimpan ke app Foto."
                )
            }
        }
    }

    private func runBackgroundBatch() async -> Bool {
        guard !isProcessing else { return false }
        preparePendingJobsForRun()
        guard hasActiveOrPendingWork else {
            isBackgroundScheduled = false
            return true
        }

        isProcessing = true
        defer {
            isProcessing = false
            isBackgroundScheduled = false
        }

        var completedCount = 0
        var paused = false

        while let index = nextQueuedJobIndex() {
            if Task.isCancelled {
                paused = true
                break
            }

            let job = jobs[index]
            let outcome = await processSingleJob(at: index, originalJob: job)
            switch outcome {
            case .completed:
                completedCount += 1
            case .interrupted, .cancelled:
                paused = true
            case .failed:
                break
            }

            if paused || Task.isCancelled {
                paused = true
                break
            }
        }

        if paused && hasActiveOrPendingWork {
            submitBackgroundProcessingRequest(updateMessageOnSuccess: false)
            return false
        }

        if completedCount > 0 {
            let potentialText = ByteFormatter.format(potentialSavedBytesPendingDeletion)
            await NotificationReminderService.sendCompressionNotification(
                title: "Kompresi Saat Charging Selesai",
                body: "\(completedCount) video selesai dikompresi. Buka ByteReaper untuk hapus asli & hemat \(potentialText)."
            )
            statusMessage = "\(completedCount) video selesai dikompresi di latar belakang."
        }
        return true
    }

    private enum JobOutcome {
        case completed
        case interrupted
        case cancelled
        case failed
    }

    private func processSingleJob(at index: Int, originalJob: CompressionQueueJob) async -> JobOutcome {
        guard jobs.indices.contains(index) else { return .failed }

        jobs[index].status = .compressing
        jobs[index].progress = 0.02
        jobs[index].errorMessage = nil
        persistJobs()

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [originalJob.id], options: nil).firstObject else {
            jobs[index].status = .failed
            jobs[index].errorMessage = "Video tidak ditemukan lagi di Foto."
            persistJobs()
            return .failed
        }

        let item = MediaAssetItem(
            id: originalJob.id,
            asset: asset,
            mediaType: asset.mediaType,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            creationDate: asset.creationDate ?? .distantPast,
            byteSize: originalJob.originalBytes,
            filename: originalJob.filename,
            isScreenshot: false,
            isLivePhoto: false,
            isBurst: false,
            isLocallyAvailable: true,
            isScreenRecording: false
        )

        let jobId = originalJob.id
        do {
            let result = try await VideoCompressionService.compressAndSave(
                item: item,
                preset: originalJob.preset,
                stripAudio: originalJob.stripAudio
            ) { [weak self] fraction in
                Task { @MainActor in
                    guard let self,
                          let currentIndex = self.jobs.firstIndex(where: { $0.id == jobId }),
                          self.jobs[currentIndex].status == .compressing else { return }
                    self.jobs[currentIndex].progress = fraction
                }
            }

            if let updatedIdx = jobs.firstIndex(where: { $0.id == jobId }) {
                jobs[updatedIdx].status = .completed
                jobs[updatedIdx].progress = 1.0
                jobs[updatedIdx].compressedBytes = result.compressedBytes
                jobs[updatedIdx].savedLocalIdentifier = result.savedLocalIdentifier
                persistJobs()
            }
            return .completed
        } catch let failure as VideoExportFailure {
            if let updatedIdx = jobs.firstIndex(where: { $0.id == originalJob.id }) {
                switch failure {
                case .interrupted(let msg):
                    jobs[updatedIdx].status = .interrupted
                    jobs[updatedIdx].errorMessage = msg
                    persistJobs()
                    return .interrupted
                case .cancelled:
                    jobs[updatedIdx].status = .interrupted
                    jobs[updatedIdx].errorMessage = "Dijeda sebelum selesai."
                    persistJobs()
                    return .cancelled
                case .failed(let msg):
                    jobs[updatedIdx].status = .failed
                    jobs[updatedIdx].errorMessage = msg
                    persistJobs()
                    return .failed
                }
            }
            return .failed
        } catch {
            if let updatedIdx = jobs.firstIndex(where: { $0.id == originalJob.id }) {
                jobs[updatedIdx].status = .failed
                jobs[updatedIdx].errorMessage = error.localizedDescription
                persistJobs()
            }
            return .failed
        }
    }

    private func deleteOriginalsMatching(_ ids: Set<String>) async -> (deletedIds: [String], netSavedBytes: Int64) {
        let targets = jobs.filter { $0.status == .completed && !$0.originalDeleted && ids.contains($0.id) }
        guard !targets.isEmpty else { return ([], 0) }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        guard !assets.isEmpty else { return ([], 0) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
            }
            let deletedSet = Set(assets.map(\.localIdentifier))
            let netSaved = targets
                .filter { deletedSet.contains($0.id) }
                .reduce(Int64(0)) { partial, job in
                    let compressed = job.compressedBytes ?? job.originalBytes
                    return partial + max(0, job.originalBytes - compressed)
                }
            markOriginalsDeleted(for: deletedSet)
            if netSaved > 0 {
                AllTimeReclaimedStore.add(netSaved)
            }
            return (Array(deletedSet), netSaved)
        } catch {
            return ([], 0)
        }
    }

    private func markOriginalsDeleted(for ids: Set<String>) {
        for idx in jobs.indices where ids.contains(jobs[idx].id) {
            jobs[idx].originalDeleted = true
        }
        persistJobs()
    }

    private func preparePendingJobsForRun() {
        for idx in jobs.indices where jobs[idx].status == .interrupted || jobs[idx].status == .compressing {
            jobs[idx].status = .queued
            jobs[idx].progress = 0
        }
        persistJobs()
    }

    private func nextQueuedJobIndex() -> Int? {
        jobs.firstIndex { $0.status == .queued }
    }

    private func submitBackgroundProcessingRequest(updateMessageOnSuccess: Bool) {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
            try BGTaskScheduler.shared.submit(request)
            isBackgroundScheduled = true
            if updateMessageOnSuccess {
                statusMessage = "Terjadwal! Kompresi otomatis berjalan saat iPhone dicas dan layar terkunci."
            }
        } catch {
            isBackgroundScheduled = false
            statusMessage = "Penjadwalan latar belakang tidak tersedia di lingkungan ini (\(error.localizedDescription)). Gunakan Jalankan Sekarang."
        }
    }

    private func beginGraceBackgroundTask() {
        endGraceBackgroundTask()
        uiBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ByteReaperCompressionGrace") { [weak self] in
            Task { @MainActor in
                self?.activeTask?.cancel()
                self?.endGraceBackgroundTask()
            }
        }
    }

    private func endGraceBackgroundTask() {
        guard uiBackgroundTaskID != .invalid else { return }
        let id = uiBackgroundTaskID
        uiBackgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    private func persistJobs() {
        guard let encoded = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.persistenceKey)
    }

    private static func loadPersistedJobs() -> [CompressionQueueJob] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              var decoded = try? JSONDecoder().decode([CompressionQueueJob].self, from: data) else {
            return []
        }
        for idx in decoded.indices where decoded[idx].status == .compressing {
            decoded[idx].status = .interrupted
            decoded[idx].errorMessage = "Terhenti saat aplikasi ditutup."
        }
        return decoded
    }
}
