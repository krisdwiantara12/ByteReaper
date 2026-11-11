import SwiftUI

/// Entry point enforcing OLED Dark appearance across the application.
@main
struct ByteReaperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

