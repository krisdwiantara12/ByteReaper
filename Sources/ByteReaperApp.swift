import BackgroundTasks
import SwiftUI
import UIKit

/// Registers background processing tasks before launch completes so charging-time compression can wake safely.
final class ByteReaperAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: CompressionQueueService.backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            CompressionQueueService.shared.handleBackgroundProcessingTask(processingTask)
        }
        return true
    }
}

/// Entry point enforcing OLED Dark appearance across the application.
@main
struct ByteReaperApp: App {
    @UIApplicationDelegateAdaptor(ByteReaperAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
